#!/usr/bin/env bash
# Creates a bucket-scoped B2 key. Without a host argument it replaces this host's key and
# reconnects; with one, it prints a key for that host. The master key is passed to curl via stdin.
set -euo pipefail
. "$(dirname "$(readlink -f "$0")")/env.sh"
for=${1:-$HOST}
[ -n "${B2_BUCKET_ID:-}" ] || { echo "B2_BUCKET_ID empty in config" >&2; exit 1; }
caps='["listBuckets","listAllBucketNames","readBuckets","listFiles","readFiles","writeFiles","deleteFiles",
       "readBucketEncryption","readBucketRetentions","readFileRetentions","writeFileRetentions","readFileLegalHolds"]'

read -rp  "B2 master keyID (= account ID): " mid
read -rsp "B2 master applicationKey: " mkey; echo
auth=$(curl -fsS -K - https://api.backblazeb2.com/b2api/v4/b2_authorize_account <<<"user = \"$mid:$mkey\"")
unset mkey
tok=$(jq -er .authorizationToken <<<"$auth"); api=$(jq -er .apiInfo.storageApi.apiUrl <<<"$auth")
body=$(jq -n --arg acct "$(jq -er .accountId <<<"$auth")" --arg name "kopia-$for" --arg b "$B2_BUCKET_ID" --argjson caps "$caps" \
        '{accountId:$acct, keyName:$name, bucketIds:[$b], capabilities:$caps}')
new=$(curl -fsS -K - -d "$body" "$api/b2api/v4/b2_create_key" <<<"header = \"Authorization: $tok\"")
id=$(jq -er .applicationKeyId <<<"$new"); key=$(jq -er .applicationKey <<<"$new")
echo "created key kopia-$for ($id) on bucket $B2_BUCKET"

if [ "$for" = "$HOST" ] && [ -w "$KOPIA_ETC" ]; then
  old=$AWS_ACCESS_KEY_ID
  write_secret b2-key-id "$id"; write_secret b2-key "$key"
  echo "written to $KOPIA_ETC/b2-key-id and $KOPIA_ETC/b2-key"
  if [ -f "$KOPIA_CONFIG_PATH" ]; then
    echo "reconnecting with the new key"
    kopia repository disconnect
    "$BACKUP_DIR/bin/connect"
  fi
  [ -z "$old" ] || [ "$old" = "$id" ] || echo "old key $old is now unused: delete it in B2 > Application Keys"
else
  echo; echo "  b2-key-id: $id"; echo "  b2-key:    $key"; echo
  echo "shown once, not stored. On $for: 'sudo make key' is simpler; or write each value to /etc/kopia/<name> (root, 0600, no newline)."
fi

#!/usr/bin/env bash
# Fails when staged files match common Kopia or B2 credential shapes.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
pat='(KOPIA_PASSWORD|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID)=[^[:space:]"'"'"'$]+'  # assigned a literal
pat+='|\bK00[0-9A-Za-z]{25,}\b'   # B2 application key
pat+='|\b[0-9a-f]{25}\b'          # B2 key id
if git grep --cached -nE "$pat" -- .; then
  echo "^^ secret-shaped content staged; refusing" >&2; exit 1
fi
echo "no secrets found"

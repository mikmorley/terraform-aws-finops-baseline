#!/usr/bin/env bash
# Run `terraform init -backend=false` + `terraform validate` for the root module,
# every submodule and every example. Used by CI and handy locally.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dirs=(".")
for d in modules/*/ examples/*/; do
  [[ -d "$d" ]] && ls "$d"*.tf >/dev/null 2>&1 && dirs+=("${d%/}")
done

status=0
for d in "${dirs[@]}"; do
  echo "==> validate $d"
  if ! (cd "$d" && terraform init -backend=false -input=false -no-color >/dev/null && terraform validate -no-color); then
    status=1
  fi
done
exit "$status"

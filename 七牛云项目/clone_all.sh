#!/usr/bin/env bash
set -euo pipefail
cd "/Users/allure/Desktop/七牛云项目"

REPOS=$(rg -o 'https?://github\.com/[^ |)]+|https?://gitee\.com/[^ |)]+' "七牛云XEngineer获奖作品链接.md" | sort -u)

clone_one() {
  local url="$1"
  # repo name = last path segment, strip .git
  local name
  name=$(basename "$url" .git)
  if [ -d "$name" ]; then
    echo "[SKIP] $name already exists"
    return 0
  fi
  echo "[CLONE] $name <- $url"
  if git clone --depth 1 "$url" "$name" 2>"$name.err"; then
    rm -f "$name.err"
    echo "[DONE] $name"
  else
    echo "[FAIL] $name (see $name.err)"
  fi
}
export -f clone_one

echo "$REPOS" | xargs -P 8 -I {} bash -c 'clone_one "$@"' _ {}

echo "=== All done ==="

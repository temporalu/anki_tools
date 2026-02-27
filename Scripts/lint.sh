#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

while IFS= read -r -d '' file; do
    bash -n "$file"
done < <(find "$repo_dir" -type f -name "*.sh" -print0)

while IFS= read -r -d '' file; do
    python3 -m py_compile "$file"
done < <(find "$repo_dir" -type f -name "*.py" -print0)

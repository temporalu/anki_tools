#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

if command -v mypy >/dev/null 2>&1; then
    while IFS= read -r -d '' file; do
        mypy --ignore-missing-imports "$file"
    done < <(find "$repo_dir" -type f -name "*.py" -print0)
else
    while IFS= read -r -d '' file; do
        python3 -m py_compile "$file"
    done < <(find "$repo_dir" -type f -name "*.py" -print0)
fi

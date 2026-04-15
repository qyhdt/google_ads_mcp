#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 0 ]]; then
  commit_message="$*"
else
  commit_message="update project changes"
fi

git add -A
git commit -m "$commit_message"
git push

#!/usr/bin/env bash
set -euo pipefail
echo "hello from $GITHUB_ACTION_PATH"
ls "$GITHUB_ACTION_PATH/.."

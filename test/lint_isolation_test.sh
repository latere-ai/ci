#!/usr/bin/env bash
# golangci-lint locks os.TempDir()/golangci-lint.lock across repositories.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step_for() {
    awk -v marker="$2" '
        /^      - / { if (found) exit; found = index($0, marker) > 0 }
        found { print }
    ' "$1"
}

for name in go-verify lateregate; do
    if [ "$name" = go-verify ]; then
        marker='uses: golangci/golangci-lint-action@'
    else
        marker='run: go tool lateregate ${{ matrix.gate }}'
    fi
    step=$(step_for "$REPO_ROOT/.github/workflows/$name.yml" "$marker")
    if ! printf '%s\n' "$step" | grep -Fq 'TMPDIR: ${{ runner.temp }}'; then
        echo "FAIL: $name shares the linter lock between runner slots"
        exit 1
    fi
done

echo 'PASS: linter locks are isolated to each runner slot'

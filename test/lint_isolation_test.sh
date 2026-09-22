#!/usr/bin/env bash
# golangci-lint locks os.TempDir()/golangci-lint.lock across repositories, so
# the lint step gets the runner process's own TMPDIR. No other gate may: a
# cached Go test result is keyed on the TMPDIR the test read, and a value per
# runner process splits the cache between processes on one machine.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

step_for() {
    awk -v marker="$2" '
        /^      - / { if (found) exit; found = index($0, marker) > 0 }
        found { print }
    ' "$1"
}

isolated() { printf '%s\n' "$1" | grep -Fq 'TMPDIR: ${{ runner.temp }}'; }

step=$(step_for "$REPO_ROOT/.github/workflows/go-verify.yml" 'uses: golangci/golangci-lint-action@')
if ! isolated "$step"; then
    echo "FAIL: go-verify shares the linter lock between runner slots"
    exit 1
fi

workflow="$REPO_ROOT/.github/workflows/lateregate.yml"
lint=$(step_for "$workflow" 'run: go tool lateregate lint')
if ! isolated "$lint" || ! printf '%s\n' "$lint" | grep -Fq "if: \${{ matrix.gate == 'lint' }}"; then
    echo "FAIL: lateregate's lint gate shares the linter lock between runner slots"
    exit 1
fi
others=$(step_for "$workflow" 'run: go tool lateregate ${{ matrix.gate }}')
if isolated "$others" || ! printf '%s\n' "$others" | grep -Fq "if: \${{ matrix.gate != 'lint' }}"; then
    echo "FAIL: lateregate gives every gate a per-slot TMPDIR, splitting the test cache"
    exit 1
fi

echo 'PASS: linter locks are isolated to each runner slot, and only the linter'

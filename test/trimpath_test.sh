#!/usr/bin/env bash
# A self-hosted runner keeps one Go build and test cache for all of its runner
# processes, and each process checks out under a work directory of its own.
# Without -trimpath the cache keys a package on that directory, so no process
# replays what another recorded. Every job of lateregate.yml that sets up Go
# therefore sets GOFLAGS=-trimpath when its runner is not a hosted label, and
# only then: a hosted runner starts with an empty cache and gains nothing. The
# aggregate result job runs no Go and needs no flag.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/lateregate.yml"

jobs=$(awk '
    /^jobs:$/ { injobs = 1; next }
    injobs && /^  [a-z0-9_-]+:$/ { if (go) n++; go = 0 }
    injobs && /uses: actions\/setup-go@/ { go = 1 }
    END { if (go) n++; print n + 0 }
' "$WORKFLOW")
FAILURES=0
for label in 'inputs.runs_on' 'matrix.os'; do
    want="GOFLAGS: \${{ !(startsWith($label, 'ubuntu-') || startsWith($label, 'macos-') || startsWith($label, 'windows-')) && '-trimpath' || '' }}"
    n=$(grep -cF -- "$want" "$WORKFLOW" || true)
    case "$label" in
        inputs.runs_on) expected=$((jobs - 1)) ;;
        matrix.os) expected=1 ;;
    esac
    if [ "$n" -ne "$expected" ]; then
        echo "FAIL: $n job(s) set -trimpath on a self-hosted $label, want $expected"
        FAILURES=$((FAILURES + 1))
    fi
done
if [ "$FAILURES" -ne 0 ]; then exit 1; fi
echo "PASS: all $jobs Go jobs build with -trimpath on a self-hosted runner and only there"

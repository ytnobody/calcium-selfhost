#!/usr/bin/env bash
#
# Differential test harness: compare the candidate implementation against the
# reference implementation.
#
# The oracle is the reference `calcium` binary, built from the calcium-lang
# commit recorded in ./oracle.pin. The candidate is this repository, executed by
# that same binary.
#
# The contract is behavioural equivalence, not byte-identical output: see
# calcium-lang/specs/bone-format.md §6 and SPEC.md §3.
#
# Environment:
#   ORACLE        path to the reference `calcium` binary (required)
#   CALCIUM_LANG  path to the calcium-lang checkout (default: ../calcium-lang)
#   CORPUS        override the corpus root (default: $CALCIUM_LANG)
#   STRICT        "1" to fail when a stage has nothing to compare
#   FILTER        only run corpus files whose path matches this regex
#
# Exit status: 0 if every comparison passed (or none could run), 1 otherwise.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CALCIUM_LANG=${CALCIUM_LANG:-$ROOT/../calcium-lang}
CORPUS=${CORPUS:-$CALCIUM_LANG}
STRICT=${STRICT:-0}
FILTER=${FILTER:-}

if [[ -z "${ORACLE:-}" ]]; then
    echo "error: ORACLE is not set (path to the reference calcium binary)" >&2
    exit 1
fi
if [[ ! -x "$ORACLE" ]]; then
    echo "error: ORACLE is not executable: $ORACLE" >&2
    exit 1
fi
if [[ ! -d "$CALCIUM_LANG/pkg" ]]; then
    echo "error: CALCIUM_LANG does not look like a calcium-lang checkout: $CALCIUM_LANG" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skip=0
declare -a failures=()

fail_case() { # fail_case <label> <detail-file>
    fail=$((fail + 1))
    failures+=("$1")
    echo "FAIL $1"
    if [[ -s "$2" ]]; then
        sed 's/^/     /' "$2" | head -20
    fi
}

# --- Stage 0: every Calcium source in this repository must at least lint ------

lint_self() {
    local files=()
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$ROOT" -name '*.ca' -not -path '*/.*' | sort
    )
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "error: no Calcium sources found in $ROOT" >&2
        return 1
    fi

    local out="$WORK/lint.out"
    if "$ORACLE" lint "${files[@]}" >"$out" 2>&1; then
        echo "ok   lint (${#files[@]} files)"
        pass=$((pass + 1))
    else
        fail_case "lint" "$out"
    fi
}

# --- Corpus discovery ---------------------------------------------------------

corpus_files() {
    local dirs=("$CORPUS/examples" "$CORPUS/tests")
    [[ -d "$CORPUS/csv" ]] && dirs+=("$CORPUS/csv")
    local f
    for f in $(find "${dirs[@]}" -name '*.ca' 2>/dev/null | sort); do
        if [[ -n "$FILTER" ]] && ! [[ "$f" =~ $FILTER ]]; then
            continue
        fi
        printf '%s\n' "$f"
    done
}

# --- Candidate invocation -----------------------------------------------------

candidate() { # candidate <command> [args...]
    "$ORACLE" "$ROOT/main.ca" "$@"
}

have_component() { # have_component <name>
    # Every component module carries `func implemented()`; the CLI does not
    # surface it yet, so read the source. This stays honest before and after a
    # component lands.
    grep -q 'func implemented() = true' "$ROOT/$1/mod.ca" 2>/dev/null
}

# --- Stage 1: formatter -------------------------------------------------------
# Compared byte-for-byte: a given program has exactly one correct formatting.

run_fmt() {
    if ! have_component formatter; then
        echo "skip fmt (formatter not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local f base out_oracle out_cand
    while IFS= read -r f; do
        base=$(basename "$f")
        out_oracle="$WORK/oracle-$base"
        out_cand="$WORK/cand-$base"
        cp "$f" "$out_oracle" 2>/dev/null || { skip=$((skip + 1)); continue; }

        if ! "$ORACLE" fmt "$out_oracle" >/dev/null 2>&1; then
            skip=$((skip + 1))   # oracle itself cannot format it; not our problem
            continue
        fi
        if ! candidate fmt "$f" -o "$out_cand" >"$WORK/fmt.err" 2>&1; then
            fail_case "fmt: $f" "$WORK/fmt.err"
            continue
        fi
        if diff -u "$out_oracle" "$out_cand" >"$WORK/fmt.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "fmt: $f" "$WORK/fmt.diff"
        fi
    done < <(corpus_files)
}

# --- Stage 2: compiler --------------------------------------------------------
# Behaviour is compared, not bytes: run the oracle's output and the candidate's
# output and compare stdout, and whether each succeeded.

run_compile() {
    if ! have_component compiler; then
        echo "skip compile (compiler not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local f base bone out_oracle out_cand st_oracle st_cand
    while IFS= read -r f; do
        base=$(basename "$f")
        bone="$WORK/cand-$base.bone"
        out_oracle="$WORK/run-oracle-$base"
        out_cand="$WORK/run-cand-$base"

        if ! candidate compile "$f" -o "$bone" >"$WORK/cc.err" 2>&1; then
            fail_case "compile: $f" "$WORK/cc.err"
            continue
        fi

        "$ORACLE" "$f" >"$out_oracle" 2>&1
        st_oracle=$?
        "$ORACLE" "$bone" >"$out_cand" 2>&1
        st_cand=$?

        if [[ $st_oracle -ne $st_cand ]]; then
            {
                echo "exit status: oracle=$st_oracle candidate=$st_cand"
                echo "--- oracle output ---"; head -20 "$out_oracle"
                echo "--- candidate output ---"; head -20 "$out_cand"
            } >"$WORK/run.diff"
            fail_case "run: $f" "$WORK/run.diff"
        elif diff -u "$out_oracle" "$out_cand" >"$WORK/run.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "run: $f" "$WORK/run.diff"
        fi
    done < <(corpus_files)
}

# --- Main ---------------------------------------------------------------------

echo "reference: $CALCIUM_LANG"
echo "oracle:    $ORACLE ($("$ORACLE" version 2>/dev/null | head -1))"
echo "corpus:    $CORPUS"
echo

lint_self || exit 1
run_fmt
run_compile

echo
if [[ $fail -eq 0 ]]; then
    echo "PASS ($pass passed, $skip skipped)"
    [[ $skip -gt 0 && "$STRICT" == "1" ]] && {
        echo "error: STRICT=1 but $skip stage(s) were skipped" >&2
        exit 1
    }
    exit 0
fi

echo "FAIL ($pass passed, $fail failed, $skip skipped)"
printf '  - %s\n' "${failures[@]}"
exit 1

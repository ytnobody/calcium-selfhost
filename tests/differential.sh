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
excluded=0
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
    # tests/typecheck holds fixtures with deliberate type errors; they are inputs
    # to the checker stage, not code that has to lint cleanly.
    while IFS= read -r f; do files+=("$f"); done < <(
        find "$ROOT" -name '*.ca' -not -path '*/.*' -not -path "$ROOT/tests/typecheck/*" | sort
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
    # The stdlib sources are the densest Calcium in the repository; lexing and
    # formatting them compares against the reference like any other file. The
    # stages that need a runnable program skip them (the reference's top-level
    # compiler does not see the `__` primitives).
    [[ -d "$CORPUS/test" ]] && dirs+=("$CORPUS/test")
    [[ -d "$CORPUS/pkg/vm/stdlib" ]] && dirs+=("$CORPUS/pkg/vm/stdlib")
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

# note_excluded records a file that a stage cannot compare, and says why when
# VERBOSE=1 (`VERBOSE=1 bash tests/differential.sh` lists every exclusion). The
# count is what the summary line reports.
EXCLUDE_REASON=""
note_excluded() { # note_excluded <stage> <file> <reason>
    excluded=$((excluded + 1))
    [[ "${VERBOSE:-}" == "1" ]] && printf 'exclude %-8s %-46s %s\n' "$1" "${2#$CALCIUM_LANG/}" "$3" >&2
}

have_component() { # have_component <name>
    # Every component module carries `func implemented()`; the CLI does not
    # surface it yet, so read the source. This stays honest before and after a
    # component lands.
    grep -q 'func implemented() = true' "$ROOT/$1/mod.ca" 2>/dev/null
}

# --- Stage 0: type checker ---------------------------------------------------
# The checker only has observable output on inputs with annotations, so it is
# compared on the fixture corpus in tests/typecheck (which deliberately contains
# mismatches) rather than on the main corpus.

run_check() {
    if ! have_component typechecker; then
        echo "skip check (type checker not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files
    mapfile -t files < <(find "$ROOT/tests/typecheck" -name '*.ca' | sort)
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "skip check (no fixtures)"
        skip=$((skip + 1))
        return 0
    fi
    local f out_oracle out_cand
    # The fixtures carry the mismatches; the corpus checks that the checker stays
    # quiet where the reference is quiet, which is where a false positive would
    # show up.
    mapfile -t files < <( { printf '%s\n' "$ROOT/tests/typecheck"/*.ca; corpus_files; } | sort)
    for f in "${files[@]}"; do
        if ! "$ORACLE" check "$f" </dev/null >"$WORK/ck.oracle" 2>&1; then :; fi
        if ! candidate check "$f" </dev/null >"$WORK/ck.cand" 2>&1; then :; fi
        if diff -u "$WORK/ck.oracle" "$WORK/ck.cand" >"$WORK/ck.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "check: $f" "$WORK/ck.diff"
        fi
    done
}

# --- Stage 1: lexer ----------------------------------------------------------
# Compared byte for byte: the token stream (kind, literal and byte position) is
# fully determined by the source.

run_lex() {
    if ! have_component lexer; then
        echo "skip lex (lexer not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files f out_oracle out_cand
    mapfile -t files < <(corpus_files)
    for f in "${files[@]}"; do
        out_oracle="$WORK/lex-oracle-$(basename "$f")"
        out_cand="$WORK/lex-cand-$(basename "$f")"

        if ! "$ORACLE" lex "$f" </dev/null >"$out_oracle" 2>&1; then
            note_excluded lex "$f" "the reference cannot lex it"
            continue
        fi
        if ! candidate lex "$f" </dev/null >"$out_cand" 2>&1; then
            fail_case "lex: $f" "$out_cand"
            continue
        fi
        if diff -u "$out_oracle" "$out_cand" >"$WORK/lex.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "lex: $f" "$WORK/lex.diff"
        fi
    done
}

# --- Stage 2: formatter -------------------------------------------------------
# Compared byte-for-byte: a given program has exactly one correct formatting.

run_fmt() {
    if ! have_component formatter; then
        echo "skip fmt (formatter not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files f base out_oracle out_cand
    mapfile -t files < <(corpus_files)
    for f in "${files[@]}"; do
        base=$(basename "$f")
        out_oracle="$WORK/oracle-$base"
        out_cand="$WORK/cand-$base"
        cp "$f" "$out_oracle" 2>/dev/null || { note_excluded fmt "$f" "unreadable"; continue; }

        if ! "$ORACLE" fmt "$out_oracle" >/dev/null 2>&1; then
            note_excluded fmt "$f" "the reference cannot parse it"
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
    done
}

# --- Stage 4: the self-hosted VM ---------------------------------------------
# Compiles with the self-hosted compiler and runs the result on the self-hosted
# interpreter, comparing against the reference.
#
# Files outside the VM's scope, with the reason:
#   async_*.ca     need the event scheduler: the reference runs it on goroutines
#                  and channels, and supplies event sources such as
#                  schedule.timeout natively. Reimplementing that in Calcium is
#                  the open question D2; the interpreter does not attempt it.
#   constraint.ca  needs the static constraint checker (D13).
#
#   *_constraint.test.ca
#                  need the static checker as well (D13): they assert on the
#                  reference's compile errors, whose text is not contractual.
#   tco.test.ca    runs: correct but slow. One interpreted iteration costs ~0.75 ms
#                  (measured, linear; 20000 deep returns the right answer in 15 s),
#                  so this case alone takes ~40 s. There is no timeout here, only
#                  wall-clock cost, and dropping it would hide a real capability.
#
# tests/*.test.ca are included now that local modules load: the loader reads
# `test/mod.ca`, compiles it with the self-hosted compiler and runs it on the same
# VM, so `use test;` resolves the same way it does for the reference.
vm_corpus() {
    find "$CALCIUM_LANG/examples" -name '*.ca' | sort
    find "$CALCIUM_LANG/tests" -name '*.test.ca' | sort
    # The `test` module's own suite: it exercises the framework's helpers, which
    # need the FFI primitives the loader now fills in.
    echo "$CALCIUM_LANG/test/mod.test.ca"
}

vm_excluded() {
    EXCLUDE_REASON="excluded by policy (see the comments above)"
    case "$(basename "$1")" in
        async_*.ca) EXCLUDE_REASON="async: needs the host event scheduler (D2)"; return 0 ;;
        constraint.ca) EXCLUDE_REASON="needs the static constraint checker (D13)"; return 0 ;;
        constraint.test.ca|function_constraint.test.ca|primitive_constraint.test.ca)
            EXCLUDE_REASON="needs the static constraint checker (D13)"; return 0 ;;
        # factorial.ca contains a `match n` whose arms are `0` and `true`; from n=1
        # no arm matches. The reference stops after the first line and still exits 0
        # because its VM drops the runtime error silently. The candidate reports the
        # no-match and exits 1, which is the behaviour we want to keep, so the two
        # differ on purpose.
        factorial.ca)
            EXCLUDE_REASON="the reference drops the runtime error silently"; return 0 ;;
        # csv/mod.test.ca fails in both implementations, but the reference's message
        # names its own source position; diagnostic text is not contractual.
        mod.test.ca) [ "$(dirname "$1")" = "$CALCIUM_LANG/csv" ] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

run_vm() {
    if ! have_component vm; then
        echo "skip vm (self-hosted VM not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files f out_oracle out_cand st_oracle st_cand
    out_oracle="$WORK/vm-oracle.out"
    out_cand="$WORK/vm-cand.out"
    mapfile -t files < <(vm_corpus)
    for f in "${files[@]}"; do
        if vm_excluded "$f"; then
            note_excluded vm "$f" "$EXCLUDE_REASON"
            continue
        fi
        ( cd "$CALCIUM_LANG" && "$ORACLE" "$f" ) >"$out_oracle" 2>&1
        st_oracle=$?
        if [[ $st_oracle -ne 0 ]]; then
            note_excluded vm "$f" "the reference cannot run it"
            continue
        fi
        candidate run "$f" </dev/null >"$out_cand" 2>&1
        st_cand=$?
        if [[ $st_oracle -ne $st_cand ]]; then
            {
                echo "exit status: oracle=$st_oracle candidate=$st_cand"
                echo "--- oracle output ---"; head -20 "$out_oracle"
                echo "--- candidate output ---"; head -20 "$out_cand"
            } >"$WORK/vm.diff"
            fail_case "vm: $f" "$WORK/vm.diff"
        elif diff -u "$out_oracle" "$out_cand" >"$WORK/vm.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "vm: $f" "$WORK/vm.diff"
        fi
    done
}

# --- Stage 3: compiler --------------------------------------------------------
# Behaviour is compared, not bytes: run the oracle's output and the candidate's
# output and compare stdout, and whether each succeeded.

# Files the compile stage cannot compare, with the reason:
#   async_spawn.ca    reads a task's status right after spawning it, so its output
#                     depends on goroutine scheduling -- the reference's own
#                     bytecode prints "pending", "running" or "completed" on
#                     different runs.
#   constraint.ca     expects a compile error from the static constraint checker,
#                     which is not implemented yet; the candidate runs it instead.
compile_excluded() {
    EXCLUDE_REASON="excluded by policy (see the comments above)"
    case "$(basename "$1")" in
        async_spawn.ca) EXCLUDE_REASON="non-deterministic in the reference too"; return 0 ;;
        constraint.ca) EXCLUDE_REASON="needs the static constraint checker (D13)"; return 0 ;;
        *) return 1 ;;
    esac
}

run_compile() {
    if ! have_component compiler; then
        echo "skip compile (compiler not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files f base bone out_oracle out_cand st_oracle st_cand
    mapfile -t files < <(corpus_files)
    for f in "${files[@]}"; do
        if compile_excluded "$f"; then
            note_excluded compile "$f" "$EXCLUDE_REASON"
            continue
        fi
        base=$(basename "$f")
        bone="$WORK/cand-$base.bone"
        out_oracle="$WORK/run-oracle-$base"
        out_cand="$WORK/run-cand-$base"

        # Only compare programs the reference itself can run. Its top-level
        # compiler does not see the `__` primitives, so the stdlib sources fail
        # to compile when run directly, and files it rejects statically (such as
        # constraint.ca) are outside this stage until the static checker exists.
        # The reference resolves local modules relative to the corpus root when
        # it runs source, but relative to the working directory when it runs a
        # .bone, so both sides run from there.
        ( cd "$CALCIUM_LANG" && "$ORACLE" "$f" ) >"$out_oracle" 2>&1
        st_oracle=$?
        if [[ $st_oracle -ne 0 ]]; then
            note_excluded compile "$f" "the reference cannot run it"
            continue
        fi

        if ! candidate compile "$f" -o "$bone" >"$WORK/cc.err" 2>&1; then
            fail_case "compile: $f" "$WORK/cc.err"
            continue
        fi
        ( cd "$CALCIUM_LANG" && "$ORACLE" "$bone" ) >"$out_cand" 2>&1
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
    done
}

# --- Stage: .bone round trip --------------------------------------------------
# A program compiled by the candidate has to be readable by the candidate. This
# compiles each supported example, reads the .bone back and compares the run with
# the reference executing the source - so it covers the writer and the reader.
run_bone() {
    if ! have_component vm || ! have_component serialize; then
        echo "skip bone (serialize/vm not implemented)"
        skip=$((skip + 1))
        return 0
    fi
    local files f out_oracle out_cand st_oracle st_cand
    out_oracle="$WORK/bone-oracle.out"
    out_cand="$WORK/bone-cand.out"
    # Examples only: a .bone carries no `use` list, and the *reference* cannot
    # resolve a local module from a compiled file either ("module 'test' not
    # found"), so there is nothing to compare against.
    mapfile -t files < <(find "$CALCIUM_LANG/examples" -name '*.ca' | sort)
    for f in "${files[@]}"; do
        if vm_excluded "$f"; then
            note_excluded bone "$f" "$EXCLUDE_REASON"
            continue
        fi
        ( cd "$CALCIUM_LANG" && "$ORACLE" "$f" ) >"$out_oracle" 2>&1
        st_oracle=$?
        if [[ $st_oracle -ne 0 ]]; then
            note_excluded bone "$f" "the reference cannot run it"
            continue
        fi
        candidate compile "$f" -o "$WORK/one.bone" >/dev/null 2>&1
        candidate run "$WORK/one.bone" </dev/null >"$out_cand" 2>&1
        st_cand=$?
        if [[ $st_oracle -ne $st_cand ]]; then
            {
                echo "exit status: oracle=$st_oracle candidate=$st_cand"
                echo "--- oracle output ---"; head -20 "$out_oracle"
                echo "--- candidate output ---"; head -20 "$out_cand"
            } >"$WORK/bone.diff"
            fail_case "bone: $f" "$WORK/bone.diff"
        elif diff -u "$out_oracle" "$out_cand" >"$WORK/bone.diff" 2>&1; then
            pass=$((pass + 1))
        else
            fail_case "bone: $f" "$WORK/bone.diff"
        fi
    done
}

# --- Main ---------------------------------------------------------------------

echo "reference: $CALCIUM_LANG"
echo "oracle:    $ORACLE ($("$ORACLE" version 2>/dev/null | head -1))"
echo "corpus:    $CORPUS"
echo

lint_self || exit 1
run_check
run_lex
run_fmt
run_compile
run_vm
run_bone

echo
if [[ $fail -eq 0 ]]; then
    echo "PASS ($pass passed, $skip stage(s) skipped, $excluded corpus file(s) excluded)"
    [[ $skip -gt 0 && "$STRICT" == "1" ]] && {
        echo "error: STRICT=1 but $skip stage(s) were skipped" >&2
        exit 1
    }
    exit 0
fi

echo "FAIL ($pass passed, $fail failed, $skip stage(s) skipped, $excluded excluded)"
printf '  - %s\n' "${failures[@]}"
exit 1

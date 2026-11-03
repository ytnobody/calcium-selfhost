# Corpus exclusions

The differential harness compares this implementation against the reference over
the corpus. Some files cannot be compared, and every one of them is listed here
with the reason. Nothing is skipped silently: the summary line prints the count,
and `VERBOSE=1` prints each entry.

```
$ VERBOSE=1 bash tests/differential.sh 2>&1 | grep '^exclude'
```

Current state:

```
PASS (229 passed, 0 stage(s) skipped, 33 corpus file(s) excluded)
```

The 33 is a count of *stage exclusions*, not of files: a file excluded from both
the `vm` and the `bone` stage counts twice. **22 distinct files** are affected.

| Stage | Exclusions |
|---|---|
| `lex` | 0 |
| `fmt` | 1 |
| `check` | 0 |
| `compile` | 16 |
| `vm` | 8 |
| `bone` | 8 |

Note what this means: `lex` and `check` compare **every** corpus file, and `fmt`
compares all but `io.ca` (group E). The exclusions below are about *running* a
program, which needs both implementations to agree on what a program's output is.

---

## A. `async` — 6 files, in the `vm` and `bone` stages (12 entries)

`async_all.ca`, `async_cancel.ca`, `async_handler.ca`, `async_interval.ca`,
`async_spawn.ca`, `async_timeout.ca`

The reference schedules these on goroutines and channels and supplies event
sources such as `schedule.timeout` natively. Reproducing that in Calcium is the
open design question **D2**; `docs/ASYNC.md` records the analysis, the options and why
it is deferred (issue #3). The compiler emits the opcodes already — `async_timeout.ca`
compiles — and the VM stops at the first one with `unsupported opcode 51`.

`lex`, `fmt` and `check` still compare all six.

## B. Static constraint checking — 4 files (6 entries)

| File | Stages |
|---|---|
| `examples/constraint.ca` | `vm`, `compile`, `bone` |
| `tests/constraint.test.ca` | `vm` |
| `tests/function_constraint.test.ca` | `vm` |
| `tests/primitive_constraint.test.ca` | `vm` |

These are programs that are *supposed* to fail compilation. Verifying the
candidate would mean matching the reference's diagnostic text, and `SPEC.md` §3
declares that text non-contractual (**D13**, tracked as issue #2). The checker itself exists and is
compared on `tests/typecheck/` plus the whole corpus, where it agrees.

`lex`, `fmt` and `check` still compare all four.

## C. Sources the reference cannot execute — 14 files, `compile` stage only

```
pkg/vm/stdlib/core/assert.ca    pkg/vm/stdlib/core/os.ca
pkg/vm/stdlib/core/bytes.ca     pkg/vm/stdlib/core/regex.ca
pkg/vm/stdlib/core/http.ca      pkg/vm/stdlib/core/string.ca
pkg/vm/stdlib/core/io.ca        pkg/vm/stdlib/core/time.ca
pkg/vm/stdlib/core/json.ca      pkg/vm/stdlib/core/toml.ca
pkg/vm/stdlib/core/math.ca      pkg/vm/stdlib/core/types.ca
test/mod.ca                     csv/mod.test.ca
```

The reference's *top-level* compiler does not register the `__` primitives these
modules are written against, so running them directly fails there. The candidate
loads them through its module loader, which does supply the primitives (**D21**),
so there is nothing to compare against.

Whether a compiled file should be able to carry that list is issue #7.

These files are the densest Calcium in the repository, and they are compared in
`lex`, `fmt` and `check` like any other file — only the *run* comparison is
impossible.

## D. `examples/factorial.ca` — `vm` and `bone` (2 entries)

```calcium
func factorial(n) = match n
    0 => 1
    true => n * factorial(n - 1);
```

From `n = 1` no arm matches. The reference stops after printing the first line and
still exits 0, because its VM drops the runtime error silently; this implementation
reports `runtime error: no match arm matched ...` and exits 1 (**D20**).
Reproducing a silent truncation is not worth matching.

## E. `pkg/vm/stdlib/core/io.ca` — `fmt` stage (1 entry)

The file uses `++`, which both lexers split into two `+` tokens; the reference
rejects it, so it cannot format its own file. This implementation now reports
`parse errors` for the same reason (**D15**), which is why the `check` stage
compares it successfully.

## F. `examples/async_spawn.ca` — `compile` stage (1 entry)

Non-deterministic in the reference itself: it reads a task's status immediately
after spawning, so the reference's own bytecode prints `pending`, `running` or
`completed` on different runs. Excluded here as well as in the `vm`/`bone` stages
(see A).

---

## Regenerating this list

```bash
ORACLE=/tmp/calcium-ck CALCIUM_LANG=/path/to/calcium-lang \
  VERBOSE=1 bash tests/differential.sh 2>&1 | grep '^exclude'
```

The reasons are attached where each exclusion is decided, in
`tests/differential.sh` (`note_excluded`, `vm_excluded`, `compile_excluded`).

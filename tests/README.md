# Tests

`differential.sh` is the only test entry point. It compares this
implementation against the reference implementation.

```bash
# Local: use a checkout of calcium-lang as both the oracle source and corpus
go build -C ../calcium-lang -o /tmp/calcium ./cmd/calcium
ORACLE=/tmp/calcium CALCIUM_LANG=../calcium-lang bash tests/differential.sh
```

## What is compared

| Stage | Comparison | Verdict |
|---|---|---|
| always | `calcium lint` over every `.ca` in this repository | must pass |
| type checker | `calcium check` findings per fixture in `tests/typecheck/` | identical positions and rules |
| lexer | `calcium lex` token dump per corpus file | byte-identical |
| formatter | `calcium fmt` output per corpus file | byte-identical |
| formatter | `calcium fmt` output, on a copy of each corpus file | byte-identical |
| compiler | compile with the candidate, run the result on the reference VM | same stdout, same exit status |
| VM | run with the candidate VM (`main.ca run`) | same stdout, same exit status |

The compiler stage runs both sides from the corpus root, because the reference
resolves local modules relative to the working directory when it runs a `.bone`,
and skips corpus files the reference itself rejects or cannot compare (see the
`compile_excluded` list and the comments there).

The compiler comparison deliberately does **not** compare bytecode. Optimisation
passes are unspecified (`calcium-lang/specs/bone-format.md` §6), so two correct
compilers may emit different instruction streams. Only behaviour is contractual
(`SPEC.md` §3).

The formatter comparison *is* byte-identical: there is exactly one correct
formatting of a given program.

## Corpus

Consumed from the reference checkout, never copied here:

* `examples/*.ca`
* `tests/*.test.ca` — 16 files
* `csv/*.ca`

Files the reference itself cannot run or format are skipped rather than failed,
so a pre-existing problem in the corpus does not look like a candidate
regression. (`examples/constraint.ca` intentionally fails with constraint
violations; `examples/fibonacci.ca` rebinds an immutable variable.)

## Environment

| Variable | Meaning |
|---|---|
| `ORACLE` | path to the reference `calcium` binary (required) |
| `CALCIUM_LANG` | path to the reference checkout (default `../calcium-lang`) |
| `CORPUS` | corpus root override (default `$CALCIUM_LANG`) |
| `FILTER` | bash regex; only corpus files matching are run |
| `STRICT` | `1` to fail when a stage has nothing to compare |

## Adding a comparison

1. Add a `run_*` function.
2. Gate it on `have_component <name>`, which reads
   `func implemented() = true` from `<name>/mod.ca`. A component that has not
   landed yet must *skip*, not pass silently.
3. Compare behaviour, not implementation output, unless the artifact is
   canonical (like formatted source).

Every file the harness cannot compare is listed in
[`../docs/EXCLUSIONS.md`](../docs/EXCLUSIONS.md) with its reason; `VERBOSE=1`
prints the same list from a run.

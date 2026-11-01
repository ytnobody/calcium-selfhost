# Calcium, written in Calcium.

A from-scratch reimplementation of the Calcium toolchain in Calcium itself.

**Status: compiler implemented.** The lexer's token stream and the formatter's
output match the reference byte for byte, and the compiler's output behaves
identically on every comparable corpus file. See `SPEC.md` for the stage plan.

The Go implementation in [`calcium-lang`](https://github.com/ytnobody/calcium-lang)
is the **reference implementation** and the source of truth for the language
specification, the bytecode format, and the native boundary.

## Why a separate repository

The reference implementation and this one have different lifecycles. Keeping
them apart lets the Go implementation stay small and stable as the reference,
and makes the eventual switchover a visible event rather than an ambiguous
in-place replacement.

What is deliberately *not* duplicated here: the language specification, the
`.bone` format, the native-boundary contract, and the differential-test corpus.
All four live in `calcium-lang` and are consumed from there, so they cannot
drift.

## What is in scope

| Component | Stage |
|---|---|
| lexer | SH-2, done |
| parser, AST, formatter | SH-2, done for the corpus |
| type checker | SH-2, done |
| compiler (emits `.bone`) | SH-3 |
| formatter | SH-2 |
| linter | SH-3 |
| bytecode VM | SH-4 (stretch) |
| compiler emitting `.bone` | SH-3, done for the corpus |

Out of scope, permanently: the 74 `__` primitives and the OS/library facilities
they wrap. Those are the native boundary and cannot be written in Calcium.

## Running

Everything here executes on the reference interpreter. There is no separate
toolchain to install.

```bash
# The reference interpreter (oracle)
ORACLE=/path/to/calcium

# Lint every Calcium source in this repository
$ORACLE lint */mod.ca mod.ca main.ca

# Run the CLI
$ORACLE main.ca version
```

## Tests

`tests/differential.sh` compares this implementation against the reference
implementation over the corpus in `calcium-lang`, using the oracle pinned in
`oracle.pin`.

```bash
ORACLE=../calcium-lang/calcium CALCIUM_LANG=../calcium-lang \
  bash tests/differential.sh
```

The contract is **behavioural equivalence**, not byte-identical output. See
`calcium-lang/specs/bone-format.md` §6 for why.

## Layout

```
mod.ca              library namespace
main.ca             CLI entry point
oracle.pin          reference commit the differential tests run against
lexer/ parser/ compiler/ formatter/ linter/ vm/
tests/differential.sh
docs/DECISIONS.md   open design decisions carried from the scope document
```

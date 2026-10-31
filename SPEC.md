# Implementation Contract

This repository implements Calcium in Calcium. It is the *candidate*
implementation; `calcium-lang` remains the *reference* implementation.

Normative documents, owned by the reference repository and **never copied
here**:

| Document | Path |
|---|---|
| Language specification | `calcium-lang/calcium-spec.md` |
| Reference manual | `calcium-lang/reference-manual.md` |
| `.bone` bytecode format | `calcium-lang/specs/bone-format.md` |
| Native boundary (FFI) | `calcium-lang/specs/ffi-primitives.md` |
| Self-hosting scope | `calcium-lang/specs/selfhost-scope.md` |

If any of those is ambiguous or wrong, the fix goes in the reference
repository. Do not patch around a spec gap locally.

---

## 1. Stages

| Stage | Deliverable | Done when |
|---|---|---|
| SH-2 | lexer → parser → AST → formatter → type checker | the formatter produces byte-identical output to the reference over the corpus |

SH-2 progress: **lexer done** — the token stream is byte-identical to
`calcium lex` over the whole corpus (`tests/differential.sh` compares it
per file).
| SH-3 | compiler emitting `.bone` | programs compiled by the candidate run identically under the reference VM over the corpus |
| SH-4 | bytecode VM | the candidate VM runs the corpus itself (stretch goal) |

SH-3 is the point at which the toolchain is self-hosted in practice.

## 2. CLI contract

The candidate is a Calcium program executed by the reference interpreter. The
differential harness drives it through this interface, so the shape is fixed:

```
calcium main.ca version
calcium main.ca fmt <in.ca> -o <out.ca>
calcium main.ca lex <in.ca>            # token dump, for debugging
calcium main.ca parse <in.ca>          # AST dump, for debugging
calcium main.ca compile <in.ca> -o <out.bone>
```

Exit code `0` on success, `1` on any diagnostic. Diagnostics go to stderr;
successful data output goes to the file named by `-o`.

`fmt` writes the formatted source to `-o` rather than editing in place, because
the reference `calcium fmt` edits in place and that is not comparable.

`lex` and `parse` dumps are debugging aids with no compatibility guarantee —
they may change freely and are never part of the differential contract.

## 3. Compatibility rule

**Behaviour, not bytes.**

* Programs compiled by the candidate must produce the same stdout, stderr class
  and exit code as the reference when run on the same VM.
* Bytecode need not be byte-identical. Optimisation passes are unspecified
  (`bone-format.md` §6), so two correct compilers may emit different
  instruction streams for the same source.
* Formatter output *is* compared byte-for-byte, because there is exactly one
  correct formatting of a given program.
* Diagnostic message text is **not** compared. Diagnostics must be present
  (non-zero exit) and must point at the same construct; wording may differ.

## 4. What must not be reimplemented

The native boundary (`ffi-primitives.md`). Concretely, the candidate must call
the existing `__`-prefixed primitives rather than trying to provide them. Any
design that requires the candidate to implement `__read_file` or `__time_now`
is out of scope by definition.

## 5. The oracle pin

`oracle.pin` holds the `calcium-lang` commit the differential tests run
against. Rules:

1. The pin is a **commit SHA**, never a branch or tag. Branches move; a moving
   oracle makes failures unreproducible.
2. Bumping the pin is a normal, reviewed change: bump it, run the harness, fix
   whatever semantic change broke, commit both.
3. The pin must be a commit where the reference test suite is green.

## 6. Open decisions

Tracked in `docs/DECISIONS.md`. Nothing in SH-2 or SH-3 may be built on an
unresolved decision.

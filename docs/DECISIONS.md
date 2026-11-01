# Decisions

Open questions that block or shape the implementation, plus gaps discovered in
the reference implementation while scoping the work.

An item marked **open** must be resolved before the stage that depends on it.
An item marked **fixed upstream** was found from this repository and corrected in
`calcium-lang`. Items marked **accepted** are known limitations with a
recorded workaround.

---

## D1 — Value representation (open, blocks SH-4)

`value.go` has 23 `TYPE_*` variants. In a self-hosted VM those values *are*
Calcium values, so `value.go` disappears — except for the variants wrapping host
pointers: `TYPE_TASK`, `TYPE_CHANNEL`, `TYPE_EVENT_SOURCE`, `TYPE_SECRET`,
`TYPE_SECRET_CAPABILITY`.

Decide which stay as opaque handles threaded through the native boundary. This
determines the VM's value model and therefore what SH-3 must emit.

## D2 — Async runtime (open, blocks SH-4)

The reference VM has ~35 `go func`/`chan` sites implementing the async runtime,
and Calcium's own `async.*` is built on top of it. A Calcium VM would nest async
inside async.

Options: keep the scheduler native (opaque handles, D1) or implement it in
Calcium on top of the host scheduler. The latter is the more interesting result
but has a much worse failure mode.

## D3 — LSP timing (open, no blocker)

`lsp` (1,042 Go LOC) depends only on `lexer`/`parser`/`ast`/`token`, so it is
nearly free after SH-2 and is excellent dogfooding. Undecided whether to pull it
into scope.

---

## D4 — ADT patterns silently treat literal payloads as bindings (**fixed upstream**)

Found while writing `main.ca`, fixed in `calcium-lang` by
`feat(lang): match literal payloads in constructor patterns`.

A constructor pattern used to treat *every* field token as a binding name, so a
literal payload became a variable instead of a value to match against:

```calcium
match Maybe.Some(99)
    Maybe.Some(5) => "matched"   // matched! `5` was a binding, not a literal
    _ => "other"
```

Numeric and string payloads could not be matched at all, and the only visible
symptom was a name collision:

```calcium
match get(args, 2)
    Maybe.Some("version") => concat("v=", version()) !> io.say
// runtime error: cannot call value of type string as a function
// `version` was shadowed by a binding holding the string "version"
```

A payload position is now a binding name, `_`, or a literal matched by value;
anything else is a parse error. A literal payload works in any arm, including the
final one, because every arm is conditional (see D7).

Still open from the same area: a bare identifier in a match arm is compiled as an
expression to compare, not as a catch-all binding, so there is no "bind the rest"
pattern. Use `_` and read the value from an outer variable.

`main.ca` now uses the natural form for command dispatch.

## D5 — `hash_set` is O(n) (accepted, revisit at SH-3)

Measured: 5,000 `hash_set` calls take 1.64 s, because the operation copies the
whole hash. Symbol tables built this way will be quadratic.

Immutable cons lists are O(n) as a workaround (100,000-element build plus reverse
takes 139 ms), and local scopes are small, so this is accepted for SH-2. If SH-3
turns out to need a global mutable map, the fix belongs in the reference
implementation's native boundary, not in a local workaround.

## D6 — Bytecode emission needs a bulk conversion (expected, SH-3)

`push` is O(n) as well, so instructions cannot be accumulated one element at a
time. The intended approach is to build an immutable list of opcode values and
convert it to bytes once. That conversion has no primitive today; add one to the
native boundary when SH-3 needs it, rather than adding a general mutable buffer.

## D7 — The final match arm is an implicit catch-all (**fixed upstream**)

Found while fixing D4, fixed in `calcium-lang` by
`fix(lang): make every match arm conditional`.

`compileMatch` only emitted a conditional jump for non-final arms: the final
arm's tag check was popped and discarded, so **the final arm always ran**,
whatever its constructor.

```calcium
match tok
    Token.Ident(name) => ...
    Token.Int(n)     => ...
    Token.Other      => ...   // ran even when tok was Token.Ident
```

For a parser this was a landmine: the final arm's body ran with unbound payload
variables, producing silent nonsense rather than a diagnostic.

**Decision: every arm is conditional; if none matches, the match raises a
runtime error** naming the value, via a new appended opcode `OpMatchFail` (85).
Alternatives rejected:

- *Require the final arm to be `_`*: fully static and easy to check, but it
  forbids genuinely exhaustive matches, needs a syntactic special case, and
  would have to be relaxed once exhaustiveness checking exists.
- *Return `failure(...)`*: makes every non-Result context depend on match
  exhaustiveness, which the type system cannot track.
- *Keep the implicit catch-all*: this is what silently ran the wrong branch.

Consequences for SH-2: an unhandled token now fails loudly with the offending
value in the message, which is what a parser needs. Always end a `match` on `_`
for a total function.

The `.bone` format gained opcode 85 (`bone-format.md` §5.1); it is emitted only
when the final arm can reject, so exhaustive matches are unchanged.

## D10 — A nested match swallowed the enclosing match's arms (**fixed upstream**)

Found while migrating dependent modules after D7. An arm body may contain another
`match`, but the inner match's case loop only stopped at `;` or EOF, so it also
consumed the enclosing match's following arms:

```calcium
func f(x, y) = match x
    true => match y
        true => 1
        false => 2
    false => 3;        // attached to the *inner* match
```

The outer match was left with a single `true` arm. Because the final arm used to
run unconditionally (D7), the mis-parse was invisible: `f(false, true)` silently
returned a value from the inner match.

Fixed by `fix(parser): don't let a nested match swallow the enclosing match's
arms`: case parsing is layout-disambiguated. A case indented further left than
the current match's first case belongs to an enclosing match. The rule only ever
stops parsing earlier, so previously-correct code is unaffected, and parentheses
still delimit a nested match where layout cannot.

Relevance to SH-2: the parser will nest `match` heavily, so this had to be
resolved before writing it — the same reason D7 was decided first.

## D11 — Writing a parser in Calcium: three ergonomics limits (open, SH-2)

Discovered while writing the lexer. None blocks the lexer, but each will shape
the parser and is cheap to fix now.

1. **A `match` cannot be delimited inside parentheses or as an argument.** Case
   parsing stops only at `;`, EOF or a shallower column, so
   `f(match x a => 1 b => 2)` is a parse error, and
   `(match x a => 1 b => 2)` likewise unless a `;` or `)` newline happens to be
   at a shallower column. Workaround used in the lexer: extract a named helper
   function. A `match ... end` form would remove the ambiguity entirely.

2. **Nested `do` blocks need their own `end`, and the diagnostic is poor.**
   Forgetting an inner `end` produced `expected identifier before '=>'` followed
   by `unexpected end of file inside do block`, pointing away from the mistake.

3. **Cross-module ADT destructuring requires an upper-case namespace.** A
   qualified constructor pattern is only recognised when both the namespace and
   the constructor start with an upper-case letter (`Maybe.Some`), because the
   parser keys on `isUpperCase`. `lexer.TokCons(t, rest)` therefore parses as a
   member access, not a pattern, and binds nothing. Workaround: the module
   exposes `first`/`rest` accessors returning `Maybe`, and consumers match on
   `Maybe.Some`. Either the case rule should be relaxed to "the token after the
   dot is upper-case", or namespaces should be upper-case by convention.

The lexer itself needed none of these fixes: it is a pure function returning a
token list, with the list kept opaque to `main.ca`.

## D12 — Tail calls were only optimized in the final match arm (**fixed upstream**)

Found while writing the lexer: a 60 KB file overflowed the 8,192-frame limit
because the token loop recursed inside a `true` arm.

`OpTailCall` was produced by a peephole that looked only at the instruction just
before the function's `OpReturn`. A non-final match arm ends with a jump that
skips the remaining arms, so the call before it was never converted:

```calcium
func loop(n, acc) = match n <= 0
    true => acc
    false => loop(n - 1, acc + 1);   // grew the stack
```

That is the ordinary shape for recursive descent, so it blocked SH-2.

Fixed upstream by `fix(compiler): optimize tail calls in any match arm`: tail
position is tracked through match arms, `do` block final expressions and
`return`, and any node compiled in tail position whose value ends in a call has
that call rewritten. Side effect worth knowing: mutual recursion between the
lexer's scanners is now flat too, so long string literals and heredocs no longer
risk the frame limit.

Verified: 12 KB, 62 KB and 125 KB inputs lex in 0.16 s, 0.75 s and 1.44 s
(linear), all byte-identical to the reference.

## D13 — The type checker (**done**)

Implemented, with the verification gap addressed:

1. `calcium check <file>` in the reference prints `<line>:<column>\ttype` per
   finding plus a `<file>: N finding(s)` trailer (position and rule only; the
   message is diagnostic and not contractual).
2. `tests/typecheck/` holds twelve fixtures with deliberate mismatches:
   annotated assignments, Any compatibility, arithmetic and string inference,
   identifier environments, return types, parameter types, do blocks, matches
   (always Any), constraint annotations (not types), and prefix/bitwise
   operators.
3. `typechecker/mod.ca` mirrors the reference: same three check sites, same
   inference rules, `Any` compatible with everything.
4. `tests/differential.sh` compares all twelve fixtures; the harness reports
   112 passing comparisons with no skipped stage.

Original deferral rationale, kept for the record:

`typechecker` (303 Go lines) reports gradual-type mismatches through
`calcium lint`. Across the whole corpus it produces **zero findings**
(`static` 135, `parse` 5, `type` 0), so a differential test cannot distinguish a
correct implementation from an empty one, and its messages are explicitly not
contractual (`SPEC.md` §3).

Implementing it would also require keeping type annotations on the AST, which the
parser currently drops for the formatter's benefit.

Decision: deferred. If it is taken up, it needs its own fixture corpus of small
programs with deliberate mismatches plus a reference command that dumps
findings as `line:column rule` (position and rule only, not message text).

SH-3 note: `constraint.ca` is excluded from the compile stage for the adjacent
reason — the reference rejects it with a static-constraint error, and that
checker is the piece that is not implemented.

## D15 — Parse errors are not reported by the candidate parser (open)

`typechecker`'s `check` command reports `parse errors` for a file the reference
parser rejects, and the candidate is more permissive: `pkg/vm/stdlib/core/io.ca`
uses `++`, which both lexers split into two `+` tokens, but the candidate's
expression parser falls back to a wildcard instead of failing. That is the same
fallback that keeps the parser from hanging (see D14).

Consequence: on the 57-file corpus the check outputs agree on 56; `io.ca`
differs only in that line. The harness's check stage runs the fixtures, which do
not exercise parse errors.

Implementing parse-error *reporting* would mean tracking a failure flag through
the parser and surfacing it in `main.ca`; the `check` command would then print
`<file>: parse errors` to match. Not started.

## D16 — SH-4 (a VM in Calcium) is started, not finished (open, stretch goal)

`vm/mod.ca` now holds the groundwork: the runtime value wrappers Calcium cannot
express (closures, builtins, ADT values, host functions), the operand stack, the
frame model, constant decoding and the operand-width table that the `.bone`
format leaves implicit. The interpreter loop itself is **not written yet**, so
this component is not marked implemented and the harness does not run it.

Two things make SH-4 harder than SH-3, and both need a decision first:

1. **There is no way to read a `.bone` from Calcium.** The slice avoids this by
   interpreting the compiler's in-memory structures, which also makes the VM
   testable without writing a deserializer. A standalone `run <file.bone>` would
   need one.
2. **The host's module loader is unreachable.** A Calcium program cannot ask the
   reference VM to load `core.io`, so observable output needs either a registry
   of Calcium-implemented modules (the sketch in `vm/mod.ca`) or a native hook.
   Without one, a compiled program can compute but cannot print, which means no
   differential test can see its result.

Proposed next steps, in order:

1. Write the dispatch loop for the opcode subset the compiler emits today
   (constants, globals/locals, arithmetic, comparisons, jumps, calls, closures,
   arrays/hashes/tuples/index/member, builtins, ADT construction and matching).
2. Verify with `main.ca run <in.ca>`: compile with the self-hosted compiler, run
   with the self-hosted VM, and compare against the reference run.
3. Extend the module registry until the corpus passes, then decide whether a
   `.bone` reader is worth adding.

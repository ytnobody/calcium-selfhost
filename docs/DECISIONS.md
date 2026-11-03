# Decisions

Open questions that block or shape the implementation, plus gaps discovered in
the reference implementation while scoping the work.

An item marked **open** must be resolved before the stage that depends on it.
An item marked **fixed upstream** was found from this repository and corrected in
`calcium-lang`. Items marked **accepted** are known limitations with a
recorded workaround.

---

## D1 — Value representation (**decided**)

The original question was which host-pointer variants (`TYPE_TASK`, `TYPE_CHANNEL`,
`TYPE_EVENT_SOURCE`, `TYPE_SECRET`, `TYPE_SECRET_CAPABILITY`) must survive as opaque
handles threaded through the native boundary.

The answer, after the interpreter was written: **none of them, because none of those
values can be produced by the programs this toolchain runs.**

- async (tasks, channels, event sources) is out of scope — D24, `docs/ASYNC.md`.
- `Secret.with` cannot be reached: nothing in the language creates a capability — D22.

So the model in use is simply:

1. **A Calcium value is a Calcium value.** Integers, floats, strings, booleans,
   arrays, hashes, `success`/`failure` and native `Maybe` are used directly; there is
   no parallel value struct, and therefore no marshalling at the boundary.
2. **Only what Calcium cannot express is wrapped**, in one ADT at the top of
   `vm/mod.ca`:

   ```calcium
   type Value =
       Closure(record, free, consts, mod) |   // a compiled function plus its unit
       BuiltinFn(index) |                     // one of the 35 builtin slots
       AdtVal(type_name, tag, items) |        // an ADT held as a constant
       HostFn(name);                          // a native function reached by name
   ```
3. **Constants have their own representation** (`serialize.Constant`: bool, int,
   float, string, function record, ADT, regex), because they come from the bytecode
   pool rather than from the program.
4. **A closure names its unit instead of holding its globals** (D17), which keeps
   values finite and printable.

Consequences, already visible in the code: `is_callable` has to know the four
wrappers (any host predicate cannot see them), `to_string` has to render them by hand
(`vm_to_string`), and the module registry is a table of `HostFn`s rather than native
module objects.

## D2 — Async runtime (**deferred**, see D24)

The reference VM has ~35 `go func`/`chan` sites implementing the async runtime,
and Calcium's own `async.*` is built on top of it. A Calcium VM would nest async
inside async.

Options: keep the scheduler native (opaque handles, D1) or implement it in
Calcium on top of the host scheduler. The latter is the more interesting result
but has a much worse failure mode.

**Resolved as "deferred"** in D24, with the full analysis in `docs/ASYNC.md`: the
toolchain self-hosts without async, and the wait primitive would be an upstream FFI
change. The recommended path if it is ever needed is the first option.

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

## D25 — `.bone` records no module list (**accepted**)

A compiled program names its modules only where it uses them: `OpLoadModule` carries
a constant holding the path. There is no header list, so resolution happens at load
time through the implementation's search path — which is why a program that needs a
local module (`use test;`) can only be run from a `.bone` where that module is
reachable, exactly as in the reference (`module error: module 'test' not found`).

Recording the list was considered and rejected: implementations resolve modules
differently (search path, cache, registry), a stale list would shadow a module that
changed after compilation, and the format is shared contract rather than a place to
encode a search path.

The `.bone` stage is therefore limited to `examples/`, and the reasoning is now part
of the format specification (`specs/bone-format.md` §3.2 in `calcium-lang`, branch
`docs/bone-module-resolution`) instead of only living in this repository's notes.

## D24 — Async stays out of scope, with the analysis written down (**accepted**)

The six `async_*` examples need task/scheduler opcodes that are part of the frozen
bytecode format (`OpSpawn`, `OpStayBegin`, `OpStayGetState`, `OpContinue`,
`OpStayEnd`) plus a timer source, which the reference supplies as a *native*
`core.schedule` module. `docs/ASYNC.md` records what that means for this
implementation: the compiler already emits the opcodes, the VM stops at the first
one with `unsupported opcode 51`, and the realistic implementation is option A
(keep the scheduler native, add the opcodes and two or three primitives).

It is deferred because the toolchain self-hosts without it, and because the wait
primitive would be an upstream FFI change. The trigger to revisit and the
acceptance criteria are in `docs/ASYNC.md`.

## D23 — Constraint checks: dynamic done, static open (**partly done**)

Constraints have two halves, and they were both missing.

**Dynamic (done).** `OpCheckConstraint` was not implemented in the VM, so any
`value |> Constraint?` aborted with `unsupported opcode 46`; and the built-in type
constraints (`Int?`, `Function?`, `Positive?`, …) were registered as builtins 16-34
but implemented with unguarded comparisons (`args[0] > 0` raises on a string) and
with `types.is_function`, which cannot see the interpreter's own closures. The VM
now implements the opcode, mirrors the reference's truthiness, and the constraint
predicates are type-guarded and wrapper-aware. The three `tests/*_constraint.test.ca`
suites match the reference as a result.

**Static (decided: not worth doing now).** The reference rejects `safe_sqrt(-4)` at
*compile* time by evaluating constraints over literal arguments
(`pkg/compiler/static_constraint.go`, 827 Go lines: literal evaluation, const
tracking, composite constraint expansion). The candidate checks at run time instead,
so the outcome is `failure(-4)` rather than a compile error.

Three measurements say porting it buys nothing:

1. **`check` already agrees.** Both implementations report
   `examples/constraint.ca: 0 finding(s)` — the static check is not part of `check`.
2. **The compared output cannot be matched.** The reference's message is
   `line 71, column 20:` + a caret line + the source line + the constraint text, and
   the harness compares raw output. Reproducing it needs the *position of the
   argument expression*, and the AST carries no positions for expressions at all
   (`ast/mod.ca` has no line/column fields; only annotations do).
3. **The file is excluded anyway.** `examples/constraint.ca` is out of the `vm`,
   `compile` and `.bone` stages because the reference itself exits non-zero on it.

So the static evaluator would add ~800 lines of literal evaluation and still compare
zero additional behaviour. It becomes worth doing if expressions ever gain positions
for another reason — better diagnostics generally would be that reason — at which
point the evaluator can follow the decomposition in issue #2.

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

## D15 — Parse errors (**done**)

The parser is total: a construct it cannot read becomes a wildcard and parsing
continues, which is what keeps it from hanging on malformed input. The price was
that a malformed program looked like a good one - `core/io.ca`'s `a ++ b` was read as
`a + (+b)`, and `x = 1 + ;` simply ran.

`parser.has_errors` now walks the tree for a wildcard where an operand belongs.
Wildcards are legitimate in three slots and those are skipped: a `do` block that ends
with `;`, a wildcard pattern, and `_` in a parameter list. Two extra markers are
needed for shapes that would otherwise look like legitimate wildcards - an arm with
no pattern at all (`=> body`), and a `match` with no arms.

`check`, `run` and `compile` all refuse such a file (`<path>: parse errors`, exit 1).
Ten malformed inputs that the reference rejects are now rejected here with the same
shape, and no corpus file is misdetected (the harness compares `check` on the whole
corpus).

An earlier version of this fix scanned the token stream for a `+` in operand
position, exploiting the fact that Calcium has no unary plus. That caught `++` and
nothing else; the tree check replaced it.

Original note:


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

## D16 — SH-4 (a VM in Calcium) (**done for the corpus**)

The two obstacles recorded here when the slice was started were both resolved
without leaving Calcium:

1. **No `.bone` reader.** The VM interprets the compiler's in-memory structures,
   which is enough for `run <in.ca>`. A standalone `run <file.bone>` would still
   need a deserializer; that remains the one open item in this area.
2. **The host's module loader is unreachable.** Modules are supplied by a registry
   (`module_value`) for `core.*`, and by the loader for local modules: it reads
   `<dir>/<name>/mod.ca`, compiles it with the self-hosted compiler, runs its
   top-level code on the same VM, and exposes its globals as the exports.

Status: `tests/array.test.ca` and eleven other suite files match the reference
line for line, and the harness compares them (see D19 for the one that is slow).

## D17 — A closure names its unit instead of holding its globals (**done**)

A module is a separate compilation unit with its own globals, so a closure has to
know which unit it came from. Storing the *array* was the obvious way and it was
wrong: the array holds the module's closures, so every closure became part of a
cycle, `Closure → globals → Closure`. Anything that walked a closure then
recursed forever - printing one with `to_string`, or passing a state that held one
to an effect function. The symptom was a `use bytecode;` program that never
returned from its first host call.

A closure now carries only the unit's *name* (`""` for the program being run) and
the loader parks each module's globals under `__globals:<path>` in the module
table; `entry_globals` resolves the array when a frame is created. Values are
therefore finite and printable, which also makes the VM debuggable.

## D18 — `core.types`, `core.json`, `core.time` forward to the host (**done**)

Those modules sit on primitives (`__json_parse`, `__time_now`, ...) that the
self-hosted compiler cannot see, so loading their `.ca` sources is not an option.
The VM loads them itself and forwards each member, which keeps their own
success/failure shapes without reimplementing parsing or date arithmetic.

`core.time` also exports unit *constants* (`minute`, `hour`, ...), and a member
read has to yield the value rather than a function, so those are special-cased.

`call_n` dispatched at most four arguments, which silently turned every larger
host call into `failure("too many arguments")`; it now covers eight.

## D22 — `Secret.with` is not supported, deliberately (**accepted**)

The construct is syntactically valid and the reference compiles it, but *no
Calcium program can reach it*: `OpSecretWithBegin` pops a value that must be a
`SecretCapability`, and nothing in the language produces one (the primitives that
create capabilities are not exposed; no file in the repository mentions
`Secret.with`). Running one in the reference gives
`runtime error: Secret.with: expected a SecretCapability, got int`.

Implementing parser, compiler and VM support would therefore be unverifiable — no
program exists to compare. The compiler reports `unsupported expression` for it
instead, which is the safe failure this project settled on after D14's silent
`do`-block bug: a construct either compiles correctly or says it cannot.

## D20 — Runtime errors are reported, not dropped (**done**)

The interpreter's dispatch ignored the ok flag on every step, so a `fail` - a
no-match, or a type error raised by the host - emptied the frames and the run just
stopped: no message, exit status 0. `test/mod.test.ca` "passed" that way while
silently truncating.

The state now carries `error`, set by `fail`; `run_with_modules` returns
`{ok, v, error}` and the CLI prints `runtime error: ...` and exits 1, like a
compile error. `examples/factorial.ca` is excluded from the VM and .bone stages as
a consequence: its `match n` arms are `0` and `true`, so nothing matches from n=1,
and the reference stops after the first line *silently*.

## D21 — The FFI primitives a module names are filled in by the loader (**done**)

The reference registers `__str_contains` and friends as builtins before compiling
a module. This compiler has no such table, so those names compiled to nothing and
the call went to whatever was on the stack. The loader now collects the
`__`-prefixed identifiers from the module's tokens, reserves a global for each, and
fills the slots with host functions the VM forwards.

`test/mod.test.ca` (the framework's own suite: `like`, `unlike`, `cmp_ok`,
`is_type`) matches the reference as a result.

## D19 — Interpretation is slow, and that is a measured limit, not a TODO (**accepted**)

**Current measurements** (re-measured after the fusion work; see below for the
method):

| Quantity | Value |
|---|---|
| tail-recursive `count`, 1000 / 2000 / 4000 deep | 0.60 s / 1.16 s / 2.37 s |
| per iteration (slope 1000→4000) | **0.605 ms** (was 0.74 ms) |
| instructions per iteration | 21 (measured: 21028 steps for n=1000, 28 for n=0) |
| per instruction | **~25-28 µs** (was ~54 µs) |
| `tests/tco.test.ca` (50000 deep) | 94 s |
| whole harness, local | 3 m 44 s |
| whole harness, CI runner | **114 s** |

The budget for the harness is **five minutes in CI**; it currently takes under two.

**Method** (so the numbers can be reproduced): the step count comes from
`tools/trace.ca <file> 100000 | grep -c '^step'`, which prints one line per
instruction; the per-instruction figure is the marginal wall-clock time between two
depths divided by the marginal step count, which removes module loading (~0.1 s,
28 steps) from the measurement. Wall-clock only: nothing here is a profiler.

The cost is intrinsic to writing an interpreter that runs on another interpreter:
one step of this VM is itself ~20-40 instructions of the reference VM's dispatch.

**What helped** (each measured):

- `step_op` handles the opcodes a loop spends its time in (`constant`,
  `get_local`, `set_local`, `get_global`, `dup`, `pop`, arithmetic, comparisons,
  jumps, `call`, `tail_call`) with the frame and code already in hand, so a stack
  change and an ip change land in one state update instead of two or three.
- every remaining handler receives `f` and `code` as parameters instead of
  re-deriving `frame_cl(current(st))`/`cl_body(...)`/`frame_base(...)`, and
  `advance_in` skips the state walk for the instruction width.

**What did not help** (each measured as a no-op): a fast path in `put_at`, resolving
the module id once in `entry_globals`, inlining the opcode-width table instead of
calling into `bytecode`, and reordering the dispatch match.

**What is left**: the state is a 7-field record that is rebuilt 2-3 times per
instruction (`push_value`, `pop_value`, `set_ip`). Fusing those is the next lever and
would need the hot handlers to write the whole state once, which is a larger change
than the ones above.

`tests/tco.test.ca` is kept *in* the harness rather than excluded: it passes in 94 s,
and excluding it would hide a real capability behind a timeout.

## D20 — Runtime errors are reported, not dropped (**done**)

The interpreter's dispatch ignored the ok flag on every step, so a `fail` - a
no-match, or a type error raised by the host - emptied the frames and the run just
stopped: no message, exit status 0. `test/mod.test.ca` "passed" that way while
silently truncating.

The state now carries `error`, set by `fail`; `run_with_modules` returns
`{ok, v, error}` and the CLI prints `runtime error: ...` and exits 1, like a
compile error. `examples/factorial.ca` is excluded from the VM and .bone stages as
a consequence: its `match n` arms are `0` and `true`, so nothing matches from n=1,
and the reference stops after the first line *silently*.

## D21 — The FFI primitives a module names are filled in by the loader (**done**)

The reference registers `__str_contains` and friends as builtins before compiling
a module. This compiler has no such table, so those names compiled to nothing and
the call went to whatever was on the stack. The loader now collects the
`__`-prefixed identifiers from the module's tokens, reserves a global for each, and
fills the slots with host functions the VM forwards.

`test/mod.test.ca` (the framework's own suite: `like`, `unlike`, `cmp_ok`,
`is_type`) matches the reference as a result.

## D19 — Interpretation is slow, and that is a measured limit, not a TODO (**accepted**)

One interpreted iteration of a tail-recursive count costs ~0.74 ms (1000 → 0.86 s,
2000 → 1.53 s, 4000 → 2.98 s, 20000 → 14.8 s: linear, and correct at 20000). One
*instruction* is ~54 µs, dominated by the reference VM executing the interpreter's
Calcium - roughly 15-25 host calls per instruction for frame/code/ip plumbing and
state rebuilds.

Tried and measured as no-ops: a fast path in `put_at`, resolving the module id
once in `entry_globals`, inlining the opcode-width table instead of calling into
`bytecode`, and reordering the dispatch match.

What did help: `step_op` handles the opcodes a loop spends its time in
(`constant`, `get_local`, `set_local`, `get_global`, `dup`, `pop`, arithmetic,
comparisons, jumps) with the frame, code and ip already in hand, so a stack change
and an ip change land in one state update instead of two or three. 4000-deep
count: 3.00 s -> 2.37 s (~20%).

The remaining lever is threading the frame and code through *every* opcode
handler so they stop re-deriving `frame_cl`/`cl_body`; the same measurement puts
the remaining cost there.

`tests/tco.test.ca` (50000 deep) is therefore kept *in* the harness rather than
excluded: it passes, it just takes ~40 s, and excluding it would hide a real
capability behind a timeout.

## D25 — SH-4 is scoped to correctness, not speed, going forward (**accepted**)

D19 already settled that the double-interpretation cost is intrinsic, not a
TODO. This makes the implication explicit for future work: further VM effort
is scoped to closing gaps in `docs/EXCLUSIONS.md` (so the differential harness
covers more of the corpus), not to chasing the per-instruction cost.

The fusion work that produced D19's current numbers was worth doing because it
removed accidental overhead that happened to be lying around. It is not the
start of a performance track — SH-4 is a stretch goal by its own definition
(`calcium-lang/specs/selfhost-scope.md` §4), and no amount of further tuning
gets past the double-interpretation ceiling, only amortizes it.

Same reasoning applies to scope decisions still open elsewhere: the LSP (D3)
and giving `.bone` module information (tracked as a self-hosted-repo issue,
not a `calcium-lang` decision) both stay deferred rather than built, until a
concrete need - not "it would be nearly free" - asks for them.

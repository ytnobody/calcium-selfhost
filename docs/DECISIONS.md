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
anything else is a parse error. A literal payload in the final arm is rejected
at compile time, because the final arm is the catch-all and the comparison could
never reject it.

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

# Async: what it would take, and why it is out of scope (D2)

Six examples are excluded from the VM and `.bone` stages. This document records
what they actually require, what the reference does, and the decision.

## What the examples need

| Example | Language features used |
|---|---|
| `async_all.ca` | `async.spawn`, `async.all` |
| `async_cancel.ca` | `async.cancel`, `async.expects`, `schedule.interval` |
| `async_handler.ca` | `async.expects`, `schedule.timeout` |
| `async_interval.ca` | `async.expects`, `async.leave`, `async.stay`, `schedule.interval` |
| `async_spawn.ca` | `async.spawn`, `async.expects`, `async.stay`/`async.leave`, `schedule.timeout` |
| `async_timeout.ca` | `async.expects`, `async.stay`/`async.leave`, `schedule.timeout` |

Two distinct things are involved:

1. **Task and scheduler opcodes**, which are part of the bytecode format:
   `OpSpawn` (no operands), `OpStayBegin` (2, number of state pairs),
   `OpStayGetState` (2, key constant), `OpContinue` (2, pair count),
   `OpStayEnd` (no operands). The format is frozen and append-only, so these are
   fixed contract, not something this implementation can design away.
2. **A timer source**: `schedule.timeout` and `schedule.interval` come from
   `core.schedule`, which is registered **natively** by the reference VM. There is
   no Calcium-level equivalent, and a Calcium program cannot create one: it would
   need either a blocking host call or an FFI primitive.

## What the reference does

`pkg/vm/vm.go` contains 32 `go func` / `chan` sites: task handles, a per-task
status machine, channels for cancellation, and an event loop that `OpStayEnd`
enters (the "stay" model: a handler stays alive and consumes events, updating its
state through `OpContinue`).

## What this implementation does today

The compiler already emits the opcodes: `main.ca compile examples/async_timeout.ca`
succeeds. The VM stops at the first one:

```
$ main.ca run examples/async_timeout.ca
Starting timeout example...
runtime error: unsupported opcode 51
```

That is the intended failure mode — loud, at the exact instruction, rather than a
program that silently computes nothing (D14, D20).

## Options

**A. Keep the scheduler native (opaque handles).**
Add the missing opcodes to the VM and drive them from host-supplied event sources
(the same shape as `core.io`'s `HostFn` bridge). The scheduler stays Go; Calcium
sees handles.
*Effort*: the five opcodes, a task table, a ready-queue loop in `OpStayEnd`, and two
or three new FFI primitives (`__schedule_timeout`, `__schedule_interval`, …).
*Risk*: medium — the interpreter is re-entrant (it already runs callbacks for
`map`/`filter`); nesting an event loop inside `step` is the part that can go wrong.
*Cost to the contract*: new FFI primitives, which is an upstream change to
`specs/ffi-primitives.md`.

**B. Implement the scheduler in Calcium on top of the host scheduler.**
The more interesting result, and the one that would make the VM self-sufficient.
*Effort*: a scheduler written in Calcium, which still needs a way to *wait* — a
blocking primitive — so it collapses into A plus extra layers.
*Risk*: high; failure mode is a deadlock inside an interpreter that cannot yield.

**C. Keep async out of scope, documented.**

## Decision: **C, for now**

The project's goal is to self-host the *toolchain*: lexer, parser, formatter, type
checker, compiler, and a VM that runs the compiled programs. Async is a language
runtime feature whose reference implementation is a goroutine-based scheduler, and
the toolchain already self-hosts without it — 229 comparisons pass with the six
examples excluded and clearly documented.

Option A is the realistic path *if* the feature is needed, and the analysis above is
the design sketch: implement the five opcodes, keep the timer source native, and add
the two or three primitives. Nothing in the current architecture prevents it; the
re-entrant interpreter already knows how to run a callback to completion.

### When to revisit

- If the self-hosted VM is ever used as the *only* VM for a program that needs
  async, or
- if `specs/ffi-primitives.md` gains timer primitives for another reason, which
  would make option A cheap.

### What "done" would look like (option A)

1. `OpSpawn`, `OpStayBegin`, `OpStayGetState`, `OpContinue`, `OpStayEnd` implemented
   in `vm/mod.ca`.
2. `schedule.timeout` / `schedule.interval` forwarded to the host, like `core.time`.
3. The six examples removed from `docs/EXCLUSIONS.md` and compared in the `vm` and
   `.bone` stages.
4. `async_spawn.ca` stays excluded from the `compile` stage regardless: its output is
   non-deterministic in the reference itself.

Decision record: `docs/DECISIONS.md` D2 and D24.

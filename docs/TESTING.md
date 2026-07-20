# Testing strategy

How taka is tested. The goal is a suite that is **fast, deterministic, and
runnable anywhere** — no network, no display, no GPU — so it gates every change
in local and web sessions alike.

## Principles

- **Offline and headless.** `zig build test` must never fetch a dependency or
  open a window. The raylib window backend is excluded from the test graph
  (see *Backend seam* below).
- **Assertions are part of the test.** Builds run in Debug/ReleaseSafe, where
  `std.debug.assert` is live. Following TIGER_STYLE, functions assert their
  own pre/postconditions and invariants, so simply exercising code checks it.
- **Fuzz the parsers.** Anything that consumes untrusted bytes (`.taka` source,
  `@run` output) has a fuzz target that must never crash or leak.
- **Test the serializable, review the visual.** Output whose bytes are
  meaningful (HTML, terminal text, PDF) is asserted directly. Pixel-accurate
  window rendering is checked by hand via `zig build run`.

## Layers

### 1. Unit tests — colocated

Every raylib-free module carries `test` blocks next to the code
(`parser.zig`, `cli.zig`, `html.zig`, `presentation.zig`, …) plus a
`refAllDecls` catch-all so no declaration goes unanalyzed. These cover pure
logic: paragraph/comment splitting, argument parsing, HTML escaping, slide
navigation bounds.

### 2. Integration tests — over the real examples

`integration_test.zig` (rooted at the project directory so it can `@embedFile`)
runs the full parse → render path against the decks in `examples/`, asserting
slide counts and output shape. Adding an example deck should come with an
integration assertion. See `examples/README.md`.

### 3. Golden output — file forms

The file forms (HTML, PDF) are deterministic, so their output is asserted by
structure now (`<!doctype html>`, one `<section>` per slide) and should grow
into byte-for-byte golden comparisons as rendering stabilizes. A golden file
lives beside the example that produced it; regenerate deliberately, review the
diff.

### 4. Fuzz tests

`parser.zig` has a `std.testing.fuzz` target that feeds arbitrary bytes through
`parse` and asserts it neither crashes nor leaks (the testing allocator checks
leaks). It runs once in the normal suite and continuously under
`zig build test --fuzz`. New byte-consuming code (markup, `@run`) gets its own
target.

## The backend seam

Interactive logic must be testable without a window. Navigation lives in
`presentation.zig` as a pure state machine (SPEC 2.1) with full unit tests;
`window.zig` only translates raylib input events into it and draws. raylib is
reached through the `"raylib"` import, which the build swaps for a no-op stub
on the default build — so nothing in the test graph ever links raylib. The real
window path is compile-checked by building the app (`zig build -Dwindow=true`)
and verified by hand.

## What is *not* automatically tested

- **Pixel output of the window form** — no headless GPU in CI. Covered by
  manual `zig build run` smoke checks and the shared, tested navigation state.
- **`@run` process execution** — will need hermetic tests with fixture programs
  (or a faked spawner) once implemented; until then it is a typed stub.

## Commands

| Command | Purpose |
| --- | --- |
| `zig build test` | Unit + integration tests; fuzz targets run once. Offline. |
| `zig build test --fuzz` | Continuous fuzzing (needs a socket for the coverage UI). |
| `zig build check` | `zig fmt` formatting gate. |
| `zig build -Dwindow=true` | Compile-check the raylib window path (needs the dependency). |
| `zig build run -- <deck> --to <form>` | Manual smoke check of a form. |

## Coverage expectations

- Every raylib-free module has tests and is reachable from `test.zig`.
- Every output form has at least one assertion on its serializable output.
- Every byte-consuming parser has a fuzz target.
- New behavior lands with the test that would have caught its absence.

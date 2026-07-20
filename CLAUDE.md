# CLAUDE.md

Rules for working in this repository.

- The **artifact** — the `.taka` format, the CLI, and the output forms — is
  defined in `SPEC.md`. Read it first; keep it free of implementation detail.
- **Technical/tooling decisions** live in the scaffold: `build.zig`,
  `build.zig.zon`, and `src/`.
- This file records the **coding rules**.

## Toolchain

- Zig 0.16 (see `minimum_zig_version` in `build.zig.zon`).
- Use a **native** Zig toolchain. Do **not** use the pip/python `ziglang`
  package.
- `zig build`, `zig build run -- <file.taka>`, `zig build test`, `zig fmt`.

## Lean on native Zig — do not roll our own

- Prefer the standard library and language features over bespoke
  reimplementations or third-party dependencies.
- Reach outside `std` only for capabilities it genuinely lacks — e.g. raylib
  for GUI windowing (SPEC 3.1). Anything `std` already provides (I/O,
  containers, hashing, formatting, allocators, argument iteration, process
  spawning) must go through `std`.

## Modern Zig idioms (0.16)

- **Entry point:** `pub fn main(init: std.process.Init) !void`. Take the
  general allocator from `init.gpa`, process-lifetime storage from
  `init.arena`, and I/O from `init.io`.
- **I/O:** the non-generic `std.Io` interface — `std.Io.Reader` /
  `std.Io.Writer`, `std.Io.Dir` / `std.Io.File`. Filesystem calls take the
  `io` value (e.g. `file.close(io)`). Do not use the removed
  `std.io.GenericReader` / `AnyReader` / `FixedBufferStream`.
- **Containers:** unmanaged by default. `std.ArrayList` is unmanaged — pass
  the allocator to each method; the managed variant is
  `std.array_list.Managed`.
- **Formatting:** define a type's `format(self, w: *std.Io.Writer)` method and
  invoke it with the `{f}` specifier; `{t}` prints an enum tag name.
- **C interop:** through the build system with `b.addTranslateC(...)`, not
  `@cImport` (removed). See how `build.zig` wires raylib.
- **Dependencies:** declared in `build.zig.zon`, added with
  `zig fetch --save`, referenced via `b.dependency(...)`.

## Coding style — TigerBeetle (TIGER_STYLE)

Follow TigerBeetle's style guide:
<https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md>

- **Safety / assertions:** average **at least two assertions per function**.
  Assert arguments, return values, pre/postconditions, and invariants — the
  expected *and* the unexpected. Split compound assertions
  (`assert(a); assert(b);`, not `assert(a and b)`). Use `comptime` asserts
  for type sizes and constant relationships.
- **Control flow:** no recursion; every loop has a fixed upper bound; an
  intentionally unbounded loop (e.g. an event loop) must assert that it is.
  Keep control flow simple and explicit. Push `if`s up and `for`s down.
- **Function length:** at most **70 lines** — a function should fit on screen.
- **Line length:** hard limit **100 columns**, no exceptions. Add a trailing
  comma and let `zig fmt` wrap.
- **Memory:** establish allocation up front; avoid dynamic allocate/free
  churn after initialization. Pass arguments larger than 16 bytes as
  `*const`. Initialize large structs in place via out-pointers.
- **Naming:** `snake_case` for functions, variables, and files. No
  abbreviations. Units last, in descending significance (`latency_ms_max`).
  Align related names to equal length (`source` / `target`, not `src` /
  `dst`). Acronyms keep case (`VSRState`).
- **Formatting:** `zig fmt` is mandatory; 4-space indentation; braces on any
  `if` that does not fit on one line.
- Prefer writing tooling/scripts in Zig over shell, for portability.

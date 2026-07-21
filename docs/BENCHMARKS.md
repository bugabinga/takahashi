# Benchmarks

Performance work on taka's hot pure-CPU paths — slide parsing and inline-markup
scanning. Every optimization is guarded by the correctness suite
(`correctness_test.zig`, 62 tests incl. a differential check over ~7000 inputs),
so speedups never change behavior.

## Method

- `zig build bench` (see `bench.zig`) — always **ReleaseFast**.
- Input: a ~4 MiB synthetic deck (~108k slides) mixing plain words, markup,
  URLs/hyphens (which must stay literal), CJK, multi-line slides, and `@run`.
- Timing: **minimum** wall time over 200 iterations (min rejects scheduler
  noise), via the `std.Io` monotonic clock; results kept live with
  `std.mem.doNotOptimizeAway`.
- Memory: peak arena bytes for one pass (`ArenaAllocator.queryCapacity`).
- Measured on a 4-core box; absolute numbers vary, ratios hold.

## Result — markup scanner (SPEC 1.2)

Markup was the bottleneck: the old scanner allocated a per-byte `[]bool`
classification array and copied every byte through a growing buffer.

| markup | before | after | change |
| --- | ---: | ---: | ---: |
| per-slide (realistic) | 129 MiB/s | **401 MiB/s** | **3.1× faster** |
| marker-heavy (stress) | 171 MiB/s | **779 MiB/s** | **4.6× faster** |
| memory (markup only) | 18.6 MiB | **7.9 MiB** | **2.35× less** |

`parse` (1.37 GiB/s) and `function.scan` (1.1 GiB/s) were unchanged.

### Techniques

- **SIMD fast path** — most slide bodies contain no marker or backslash. A
  hand-rolled `@Vector` scan (`containsSpecial`) checks the whole body against
  the delimiter set at once; when clean, the body becomes a single **borrowed**
  span with no per-byte work and one tiny allocation. (`std.mem.indexOfAny` is
  *not* vectorized in this std, so the hand-rolled vector scan is the win.)
- **SIMD marker location** — `std.mem.indexOfScalarPos` *is* vectorized, so
  pairing jumps between marker occurrences instead of scanning every byte ×6.
- **Data-oriented** — escaped/active marker positions live in
  `std.DynamicBitSetUnmanaged` (n/8 bytes) instead of `[]bool` (n bytes).
- **Zero-copy** — spans borrow sub-slices of the source; a copy happens only
  for a span that actually contains an escape.

## Multi-threading — measured, and deliberately not shipped

For completeness the bench also runs markup across 8 tasks
(`std.Io.Group`, per-task arenas): on the 4 MiB / 108k-slide input it reaches
~682 MiB/s (≈1.7× the single-thread scanner on 4 cores).

It is **not** wired into `document.process`, on purpose. Real decks are
kilobytes with dozens of slides, where markup takes microseconds — there the
task-spawn and per-thread arena setup dwarf the work and would make the common
case *slower*. Threading only pays past multi-megabyte inputs taka never sees.
The single-threaded SIMD/DOD scanner is faster for every realistic deck and has
no concurrency risk.

## Parser

The parser was profiled first and is already ~1.37 GiB/s — near memory
bandwidth for a scanning parser (it uses the vectorized newline search under
`std.mem.splitScalar`). It is ~10× faster than the old markup scanner, so the
optimization effort was correctly aimed at markup.

## Running

```sh
zig build bench          # ReleaseFast microbenchmarks
zig build test           # correctness net that guards every change (offline)
```

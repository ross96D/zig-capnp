# RPC Benchmarks

Captured: 2026-11-13  
Command:

```sh
taskset -c 6 zig build bench -Doptimize=ReleaseFast
```

Environment:

- Zig 0.17.0
- Linux, x86_64
- `-Doptimize=ReleaseFast`
- `std.heap.smp_allocator`
- Pinned to CPU 6; baseline and new runs alternated to reduce CPU-frequency drift

## Results

Medians of three interleaved runs.

| Benchmark | Baseline ns/op | New ns/op | Change | Baseline Mops/s | New Mops/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| `local-call` | 430.9 | 455.2 | +5.6% | 2.321 | 2.197 |
| `scripted-call` | 980.6 | 919.9 | -6.2% | 1.020 | 1.087 |
| `scripted-cap-pass` | 1325.6 | 1242.3 | -6.3% | 0.754 | 0.805 |
| `scripted-pipeline` | 2295.3 | 2077.8 | -9.5% | 0.436 | 0.481 |

Baseline is `cfe60c4`; new is the ID-slot/table refactor on top of it.

`local-call` is the only benchmark that does not exercise the wire tables. Its
change is within the observed run-to-run spread; the best observed local runs
were 423.7 ns (baseline) and 427.7 ns (new, final sanity run after all changes).

## What changed

- Removed three maps outright:
  - `returns` -> `QuestionRef.return_bytes`
  - `forwarded_calls` -> `QuestionRef.forwarded_original_id`
  - `queued_questions` -> `AnswerState.queued`
- Replaced the question, export, and embargo ID maps with flat slot arrays
  indexed directly by ID (`src/rpc/id_table.zig`).
- Added an embedded free list so completed IDs are recycled. The slot array is
  bounded by peak concurrent entries rather than lifetime call count.
- Question IDs whose Return may still be in flight are tombstoned and are not
  reused until the late Return arrives.
- Export IDs are recycled once both wire and handle references are gone.
  Embargo IDs are tombstoned until their loopback echo arrives.
- `answers` now stores `*AnswerState` rather than `AnswerState` by value, so
  rehashing copies a pointer instead of several `ArrayList`s.
- All per-entry allocations for `QuestionRef`, `ExportEntry`, `ImportEntry`,
  `LocalEntry`, `AnswerState`, and `AnswerCapability` now come from
  `std.heap.MemoryPool`.
- Remaining keyed maps are `answers`, `imports` (both keyed by peer IDs), and
  `locals` (keyed by `LocalKey`).

## Notes

- The existing four benchmarks keep table sizes small, so most of the gain is
  from removing hash-table overhead rather than table growth.
- `src/rpc/tests/lifecycle.zig` now asserts that 200 sequential calls reuse the
  same small question-id range and that an abandoned question stays tombstoned
  until its late Return arrives.
- Raw runs were captured in `/tmp/opencode/bench-final-interleaved.txt` during
  development; they are not checked in.

# RPC Benchmarks

Baseline captured: 2026-11-12  
Command:

```sh
zig build bench -Doptimize=ReleaseFast
```

For stable numbers, pin to a single CPU:

```sh
taskset -c 2 zig build bench -Doptimize=ReleaseFast
```

Environment:

- Zig 0.17.0
- Linux
- `-Doptimize=ReleaseFast`
- `std.heap.smp_allocator`

## Baseline (P2.0)

| Benchmark | Iterations | ns/op | Mops/s |
| --- | ---: | ---: | ---: |
| `local-call` | 50,000 | 14,468 | 0.069 |
| `scripted-call` | 20,000 | 24,044 | 0.042 |
| `scripted-cap-pass` | 10,000 | 32,145 | 0.031 |
| `scripted-pipeline` | 5,000 | 47,361 | 0.021 |

Values are medians of three runs.

## Notes

- `local-call` is an in-process capability call. The request is read directly
  from the builder; the response is serialized into an exact-size owned buffer.
- `scripted-call` is a full round trip with explicit message delivery through
  `transports.Scripted`.
- `scripted-cap-pass` sends one capability in the params table on every call.
- `scripted-pipeline` creates a promise result capability and pipelines a call
  onto it before the first call returns.
- P2.3 reduced the RPC builder initial segment from 64 KiB to 1 KiB and added
  owned-buffer message/response paths. This removed the dominant allocation
  cost and roughly a full message copy per Return and local response.
- An earlier `toReader` benchmark appeared slower, but that was an unpinned
  `std.heap.smp_allocator` slab/page-fault artifact. Pinned, the builder-backed
  local request path is faster and is now used.
- The low-level serialization API removes `toBytes`/`toPackedBytes` and
  `std.Io.Writer.Allocating` from the RPC send path. `MessageBuilder` now
  exposes `serializedSize`, `writeHeader`, `writeToBuffer`, and
  `segmentSlices`; transports send `MessageParts` directly.

## Comparison log

| Date | Change | local-call ns/op | scripted-call ns/op | cap-pass ns/op | pipeline ns/op |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-11-12 | P2.0 baseline | 14,468 | 24,044 | 32,145 | 47,361 |
| 2026-11-12 | P2.1 structure (no behavior change) | 14,299 | 24,070 | 32,022 | 47,340 |
| 2026-11-12 | P2.2 scheduler decoupling | 14,164 | 24,504 | 31,901 | 48,167 |
| 2026-11-12 | P2.3 buffers/allocations | 558 | 1,140 | 1,573 | 2,744 |
| 2026-11-12 | P2.3 low-level serialization/parts, unpinned | 467 | 1,019 | 1,397 | 2,338 |
| 2026-11-12 | P2.3 low-level serialization/parts, pinned CPU 2 | 452 | 976 | 1,334 | 2,255 |

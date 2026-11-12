# RPC Benchmarks

Baseline captured: 2026-11-12  
Command:

```sh
zig build bench -Doptimize=ReleaseFast
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

- `local-call` is an in-process capability call. It still serializes the
  request and response through `capnp.MessageBuilder`/`Message.fromBytes`.
- `scripted-call` is a full round trip with explicit message delivery through
  `transports.Scripted`.
- `scripted-cap-pass` sends one capability in the params table on every call.
- `scripted-pipeline` creates a promise result capability and pipelines a call
  onto it before the first call returns.
- `MessageBuilder.init()` currently reserves a 64 KiB initial segment and
  zeroes it. Each RPC message (request and response) therefore pays a large
  fixed allocation/zeroing cost. This is a primary target for P2.3.

## Comparison log

| Date | Change | local-call ns/op | scripted-call ns/op | cap-pass ns/op | pipeline ns/op |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-11-12 | P2.0 baseline | 14,468 | 24,044 | 32,145 | 47,361 |

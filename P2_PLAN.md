# P2 Plan: Structure, Scheduling, and Performance

Status: P2.3 complete; P2.4 next
Started: 2026-11-12

## Decisions

1. **Order:** recommended sequence:
   - P2.0 test infrastructure and benchmarks
   - P2.1 module structure
   - P2.2 scheduler decoupling
   - P2.3 performance
   - P2.4 teardown/robustness
   - P2.5 generated-binding cleanup (Linux-only for P2)
   - P2.6 documentation
2. **`Connection.peer`:** no compatibility shim. P2.2 will replace recursive
   peer pumping with an explicit loopback/test driver and remove `Connection.peer`.
3. **Out of scope (P3):** `.imported` call forwarding/proxy Return relay,
   Accept/Join/Provide, third-party introductions, proper embargoes,
   SturdyRefs/persistence, full async/multi-connection event loop.
4. **Platform:** Linux-only for P2. Keep the existing POSIX polling path and
   defer portable-core work. P2.5 only covers generated bindings and `Side`
   cleanup.
5. **Performance:** improvements must be backed by benchmark numbers, with
   before/after comparisons recorded in `BENCHMARKS.md`.

## P2 Goals

- Remove recursive peer pumping from `sendRaw`.
- Reduce `connection.zig` and split `rpc_tests.zig`.
- Establish benchmarks and remove the worst copies/allocations.
- Harden teardown, limits, and malformed-input handling.
- Document threading, ordering, reentrancy, and ownership.

## Workstreams

### P2.0 — Test infrastructure and baselines (complete)

- [x] Deterministic scripted transport (`src/rpc/transports/scripted.zig`)
  - per-endpoint outboxes/inboxes
  - manual delivery in arbitrary order
  - injection of malformed messages
  - per-endpoint close/EOF
- [x] Tests:
  - `Finish` cancels a call queued behind an unresolved promise
  - late `Return` is ignored after the question is released
  - late `Resolve` after the import is released is harmless
  - duplicate question ids produce an exception
  - unknown export ids produce an exception
  - scripted/out-of-order pipelining still resolves correctly
- [x] `zig build bench` with:
  - local call round-trip
  - scripted in-memory round-trip
  - capability-passing round-trip
  - promise-pipelined capability call
- [x] Baseline recorded in `BENCHMARKS.md` using
  `zig build bench -Doptimize=ReleaseFast`.

### P2.1 — Module structure (complete)

- [x] Split tests:
  - `src/rpc/rpc_tests.zig` (thin aggregator)
  - `src/rpc/tests/mod.zig`
  - `src/rpc/tests/support.zig` (shared test interfaces/helpers)
  - `src/rpc/tests/level0.zig`
  - `src/rpc/tests/capabilities.zig`
  - `src/rpc/tests/pipelining.zig`
  - `src/rpc/tests/lifecycle.zig`
  - `src/rpc/tests/transports.zig`
- [x] Move generated bindings to `src/rpc/generated/` and update
  `codegen_rpc.bash`.
- [x] Extract stateless message builders into `src/rpc/wire.zig`
  (`buildFinish`, `buildAbort`, `buildException`, `buildRelease`).
- [x] Extract pure internal types into `src/rpc/internal.zig`
  (`PendingCall`, `LocalKey`, `LocalKeyContext`, `ExportKind`,
  `FinishState`, `AnswerCallState`, lifecycle/drain enums).
- [x] Do not force `Request`/`Response`/`Promise`/`Connection` method
  extraction into separate files; they remain in `connection.zig` to avoid
  import cycles.

### P2.2 — Scheduler decoupling (complete)

- [x] `sendRaw` is transport-only; it no longer pumps a peer.
- [x] Removed `Connection.peer`.
- [x] Added `Connection.Waker` and `Connection.setWaker` for blocking waits.
- [x] Added `driver.LoopbackPair`:
  - owns two in-memory connections
  - installs wakers that step the opposite side only during blocking waits
  - provides explicit `step`/`pump` helpers
- [x] Migrated tests, `codegen_tests.zig`, and in-process examples to
  `LoopbackPair`.
- [x] Replaced `deferred_calls.orderedRemove(0)` with a head-index queue.
- [x] Documented reentrancy and scheduling in the `connection.zig` module doc.
- [x] Added a deep local-call nesting test (depth 128).
- [x] Benchmark comparison recorded in `BENCHMARKS.md`; no planned
  performance change in this milestone.

### P2.3 — Performance (complete)

- [x] Reduced RPC `MessageBuilder` initial segment from 64 KiB to 1 KiB.
  This was the dominant cost for small RPC messages.
- [x] Added `capnp.Message.fromOwnedBytes`, which parses a contiguous message
  without copying each segment.
- [x] Added `Response.fromOwnedBytes`.
- [x] `takeReturn` transfers ownership of stored Return bytes into the
  Response instead of copying.
- [x] Local response bytes are transferred into the `Response`.
- [x] Removed `MessageBuilder.toBytes` / `toPackedBytes` and the hidden
  `std.Io.Writer.Allocating` path from the RPC hot path.
- [x] Added low-level serialization primitives:
  - `serializedSize`
  - `writeHeader`
  - `writeToBuffer`
  - `segmentSlices`
  - `writePackedTo(writer, scratch)`
- [x] Replaced `Transport.send(bytes)` with `Transport.send(MessageParts)`.
  - Unix appends header + segments directly to its write queue.
  - Loopback/Scripted flatten parts into their queues.
- [x] `Request.start` no longer flattens wire messages into a temporary buffer.
- [x] Local requests use the builder-backed `toReader()` path.
- [x] `AnswerCapability` release is O(1) via a stored list index.
- [x] Corrected the earlier `toReader` conclusion: the 2x result was an
  unpinned `std.heap.smp_allocator` slab/page-fault artifact. Pinned, the
  builder-backed path is faster.
- [ ] Inbound Return buffers are still duplicated in `handleReturn`; defer
  transferring ownership from `step` until a benchmark shows it matters.
- [ ] Pools/per-message arenas were not needed for P2.3 after the above; defer
  until a benchmark shows allocation churn is still dominant.
- [x] Benchmark comparison recorded in `BENCHMARKS.md`:

  | Benchmark | P2.2 | P2.3 initial | P2.3 low-level, pinned |
  | --- | ---: | ---: | ---: |
  | `local-call` | 14,164 ns | 558 ns | 452 ns |
  | `scripted-call` | 24,504 ns | 1,140 ns | 976 ns |
  | `scripted-cap-pass` | 31,901 ns | 1,573 ns | 1,334 ns |
  | `scripted-pipeline` | 48,167 ns | 2,744 ns | 2,255 ns |

### P2.4 — Teardown and robustness

- Fix hash-map mutation while iterating in `Connection.deinit`:
  - snapshot keys or use a worklist instead of removing while a map iterator
    is live.
- Reject self-referential/cyclic `Resolve` descriptors.
- Add limits:
  - max cap-table entries per message
  - max pending calls per promise/answer
  - max live questions/answers/imports/exports
  - optional runtime message-size limit
- Classify fatal errors consistently:
  - malformed/protocol errors -> `Abort` + close
  - OOM/transport failure -> close
  - handler failure -> `Return.exception`
- Add teardown tests with outstanding questions and capabilities.

### P2.5 — Generated bindings and `Side` cleanup (Linux-only)

- Move `rpc.zig` and `rpc_twoparty.zig` under `generated/`.
- Decide whether `rpc_twoparty.zig` stays:
  - keep it as generated-but-unused, clearly marked, or
  - delete it until level 3/4 features exist.
- Reconcile `transport.Side` (`client=0, server=1`) with
  `rpc_twoparty.Side` (`server=0, client=1`):
  - remove `Side` from the transport abstraction, or
  - make transport endpoints an opaque local loopback concern.
- Do not move POSIX `fd`/`poll` out of the core in P2.

### P2.6 — Documentation

Add `src/rpc/README.md` or expand module docs covering:

- single-threaded / not `Send`
- E-order and message ordering guarantees
- reentrancy rules
- capability/refcount ownership
- question/answer/import/export lifecycle
- supported protocol feature matrix
- transport responsibilities and limits
- blocking vs non-blocking (`step`/`tryTake`) usage

## Milestones

| Milestone | Contents | Risk |
| --- | --- | --- |
| M1 | Scripted transport, ordering/cancellation tests, benchmarks | Low |
| M2 | Test-file split, generated-file move, `wire.zig` | Low/medium |
| M3 | Remove `sendRaw` peer recursion and `Connection.peer` | High |
| M4 | Owned-buffer paths, local-call fast path, arenas/pools | Medium |
| M5 | Teardown/limits/Resolve hardening | Medium |
| M6 | Generated-binding/`Side` cleanup, docs | Low |

Each milestone must keep the full suite green.

## Baseline

Filled in by P2.0; see `BENCHMARKS.md`.

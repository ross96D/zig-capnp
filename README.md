# zig-capnp
Yet another capnproto code generator attempt for zig

## Progress

We are currently in early stages of development. This is not a useful project yet!

The current status is that code generation is working for schema.capnp to the point we can replace our hand-written schema file

- [x] Minimal reading
- [x] Reading of capnproto
- [ ] Code generation (Reader)
- [ ] Code generation (Builder)
- [ ] Packed messages
- [ ] RPC

## RPC capability ownership

`src/rpc/connection.zig` exposes owned, reference-counted `Capability` handles:

- `Connection.initLocal` turns a generated `LocalCapability` descriptor into a
  handle; descriptors with the same context/interface/dispatch share one
  server entry.
- Handles returned by `bootstrap`, `Response.capability`, and
  `Promise.capability` must be released exactly once with `release()`.
- `Connection.setBootstrap` consumes a handle; `Request.addCapability` and
  `Call.addResultCapability` borrow their argument. Convenience helpers
  `Request.addLocalCapability` and `Call.addLocalResultCapability` handle the
  common local-capability case.
- `LocalCapability.destroy` is an optional callback invoked once when the last
  handle and wire export are gone (or when the connection is destroyed).
- Generated `Client.fromCapability` consumes a handle and `Client.deinit`
  releases it.

See the module doc comment in `src/rpc/connection.zig` for the full rules.

## Existing efforts

### Zarzwick/capnproto-zig

Gitlab: https://gitlab.com/Zarzwick/capnproto-zig/-/tree/main

This appears the most advanced of existing efforts. The compiler is implemented in C++, not zig.

I do not seem to be able to find the alternative efforts!


# Examples

Build all examples:

```sh
zig build examples
```

Run each example:

```sh
zig build run-example-build-message
zig build run-example-packed-message
zig build run-example-point-list
zig build run-example-rpc-echo
zig build run-example-rpc-pipeline
```

## Structure

```text
examples/
├── build-message/
├── packed-message/
├── point-list/
├── rpc-echo/
├── rpc-pipeline/
└── common/
```

- `build-message/` — build a `Point` message, serialize it, parse it back, and read fields.
- `packed-message/` — frame a message with the Cap'n Proto packing codec and unpack it again.
- `point-list/` — build and read a composite list of `Point` structs.
- `rpc-echo/` — a self-contained RPC example with a Cap'n Proto interface, generated bindings, typed client/server, and loopback transport.
- `rpc-pipeline/` — several interfaces and methods, including calls pipelined on capabilities returned by earlier calls.
- `common/` — the shared `Point` schema and generated bindings used by the non-RPC examples.

## RPC interfaces

`rpc-echo/echo.capnp`:

```capnp
@0x9f4c2a7e1d8b6350;

interface Echo {
  echo @0 (text :Text) -> (text :Text);
}
```

`rpc-pipeline/services.capnp` defines `Factory`, `Greeter`, and `Calculator`, with several methods each. `rpc-pipeline/main.zig` starts calls, obtains promised capabilities from `Request.start()` + `Promise.capability(0)`, and calls those capabilities before waiting for the originating result.

## Generated schema code

`common/generated/point.zig` is generated from `common/point.capnp`:

```sh
zig build
./examples/common/codegen.bash
```

`rpc-echo/generated/echo.zig` is generated from `rpc-echo/echo.capnp`:

```sh
zig build
./examples/rpc-echo/codegen.bash
```

`rpc-pipeline/generated/services.zig` is generated from `rpc-pipeline/services.capnp`:

```sh
zig build
./examples/rpc-pipeline/codegen.bash
```

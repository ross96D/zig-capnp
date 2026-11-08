#!/bin/bash
set -euo pipefail

mkdir -p capnp-tests/codegen-request
for f in capnp-tests/*.capnp; do
  name=$(basename "$f" .capnp)
  capnp compile -I/usr/local/include/capnp -o- "$f" > "capnp-tests/codegen-request/${name}.request.bin"
done

mkdir -p capnp-tests/codegen-zig
for f in capnp-tests/codegen-request/*.request.bin; do
  name=$(basename "$f" .request.bin)
  echo "generate capnp-tests/codegen-zig/generated_${name}.zig"
  ./zig-out/bin/capnpc-zig --stdout < "$f" > "capnp-tests/codegen-zig/generated_${name}.zig"
done

cp src/schema.zig capnp-tests/codegen-zig/schema.zig
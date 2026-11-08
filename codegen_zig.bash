#!/bin/bash
set -euo pipefail

capnpc=${1:-./zig-out/bin/capnpc-zig}

mkdir -p capnp-tests/codegen-request
for f in capnp-tests/*.capnp; do
  name=$(basename "$f" .capnp)
  request="capnp-tests/codegen-request/${name}.request.bin"
  if [ ! -f "$request" ]; then
    capnp compile -I/usr/local/include/capnp -o- "$f" > "$request"
  fi
done

mkdir -p capnp-tests/codegen-zig
for f in capnp-tests/codegen-request/*.request.bin; do
  name=$(basename "$f" .request.bin)
  generated="capnp-tests/codegen-zig/generated_${name}.zig"
  if [ ! -f "$generated" ]; then
    echo "generate $generated"
    "$capnpc" --stdout < "$f" > "$generated"
  fi
done

if [ ! -f capnp-tests/codegen-zig/schema.zig ]; then
  cp src/schema.zig capnp-tests/codegen-zig/schema.zig
fi

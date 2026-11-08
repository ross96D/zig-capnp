#!/bin/bash
set -euo pipefail

mkdir -p capnp-tests/codegen-zig
for f in capnp-tests/codegen/*.request.bin; do
  name=$(basename "$f" .request.bin)
  ./zig-out/bin/zig-capnp < "$f" > "capnp-tests/codegen-zig/generated_${name}.zig"
done

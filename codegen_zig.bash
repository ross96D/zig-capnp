#!/bin/bash
set -euo pipefail

capnpc=${1:-./zig-out/bin/capnpc-zig}

eval_fixtures=(
  01_simple_struct_date_20230714.bin
  01_simple_struct_datem_20230714.bin
  02_simple_lists.bin
  03_composite_lists.bin
  04_unions.bin
  05_default_values.bin
  07_bits_and_floats.bin
  09_codegen_features.bin
  10_groups_point.bin
  10_groups_union.bin
  06_schema.capnp.original.bin
  06_schema.capnp.original.1.bin
  08-schema-examples.void.bin
  08-schema-examples.field1.bin
  08-schema-examples.node.bin
)

need_eval_fixtures=0
for fixture in "${eval_fixtures[@]}"; do
  if [ ! -f "capnp-tests/$fixture" ]; then
    need_eval_fixtures=1
    break
  fi
done

if [ "$need_eval_fixtures" -eq 1 ]; then
  (cd capnp-tests && bash build.sh)
fi

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

#!/bin/bash
set -euo pipefail

capnpc=${1:-./zig-out/bin/capnpc-zig}
include_dir=${CAPNP_INCLUDE_DIR:-/usr/local/include/capnp}

if ! command -v capnp >/dev/null 2>&1; then
  echo "capnp compiler not found in PATH" >&2
  exit 1
fi

if [ ! -x "$capnpc" ]; then
  echo "capnpc-zig not found at $capnpc; run 'zig build' first" >&2
  exit 1
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

capnp compile -I"$include_dir" -o- "$include_dir/rpc.capnp" > "$tmp_dir/rpc.request.bin"
"$capnpc" --stdout < "$tmp_dir/rpc.request.bin" > src/rpc/generated/rpc.zig

capnp compile -I"$include_dir" -o- "$include_dir/rpc-twoparty.capnp" > "$tmp_dir/rpc-twoparty.request.bin"
"$capnpc" --stdout < "$tmp_dir/rpc-twoparty.request.bin" > src/rpc/generated/rpc_twoparty.zig

zig fmt src/rpc/generated/rpc.zig src/rpc/generated/rpc_twoparty.zig

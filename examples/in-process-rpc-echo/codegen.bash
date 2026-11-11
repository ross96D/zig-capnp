#!/bin/bash
set -euo pipefail

capnpc=${1:-./zig-out/bin/capnpc-zig}

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

capnp compile -o- examples/rpc-echo/echo.capnp > "$tmp_dir/echo.request.bin"
"$capnpc" --stdout < "$tmp_dir/echo.request.bin" > examples/rpc-echo/generated/echo.zig
zig fmt examples/rpc-echo/generated/echo.zig

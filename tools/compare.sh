#!/bin/sh

mode=$1
shift

echo "comparing allocators in $mode mode"

path="zig-out/bench/$mode"
hyperfine $@ $(find "$path" -executable -type f)

#!/bin/sh

mode=$1
shift

echo "comparing allocators in $mode mode"

path="zig-out/bench/$mode"
basenames=$(find "$path/mesh" -executable -type f -printf '%f\n')
for basename in $basenames
do
    hyperfine $@ "$path/gpa/$basename" "$path/mesh/$basename"
done

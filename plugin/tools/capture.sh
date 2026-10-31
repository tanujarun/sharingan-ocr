#!/bin/bash
# Grabs each named monitor at native resolution: capture.sh <dir> <stamp> <output>...
# grim blocks forever while the monitors are asleep, hence the timeout.
dir=$1 stamp=$2; shift 2
mkdir -p "$dir" && chmod 700 "$dir"
rm -f "${dir:?}"/*.ppm
pids=()
for out in "$@"; do
  timeout 3 grim -t ppm -o "$out" "$dir/$out-$stamp.ppm" & pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid" || exit 1; done

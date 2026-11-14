#!/bin/bash
# Whole-machine CPU % (all qubes, via Xen) + hottest Dell sensor
pcpus=$(sudo xl info | awk '/^nr_cpus/ {print $3}')
used=$(sudo xentop -b -d 1 -i 2 | awk '/^ *NAME/{n++; next} n==2 {s+=$4} END {print s+0}')
temp=$(sensors -j 2>/dev/null | jq '[."dell_smm-virtual-0" | to_entries[] | select(.key|test("^temp"))
        | .value | to_entries[] | select(.key|endswith("_input")) | .value | select(. > 0)] | max | floor')
awk -v u="$used" -v c="$pcpus" -v t="$temp" 'BEGIN { printf(" 🔥 %5.1f%% @ +%s.0°C \n", u/c, t) }'

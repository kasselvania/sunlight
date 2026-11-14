#!/bin/bash
# gclick.sh <window id> <x> <y>: click only if the tile is there and no consent prompt is near.
cd "$(dirname "$0")"
python3 tileat.py $1 $2 $3 >/dev/null || { echo "ABORT: $(python3 tileat.py $1 $2 $3)"; exit 1; }
./safe $2 $3 60 >/dev/null || { echo "ABORT: $(./safe $2 $3 60)"; exit 1; }
./drive2 click $2 $3

#!/usr/bin/env bash
#
# Clones and builds wrk2 (https://github.com/giltene/wrk2) into benchmark/.wrk2/, 
# for use by bench.sh.
#
# On newer binutils 2.4x+, wrk2's vendored LuaJIT bytecode-to-object step links 
# fine on its own, but the final link fails with "string table is corrupt" using 
# the default bfd linker. I don't know if it's issue on my side, but building 
# with the gold linker avoids it.

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$ROOT/.wrk2"

if [ -x "$DEST/wrk2" ]; then
  echo "Already built: $DEST/wrk2"
  exit 0
fi

rm -rf "$DEST/src"
mkdir -p "$DEST"
git clone --depth 1 https://github.com/giltene/wrk2.git "$DEST/src"

(
  cd "$DEST/src"
  make CC="gcc -fuse-ld=gold"
)

cp "$DEST/src/wrk" "$DEST/wrk2"
echo "Built: $DEST/wrk2"
"$DEST/wrk2" --version || true

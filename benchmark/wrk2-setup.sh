#!/usr/bin/env bash

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

#!/bin/bash
# Rebuilds both trailers from this kit only.  usage: ./make-trailer.sh [output folder]
set -euo pipefail
cd "$(dirname "$0")"
KIT="$(cd .. && pwd)"
OUT="${1:-$KIT/06 Trailers}"
BIN="$(mktemp -d)"
for s in trailer music mux shrink; do swiftc -O "$s.swift" -o "$BIN/$s" 2>/dev/null; done
"$BIN/music" 89.1 "$KIT/04 Music/Trailer music (89.1 s).m4a"
"$BIN/music" 89.1 "$KIT/04 Music/Trailer music (89.1 s).wav"
for L in ro en; do
  U=$(echo $L | tr a-z A-Z)
  "$BIN/trailer" "$KIT/01 Recordings" "$KIT/05 Graphics/App icon 1024.png" $L "$BIN/$L.mp4"
  cp "$BIN/$L.mp4.video.mp4" "$KIT/07 Silent masters/Trailer $U - no music.mp4"
  "$BIN/mux" "$BIN/$L.mp4.video.mp4" "$KIT/04 Music/Trailer music (89.1 s).m4a" "$OUT/Toolbox Pro Max - trailer ($U).mp4"
  "$BIN/shrink" "$OUT/Toolbox Pro Max - trailer ($U).mp4" "$OUT/Toolbox Pro Max - trailer ($U, mic).mp4"
done
rm -rf "$BIN"
echo "Done → $OUT"

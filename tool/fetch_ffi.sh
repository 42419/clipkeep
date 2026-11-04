#!/usr/bin/env bash
# Fetch libbdl_ffi.so for Android ABIs from the bdl fork's rolling "ffi" release,
# verify against SHA256SUMS, and place them under android/app/src/main/jniLibs/<abi>/.
# Run from the Flutter project root.
set -euo pipefail
REPO="${REPO:-42419/bdl}"
DEST="${DEST:-android/app/src/main/jniLibs}"
BASE="https://github.com/${REPO}/releases/download/ffi"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$BASE/SHA256SUMS" -o "$tmp/SHA256SUMS"
for abi in arm64-v8a armeabi-v7a x86_64; do
  asset="libbdl_ffi-$abi.so"
  mkdir -p "$DEST/$abi"
  curl -fsSL "$BASE/$asset" -o "$DEST/$abi/libbdl_ffi.so"
  want="$(awk -v n="$asset" '$2 ~ n {print $1; exit}' "$tmp/SHA256SUMS")"
  got="$(sha256sum "$DEST/$abi/libbdl_ffi.so" | awk '{print $1}')"
  if [ -n "$want" ] && [ "$want" != "$got" ]; then
    echo "SHA256 mismatch for $asset" >&2
    exit 1
  fi
  echo "ok  $asset -> $DEST/$abi/libbdl_ffi.so"
done

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ROOT_DIR/RustCore"
OUT_DIR="$ROOT_DIR/Frameworks"
XCFRAMEWORK="$OUT_DIR/XboxPadNano.xcframework"
DEVICE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --device-only)
      DEVICE_ONLY=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

export PATH="$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET="16.0"

echo "==> Building RustCore for iOS arm64 (device)..."
(cd "$RUST_DIR" && cargo build --release --target aarch64-apple-ios)

ARGS=(
  -library "$RUST_DIR/target/aarch64-apple-ios/release/libxboxpad_nano.a"
  -headers "$RUST_DIR/include"
)

if [ "$DEVICE_ONLY" = false ]; then
  echo "==> Building RustCore for iOS Simulator arm64..."
  (cd "$RUST_DIR" && cargo build --release --target aarch64-apple-ios-sim)
  ARGS+=(
    -library "$RUST_DIR/target/aarch64-apple-ios-sim/release/libxboxpad_nano.a"
    -headers "$RUST_DIR/include"
  )
fi

mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"

echo "==> Packaging XboxPadNano.xcframework..."
xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCFRAMEWORK"

echo "==> Done: $XCFRAMEWORK"

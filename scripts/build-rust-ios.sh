#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUST_DIR="$ROOT_DIR/RustCore"
OUT_DIR="$ROOT_DIR/Frameworks"
XCFRAMEWORK="$OUT_DIR/XboxPadNano.xcframework"
MODE="all"

for arg in "$@"; do
  case "$arg" in
    --device-only)
      MODE="ios-device"
      ;;
    --macos-only)
      MODE="macos"
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

export PATH="$HOME/.cargo/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET="16.0"
export MACOSX_DEPLOYMENT_TARGET="14.0"

ARGS=()

if [ "$MODE" = "ios-device" ] || [ "$MODE" = "all" ]; then
  echo "==> Building RustCore for iOS arm64 (device)..."
  (cd "$RUST_DIR" && cargo build --release --target aarch64-apple-ios)
  ARGS+=(
    -library "$RUST_DIR/target/aarch64-apple-ios/release/libxboxpad_nano.a"
    -headers "$RUST_DIR/include"
  )
fi

if [ "$MODE" = "all" ]; then
  echo "==> Building RustCore for iOS Simulator arm64..."
  (cd "$RUST_DIR" && cargo build --release --target aarch64-apple-ios-sim)
  ARGS+=(
    -library "$RUST_DIR/target/aarch64-apple-ios-sim/release/libxboxpad_nano.a"
    -headers "$RUST_DIR/include"
  )
fi

if [ "$MODE" = "macos" ] || [ "$MODE" = "all" ]; then
  echo "==> Building RustCore Universal for macOS (arm64 + x86_64)..."
  (cd "$RUST_DIR" && cargo build --release --target aarch64-apple-darwin)
  (cd "$RUST_DIR" && cargo build --release --target x86_64-apple-darwin)
  mkdir -p "$RUST_DIR/target/universal-macos/release"
  lipo -create \
    "$RUST_DIR/target/aarch64-apple-darwin/release/libxboxpad_nano.a" \
    "$RUST_DIR/target/x86_64-apple-darwin/release/libxboxpad_nano.a" \
    -output "$RUST_DIR/target/universal-macos/release/libxboxpad_nano.a"
  ARGS+=(
    -library "$RUST_DIR/target/universal-macos/release/libxboxpad_nano.a"
    -headers "$RUST_DIR/include"
  )
fi

mkdir -p "$OUT_DIR"
rm -rf "$XCFRAMEWORK"

echo "==> Packaging XboxPadNano.xcframework ($MODE)..."
xcodebuild -create-xcframework "${ARGS[@]}" -output "$XCFRAMEWORK"

echo "==> Done: $XCFRAMEWORK"

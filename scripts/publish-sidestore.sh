#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$ROOT_DIR/.env.deploy.local" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env.deploy.local"
fi

IPA_PATH="${1:-$ROOT_DIR/build/XboxPad-unsigned.ipa}"
CHANGELOG="${2:-原生 Apple 全平台低延迟 Xbox 串流与 xCloud 云游戏：支持 iPad / iPhone / macOS，2K 1440p 高码率、MetalFX 超分、120Hz 双向光流补帧、EDR Auto-HDR、多手柄与键鼠支持。}"
MACOS_DMG_PATH="${3:-${XBOXPAD_MACOS_DMG:-}}"
ICON_PATH="$ROOT_DIR/XboxPad/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

SSH_KEY="${XBOXPAD_DEPLOY_KEY:-}"
REMOTE_HOST="${XBOXPAD_DEPLOY_HOST:-}"
REMOTE_DIR="${XBOXPAD_REMOTE_DIR:-/srv/xboxpad-sidestore}"
BASE_URL="${XBOXPAD_BASE_URL:-}"
SYNC_DIR="${XBOXPAD_SYNC_DIR:-}"

if [ -z "$SSH_KEY" ] || [ -z "$REMOTE_HOST" ] || [ -z "$BASE_URL" ]; then
  cat >&2 <<'EOF'
Missing deployment environment variables.
Configure them in your environment or in a gitignored `.env.deploy.local` file:
  XBOXPAD_DEPLOY_HOST="user@your-server.example"
  XBOXPAD_DEPLOY_KEY="/path/to/your-ssh-key.pem"
  XBOXPAD_BASE_URL="https://your-source-domain.example"
  XBOXPAD_REMOTE_DIR="/srv/xboxpad-sidestore"   # optional
  XBOXPAD_SYNC_DIR="/path/to/local/sync/dir"    # optional
EOF
  exit 1
fi

BASE_URL="${BASE_URL%/}"
test -f "$IPA_PATH" || { echo "Missing IPA: $IPA_PATH" >&2; exit 1; }
test -f "$ICON_PATH" || { echo "Missing icon: $ICON_PATH" >&2; exit 1; }
test -f "$SSH_KEY" || { echo "Missing SSH key: $SSH_KEY" >&2; exit 1; }

PLIST_XML="$(unzip -p "$IPA_PATH" Payload/XboxPad.app/Info.plist | plutil -convert xml1 -o - -)"
VERSION="$(printf '%s' "$PLIST_XML" | python3 -c 'import sys, plistlib; p=plistlib.loads(sys.stdin.buffer.read()); print(p["CFBundleShortVersionString"])')"
BUILD="$(printf '%s' "$PLIST_XML" | python3 -c 'import sys, plistlib; p=plistlib.loads(sys.stdin.buffer.read()); print(p["CFBundleVersion"])')"
BUNDLE_ID="$(printf '%s' "$PLIST_XML" | python3 -c 'import sys, plistlib; p=plistlib.loads(sys.stdin.buffer.read()); print(p["CFBundleIdentifier"])')"
MIN_OS="$(printf '%s' "$PLIST_XML" | python3 -c 'import sys, plistlib; p=plistlib.loads(sys.stdin.buffer.read()); print(p.get("MinimumOSVersion", "17.0"))')"
IPA_SIZE="$(stat -f%z "$IPA_PATH")"
ISO_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
IPA_FILENAME="XboxPad-${VERSION}.ipa"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

python3 - "$TMP_DIR/source.json" "$VERSION" "$BUILD" "$BUNDLE_ID" "$MIN_OS" "$IPA_SIZE" "$ISO_DATE" "$BASE_URL" "$IPA_FILENAME" "$CHANGELOG" <<'PY'
import json, sys

out_path, version, build, bundle_id, min_os, size_s, iso_date, base_url, ipa_file, changelog = sys.argv[1:]
size = int(size_s)
dl_url = f"{base_url}/{ipa_file}"
icon_url = f"{base_url}/icon.png"

source = {
    "name": "XboxPad Source",
    "identifier": "com.elliot.xboxpad.source",
    "subtitle": "原生 iPadOS 超低延迟 Xbox 串流与 xCloud 客户端（OTA 源）",
    "description": "XboxPad 开源 SideStore / AltStore 订阅源，支持一键更新与自动续期。",
    "iconURL": icon_url,
    "tintColor": "#107C10",
    "featuredApps": [bundle_id],
    "apps": [
        {
            "name": "XboxPad",
            "bundleIdentifier": bundle_id,
            "developerName": "Elliot",
            "subtitle": "原生 iPadOS 低延迟 Xbox Remote Play / xCloud",
            "localizedDescription": "基于 Rust WebRTC + MetalFX + 120Hz 双向光流补帧 + 原生 EDR Auto-HDR + AudioToolbox Opus + CoreHaptics 震动的原生 iPadOS Xbox 串流与云游戏客户端，支持多手柄、外接键鼠、语音开麦与自定义 STUN/TURN 穿透。",
            "iconURL": icon_url,
            "tintColor": "#107C10",
            "category": "games",
            "version": version,
            "versionDate": iso_date,
            "versionDescription": changelog,
            "downloadURL": dl_url,
            "size": size,
            "versions": [
                {
                    "version": version,
                    "buildVersion": build,
                    "date": iso_date,
                    "localizedDescription": changelog,
                    "downloadURL": dl_url,
                    "size": size,
                    "minOSVersion": min_os
                }
            ],
            "appPermissions": {
                "entitlements": [],
                "privacy": {
                    "NSLocalNetworkUsageDescription": "XboxPad 需要访问本地网络，以便在局域网内超低延迟直连你的 Xbox 主机。"
                }
            }
        }
    ],
    "news": []
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(source, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "Uploading XboxPad v${VERSION} (build ${BUILD}, ${IPA_SIZE} bytes) to ${REMOTE_HOST}:${REMOTE_DIR} ..."
UPLOAD_FILES=("$IPA_PATH" "$ICON_PATH" "$TMP_DIR/source.json")
if [ -f "$ROOT_DIR/docs/web/index.html" ]; then
  UPLOAD_FILES+=("$ROOT_DIR/docs/web/index.html")
fi
if [ -f "$ROOT_DIR/docs/web/donate-alipay.png" ]; then
  UPLOAD_FILES+=("$ROOT_DIR/docs/web/donate-alipay.png")
fi
DMG_FILENAME=""
if [ -n "$MACOS_DMG_PATH" ] && [ -f "$MACOS_DMG_PATH" ]; then
  DMG_FILENAME="XboxPad-${VERSION}-macOS.dmg"
  UPLOAD_FILES+=("$MACOS_DMG_PATH")
fi
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  "${UPLOAD_FILES[@]}" \
  "${REMOTE_HOST}:${REMOTE_DIR}/"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$REMOTE_HOST" "
  set -e
  cd '${REMOTE_DIR}'
  mv -f XboxPad-unsigned.ipa '${IPA_FILENAME}'
  mv -f AppIcon.png icon.png
  chmod 644 '${IPA_FILENAME}' icon.png source.json
  [ -f index.html ] && chmod 644 index.html || true
  [ -f donate-alipay.png ] && chmod 644 donate-alipay.png || true
  ln -sf '${IPA_FILENAME}' XboxPad-latest.ipa
  # Keep at most 3 recent versioned IPAs
  ls -t XboxPad-*.ipa | grep -v 'XboxPad-latest.ipa' | grep -v 'macOS' | tail -n +4 | xargs -r rm -f
  if [ -n '${DMG_FILENAME}' ] && [ -f XboxPad-macOS.dmg ]; then
    mv -f XboxPad-macOS.dmg '${DMG_FILENAME}'
    chmod 644 '${DMG_FILENAME}'
    ln -sf '${DMG_FILENAME}' XboxPad-macOS-latest.dmg
    ls -t XboxPad-*-macOS.dmg | tail -n +4 | xargs -r rm -f
  fi
  ls -lh '${REMOTE_DIR}'
"

if [ -n "$SYNC_DIR" ] && [ -d "$SYNC_DIR" ] && ! [ "$IPA_PATH" -ef "$SYNC_DIR/XboxPad-unsigned.ipa" ]; then
  cp -f "$IPA_PATH" "$SYNC_DIR/XboxPad-unsigned.ipa"
  echo "Synced copy to $SYNC_DIR/XboxPad-unsigned.ipa"
fi
if [ -n "$SYNC_DIR" ] && [ -d "$SYNC_DIR" ] && [ -n "$MACOS_DMG_PATH" ] && [ -f "$MACOS_DMG_PATH" ]; then
  cp -f "$MACOS_DMG_PATH" "$SYNC_DIR/XboxPad-macOS.dmg"
  echo "Synced macOS DMG to $SYNC_DIR/XboxPad-macOS.dmg"
fi

echo "Verifying live HTTPS SideStore source..."
curl -fsSI "${BASE_URL}/" | head -n 6
curl -fsSI "${BASE_URL}/source.json" | head -n 6
curl -fsSI "${BASE_URL}/${IPA_FILENAME}" | head -n 6
curl -fsSI "${BASE_URL}/icon.png" | head -n 6
if [ -f "$ROOT_DIR/docs/web/donate-alipay.png" ]; then
  curl -fsSI "${BASE_URL}/donate-alipay.png" | head -n 6
fi
if [ -n "$DMG_FILENAME" ]; then
  curl -fsSI "${BASE_URL}/XboxPad-macOS-latest.dmg" | head -n 6
fi
echo "DONE: SideStore Source URL = ${BASE_URL} (or ${BASE_URL}/source.json)"

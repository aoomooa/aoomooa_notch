#!/usr/bin/env bash
#
# 将已编译签名的「aoomooa🉐刘海屏.app」封装为可分发的 macOS DMG（带 /Applications 快捷方式 + SHA-256）
#
# 用法：
#   ./scripts/package-dmg.sh                                     # 默认取 /Applications/aoomooa🉐刘海屏.app（若不存在则取 .build Release 产物）
#   ./scripts/package-dmg.sh "/Applications/aoomooa🉐刘海屏.app"  # 显式指定 .app 路径
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DISPLAY_NAME="aoomooa🉐刘海屏.app"
BUNDLE_ID="com.aoomooa.notch"
DIST_DIR="${ROOT}/dist"
DMG_NAME="aoomooa-notch.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"
SHA_PATH="${DMG_PATH}.sha256"

if [[ $# -ge 1 ]]; then
  SRC_APP="$1"
elif [[ -d "/Applications/${APP_DISPLAY_NAME}" ]]; then
  SRC_APP="/Applications/${APP_DISPLAY_NAME}"
elif [[ -d "${ROOT}/.build/Build/Products/Release/Boring Notch.app" ]]; then
  SRC_APP="${ROOT}/.build/Build/Products/Release/Boring Notch.app"
else
  echo "✗ 找不到已编译的 App，请先运行 ./scripts/build-install.sh" >&2
  exit 1
fi

PLIST="${SRC_APP}/Contents/Info.plist"
[[ -f "${PLIST}" ]] || { echo "✗ 无效的 App 包：${SRC_APP}" >&2; exit 1; }

ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"

if [[ "${ACTUAL_ID}" != "${BUNDLE_ID}" ]]; then
  echo "✗ Bundle ID 不匹配：期望 ${BUNDLE_ID}，实际 ${ACTUAL_ID}" >&2
  exit 1
fi

echo "▶ 源应用：${SRC_APP}"
echo "▶ 标识：${ACTUAL_ID} · 版本 v${VERSION} (build ${BUILD})"

STAGE="$(mktemp -d -t aoomooa-dmg-stage)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${SHA_PATH}"

ditto "${SRC_APP}" "${STAGE}/${APP_DISPLAY_NAME}"
ln -s /Applications "${STAGE}/Applications"

echo "▶ 正在生成压缩镜像 ${DMG_PATH}…"
hdiutil create \
  -volname "AooMooa Notch ${VERSION}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "${DMG_PATH}" >/dev/null

echo "▶ 校验镜像完整性…"
hdiutil verify "${DMG_PATH}" >/dev/null

SHA256="$(shasum -a 256 "${DMG_PATH}" | awk '{print $1}')"
printf "%s  %s\n" "${SHA256}" "${DMG_NAME}" > "${SHA_PATH}"
SIZE="$(du -h "${DMG_PATH}" | awk '{print $1}')"

echo "✓ 封装完成："
echo "  DMG：   ${DMG_PATH}（${SIZE}）"
echo "  SHA256：${SHA256}"
echo "  校验文件：${SHA_PATH}"

#!/usr/bin/env bash
#
# aoomooa-notch：一键 Release 编译 → 安装到固定路径 → 从固定路径启动
#
# 为什么要这样做：macOS 的辅助功能权限认的是「Bundle ID + 签名」。
# 从 Xcode 的 DerivedData 直接 Run，签名和路径每次都变，权限就会反复失效。
# 固定 Bundle ID、固定签名、固定安装路径之后，授权一次就能一直用。
#
# 用法：
#   ./scripts/build-install.sh
#   TEAM_ID=ABCDE12345 ./scripts/build-install.sh     # 临时指定 Team ID
#   ICON=~/路径/图标.png ./scripts/build-install.sh     # 先生成整套 App 图标再编译（透明底可加 ICON_BG="#RRGGBB"）
#
set -euo pipefail

# ─── 需要你确认 / 替换的变量 ──────────────────────────────────────────────
# TEAM_ID：你的开发者 Team ID。Xcode → 设置 → 账户 → 选中 Apple ID → 看 Team 一栏，
#          或在钥匙串里看「Apple Development: …」证书的「组织单位」。
#          留空 = 本地临时签名（能运行，但每次编译后辅助功能权限仍会失效）。
#          说明：免费 Apple ID 的签名能大幅改善这个问题，但证书 7 天过期，过期后重新运行本脚本即可；
#          想彻底根治需要付费开发者账号（Developer ID）。
TEAM_ID="${TEAM_ID:-}"
# 没填就自动从钥匙串里的「Apple Development」证书读 Team ID（证书的“组织单位 OU”）
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
  if [[ -n "$TEAM_ID" ]]; then echo "ℹ︎ 自动找到开发证书的 Team ID：$TEAM_ID"; fi
fi
# SCHEME：Xcode 里的 scheme 名，一般不用改
SCHEME="${SCHEME:-boringNotch}"
# APP_NAME：安装到 /Applications 下的名字（不带 .app）
APP_NAME="${APP_NAME:-aoomooa}"
# BUNDLE_ID：必须和 project.pbxproj 里主 App 的 PRODUCT_BUNDLE_IDENTIFIER 一致；
#            如果要换，两边一起换（XPC 助手的 ID 不要动）
BUNDLE_ID="${BUNDLE_ID:-com.aoomooa.notch}"
# ─────────────────────────────────────────────────────────────────────────

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/boringNotch.xcodeproj"
DERIVED="$ROOT/.build"
DEST="/Applications/$APP_NAME.app"

cd "$ROOT"

if [[ -n "${ICON:-}" ]]; then
  echo "▶ 生成 App 图标：$ICON"
  if [[ -n "${ICON_BG:-}" ]]; then
    swift "$ROOT/scripts/make-appicon.swift" "$ICON" "$ICON_BG"
  else
    swift "$ROOT/scripts/make-appicon.swift" "$ICON"
  fi
fi

if [[ -n "$TEAM_ID" ]]; then
  echo "▶ 使用 Team $TEAM_ID 签名（Apple Development）"
  SIGN_ARGS=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic
             CODE_SIGN_IDENTITY="Apple Development" "CODE_SIGN_IDENTITY[sdk=macosx*]=Apple Development"
             -allowProvisioningUpdates)
else
  echo "▶ 未设置 TEAM_ID：使用本地临时签名（辅助功能权限每次编译后需要重新授权）"
  SIGN_ARGS=(CODE_SIGN_IDENTITY="-" "CODE_SIGN_IDENTITY[sdk=macosx*]=-" DEVELOPMENT_TEAM="")
fi

echo "▶ Release 编译中（第一次会下载依赖，需要几分钟）…"
mkdir -p "$DERIVED"
LOG="$DERIVED/xcodebuild.log"
set +e
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  "${SIGN_ARGS[@]}" \
  build > "$LOG" 2>&1
STATUS=$?
set -e
grep -E "error:" "$LOG" | head -30 || true
if [[ $STATUS -ne 0 ]]; then
  echo "✗ 编译失败（完整日志：$LOG）。把上面的 error 行发给 Claude。" >&2
  exit 1
fi
echo "✓ BUILD SUCCEEDED"

BUILT="$DERIVED/Build/Products/Release/Boring Notch.app"
if [[ ! -d "$BUILT" ]]; then
  BUILT="$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "*.app" -print -quit)"
fi
if [[ -z "$BUILT" || ! -d "$BUILT" ]]; then
  echo "✗ 没找到编译产物（日志：$LOG）。" >&2
  exit 1
fi

ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")"
if [[ "$ACTUAL_ID" != "$BUNDLE_ID" ]]; then
  echo "✗ 编译出来的 Bundle ID 是 $ACTUAL_ID，和脚本里的 $BUNDLE_ID 不一致，先把两边改成一样。" >&2
  exit 1
fi

echo "▶ 退出正在运行的旧版本…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
osascript -e 'tell application id "theboringteam.boringnotch" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  pgrep -f "$DEST/Contents/MacOS/" >/dev/null || break
  sleep 0.25
done

echo "▶ 安装到 $DEST"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

# 让 Finder / 启动台 / 程序坞马上用新图标（不然可能还显示缓存里的旧图标）
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true

echo "▶ 签名信息："
codesign -dv "$DEST" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature" || true
if codesign -dv "$DEST" 2>&1 | grep -q "Signature=adhoc"; then
  echo "⚠︎ 现在是临时签名（ad-hoc）：每次重新编译后，辅助功能权限都要重新勾一次。"
  echo "  解决：Xcode → 设置 → 账户 登录 Apple ID 并创建「Apple Development」证书，再运行本脚本。"
fi

echo "▶ 启动 $DEST"
open "$DEST"

if [[ -d "/Applications/Boring Notch.app" ]]; then
  echo "ℹ︎ 发现旧的 /Applications/Boring Notch.app，确认新版本没问题后可以手动删掉它。"
fi
echo "✓ 完成。第一次安装请在 系统设置 → 隐私与安全性 → 辅助功能 里打开「$APP_NAME」。"

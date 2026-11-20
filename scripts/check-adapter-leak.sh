#!/usr/bin/env bash
#
# 验收：连续启动 / 退出 aoomooa 10 次，看有没有残留的 mediaremote-adapter.pl
#
# 用法：./scripts/check-adapter-leak.sh [次数]
# 只读检查，不会结束任何进程。
#
set -uo pipefail

APP="/Applications/aoomooa🉐刘海屏.app"
BUNDLE_ID="com.aoomooa.notch"
ROUNDS="${1:-10}"

count() { pgrep -f "mediaremote-adapter.pl" | wc -l | tr -d ' '; }

[[ -d "$APP" ]] || { echo "找不到 $APP，先运行 ./scripts/build-install.sh"; exit 1; }

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 2
BEFORE=$(count)
echo "开始前已有 mediaremote-adapter.pl：$BEFORE 个（可能来自原版 Boring Notch 等其它 App）"

for i in $(seq 1 "$ROUNDS"); do
  open "$APP"
  sleep 4
  RUNNING=$(count)
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 2
  echo "第 $i 次：运行中 $RUNNING 个 → 退出后 $(count) 个"
done

AFTER=$(count)
echo
if [[ "$AFTER" -le "$BEFORE" ]]; then
  echo "✅ 通过：退出后没有新增残留（$AFTER 个，开始前 $BEFORE 个）"
else
  echo "❌ 有残留：退出后 $AFTER 个，比开始前多 $((AFTER - BEFORE)) 个"
  pgrep -fl "mediaremote-adapter.pl"
  exit 1
fi

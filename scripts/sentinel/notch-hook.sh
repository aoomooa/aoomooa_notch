#!/usr/bin/env bash
#
# AooMooa Notch AI 哨兵通用 Hook 脚本（Antigravity / Claude Code / dsh-hooks-claude-code 共用）
#
# 用法：
#   notch-hook.sh antigravity     # 供 ~/.gemini/config/hooks.json 调用
#   notch-hook.sh claude          # 供 ~/.claude/settings.json 调用
#   notch-hook.sh deepseek        # 供 @deepseek-ai/dsh-hooks-claude-code 桥接调用
#
# 特性：
#   · 读取 stdin 后立即向 stdout 输出 {} 并退出，上报放后台执行（不阻塞同步 Hook）
#   · 仅发往本机 127.0.0.1，携带 0600 权限的 X-Notch-Token，刘海未运行时静默忽略
#

set -u

SOURCE="${1:-antigravity}"
PORT="${AOOMOOA_NOTCH_PORT:-17425}"
TOKEN_FILE="${AOOMOOA_NOTCH_TOKEN_FILE:-$HOME/Library/Containers/com.aoomooa.notch/Data/Library/Application Support/aoomooa-sentinel/token}"

# 一次性读入 stdin（Antigravity / Claude Code 传入的 JSON 事件）
PAYLOAD=""
if [ ! -t 0 ]; then
  PAYLOAD="$(cat 2>/dev/null || true)"
fi

# 立刻向宿主返回空 JSON（确保同步 Hook 零延迟、不改动任何权限决策）
printf '{}'

# 后台解析事件并上报（完全脱离当前 stdout/stderr，避免宿主等待子进程关闭管道）
(
  [ -r "$TOKEN_FILE" ] || exit 0
  TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE" 2>/dev/null || true)"
  [ -n "$TOKEN" ] || exit 0

  /usr/bin/python3 - "$SOURCE" "$PORT" "$TOKEN" <<'PY' "$PAYLOAD"
import json, sys, urllib.request

source = sys.argv[1]
port = sys.argv[2]
token = sys.argv[3]
raw = sys.argv[4] if len(sys.argv) > 4 else ""

try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}

event = (data.get("hookEventName") or data.get("hook_event_name") or "").strip()
state = None
label = None

if event in ("SessionStart", "PreInvocation", "PostToolUse", "PostInvocation", "UserPromptSubmit"):
    state = "working"
elif event in ("PermissionRequest", "Notification"):
    state = "attention"
    label = "需要确认"
elif event == "Stop":
    reason = str(data.get("terminationReason") or "").upper()
    err = str(data.get("error") or "").strip()
    if reason == "USER_CANCELED":
        state = "idle"
    elif err or reason.startswith("ERROR") or reason.startswith("MAX_"):
        state = "attention"
        label = "已出错" if err or reason == "ERROR" else "达到上限"
    else:
        state = "done"
        label = "已完成"

if not state:
    sys.exit(0)

body = {"source": source, "state": state}
if label:
    body["label"] = label

req = urllib.request.Request(
    f"http://127.0.0.1:{port}/status",
    data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
    headers={
        "Content-Type": "application/json",
        "X-Notch-Token": token,
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=0.4):
        pass
except Exception:
    pass
PY
) >/dev/null 2>&1 </dev/null &

exit 0

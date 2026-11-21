#!/usr/bin/env bash
#
# AooMooa Notch · AI 任务哨兵一键接入 / 卸载脚本
#
# 功能：
#   1. 将内置的三个轻量插件复制到 ~/.aoomooa-notch/（避开 macOS Desktop/Container TCC 权限拦截）
#   2. 自动检测本机已安装的 Antigravity / Claude Desktop / DeepSeek Harness，
#      安全备份（.bak）并合并对应配置（不会覆盖你原有的其他 Hook / MCP / 插件）
#   3. 校验本机回环通道（127.0.0.1:17425）连通性
#
# 用法：
#   bash "/Applications/aoomooa🉐刘海屏.app/Contents/Resources/sentinel/install.sh"
#   bash ".../install.sh" --only antigravity   # 仅接入单个工具（antigravity / claude / deepseek）
#   bash ".../install.sh" --uninstall          # 卸载哨兵插件并还原配置项
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.aoomooa-notch"
ONLY=""
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      UNINSTALL=1
      shift
      ;;
    --only)
      ONLY="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数：$1（支持 --only antigravity|claude|deepseek 或 --uninstall）" >&2
      exit 1
      ;;
  esac
done

want() {
  [[ -z "${ONLY}" || "${ONLY}" == "$1" ]]
}

# ─── 卸载模式 ─────────────────────────────────────────────────────────────────

if [[ "${UNINSTALL}" -eq 1 ]]; then
  echo "▶ 正在卸载 AooMooa Notch AI 任务哨兵接入…"

  if want "antigravity"; then
    /usr/bin/python3 - "${HOME}/.gemini/config/hooks.json" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict) and "aoomooa-notch" in data:
            shutil.copy2(path, path + ".bak")
            del data["aoomooa-notch"]
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
                f.write("\n")
            print("  ✓ 已从 Antigravity hooks.json 移除 aoomooa-notch（旧文件已备份 .bak）")
    except Exception as e:
        print(f"  ⚠︎ 跳过 Antigravity hooks.json：{e}")
PY
  fi

  if want "claude"; then
    /usr/bin/python3 - "${HOME}/Library/Application Support/Claude/claude_desktop_config.json" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
if os.path.isfile(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        servers = data.get("mcpServers") if isinstance(data, dict) else None
        if isinstance(servers, dict) and "aoomooa-notch" in servers:
            shutil.copy2(path, path + ".bak")
            del servers["aoomooa-notch"]
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
                f.write("\n")
            print("  ✓ 已从 Claude Desktop 移除 aoomooa-notch MCP（旧文件已备份 .bak）")
    except Exception as e:
        print(f"  ⚠︎ 跳过 Claude 配置：{e}")
PY
  fi

  if want "deepseek"; then
    DSH_BIN="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
    if [[ -x "${DSH_BIN}" && -d "${HOME}/.dsh" ]]; then
      "${DSH_BIN}" plugin --profile desktop remove aoomooa-notch >/dev/null 2>&1 || true
      echo "  ✓ 已从 DeepSeek Harness (desktop) 移除 aoomooa-notch 插件"
    fi
  fi

  if [[ -z "${ONLY}" ]]; then
    rm -rf "${TARGET_DIR}/notch-hook.sh" "${TARGET_DIR}/claude-mcp.py" "${TARGET_DIR}/dsh-notch-plugin"
    echo "  ✓ 已清理 ${TARGET_DIR} 中的插件脚本"
  fi
  echo "✓ 卸载完成（重启对应 AI 应用后生效）。"
  exit 0
fi

# ─── 安装模式 ─────────────────────────────────────────────────────────────────

echo "▶ 1/3 复制哨兵插件到 ${TARGET_DIR}…"
mkdir -p "${TARGET_DIR}"
chmod 700 "${TARGET_DIR}"

for f in notch-hook.sh claude-mcp.py; do
  if [[ ! -f "${SCRIPT_DIR}/${f}" ]]; then
    echo "✗ 缺少插件文件：${SCRIPT_DIR}/${f}" >&2
    exit 1
  fi
  cp "${SCRIPT_DIR}/${f}" "${TARGET_DIR}/${f}"
  chmod 755 "${TARGET_DIR}/${f}"
done

if [[ ! -d "${SCRIPT_DIR}/dsh-notch-plugin" ]]; then
  echo "✗ 缺少插件目录：${SCRIPT_DIR}/dsh-notch-plugin" >&2
  exit 1
fi
rm -rf "${TARGET_DIR}/dsh-notch-plugin"
cp -R "${SCRIPT_DIR}/dsh-notch-plugin" "${TARGET_DIR}/dsh-notch-plugin"
echo "  ✓ 已安装脚本：notch-hook.sh · claude-mcp.py · dsh-notch-plugin/"

echo
echo "▶ 2/3 检测本机 AI 工具并写入配置…"
CONFIGURED=0
CLAUDE_CONFIGURED=0
DSH_CONFIGURED=0

# --- 1) Antigravity ---
if want "antigravity"; then
  if [[ -d "/Applications/Antigravity.app" || -d "${HOME}/.gemini" || "${ONLY}" == "antigravity" ]]; then
    /usr/bin/python3 - "${HOME}/.gemini/config/hooks.json" "${TARGET_DIR}/notch-hook.sh" <<'PY'
import json, os, shutil, sys
hooks_path, script_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(hooks_path), exist_ok=True)
data = {}
if os.path.isfile(hooks_path):
    try:
        with open(hooks_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
            data = json.loads(raw) if raw else {}
        if not isinstance(data, dict):
            print(f"  ⚠︎ {hooks_path} 根结构不是 JSON 对象，已跳过避免破坏原配置")
            sys.exit(0)
    except Exception as e:
        print(f"  ⚠︎ 解析 {hooks_path} 失败（{e}），已跳过")
        sys.exit(0)

cmd = f"{script_path} antigravity"
entry = {
    "PreInvocation": [{"type": "command", "command": cmd}],
    "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": cmd}]}],
    "Stop": [{"type": "command", "command": cmd}],
}
if data.get("aoomooa-notch") == entry:
    print("  ✓ Antigravity：已是最新配置")
else:
    if os.path.isfile(hooks_path):
        shutil.copy2(hooks_path, hooks_path + ".bak")
    data["aoomooa-notch"] = entry
    with open(hooks_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  ✓ Antigravity：已写入 {hooks_path}（仅挂非权限 Hook）")
PY
    CONFIGURED=$((CONFIGURED + 1))
  else
    echo "  · Antigravity：未检测到，已跳过"
  fi
fi

# --- 2) Claude Desktop / Cowork ---
if want "claude"; then
  CLAUDE_DIR="${HOME}/Library/Application Support/Claude"
  if [[ -d "/Applications/Claude.app" || -d "${CLAUDE_DIR}" || "${ONLY}" == "claude" ]]; then
    /usr/bin/python3 - "${CLAUDE_DIR}/claude_desktop_config.json" "${TARGET_DIR}/claude-mcp.py" <<'PY'
import json, os, shutil, sys
cfg_path, script_path = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
data = {}
if os.path.isfile(cfg_path):
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            raw = f.read().strip()
            data = json.loads(raw) if raw else {}
        if not isinstance(data, dict):
            print(f"  ⚠︎ {cfg_path} 根结构不是 JSON 对象，已跳过避免破坏原配置")
            sys.exit(0)
    except Exception as e:
        print(f"  ⚠︎ 解析 {cfg_path} 失败（{e}），已跳过")
        sys.exit(0)

servers = data.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    print(f"  ⚠︎ {cfg_path} 中 mcpServers 不是对象，已跳过")
    sys.exit(0)

entry = {"command": "/usr/bin/python3", "args": [script_path]}
if servers.get("aoomooa-notch") == entry:
    print("  ✓ Claude Desktop：已是最新 MCP 配置")
else:
    if os.path.isfile(cfg_path):
        shutil.copy2(cfg_path, cfg_path + ".bak")
    servers["aoomooa-notch"] = entry
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  ✓ Claude Desktop：已写入 {cfg_path}")
PY
    CONFIGURED=$((CONFIGURED + 1))
    CLAUDE_CONFIGURED=1
  else
    echo "  · Claude Desktop：未检测到，已跳过"
  fi
fi

# --- 3) DeepSeek Harness (dsh) ---
if want "deepseek"; then
  DSH_BIN="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
  if [[ -x "${DSH_BIN}" ]]; then
    if "${DSH_BIN}" plugin --profile desktop add "${TARGET_DIR}/dsh-notch-plugin" >/dev/null 2>&1; then
      echo "  ✓ DeepSeek Harness：已通过 dsh 安装插件到 desktop profile"
    else
      echo "  ⚠︎ DeepSeek Harness：dsh plugin add 返回非零（可能已安装或 profile 未初始化，可手动运行：\"${DSH_BIN}\" plugin --profile desktop add \"${TARGET_DIR}/dsh-notch-plugin\"）"
    fi
    CONFIGURED=$((CONFIGURED + 1))
    DSH_CONFIGURED=1
  elif [[ "${ONLY}" == "deepseek" ]]; then
    echo "  ⚠︎ 未找到 /Applications/DeepSeek Harness.app，请先安装 DeepSeek Harness"
  else
    echo "  · DeepSeek Harness：未检测到，已跳过"
  fi
fi

echo
echo "▶ 3/3 检查本机哨兵通道（127.0.0.1:17425）…"
TOKEN_FILE="${TARGET_DIR}/token"
if [[ -r "${TOKEN_FILE}" ]]; then
  TOKEN="$(tr -d '\r\n' < "${TOKEN_FILE}")"
  if curl -fsS --max-time 2 -H "X-Notch-Token: ${TOKEN}" http://127.0.0.1:17425/health >/dev/null 2>&1; then
    echo "  ✓ 通道已连通（aoomooa🉐刘海屏 正在运行并监听 127.0.0.1:17425）"
  else
    echo "  ℹ︎ 尚未检测到监听：请先启动 /Applications/aoomooa🉐刘海屏.app（并确认设置中已开启 AI 哨兵）"
  fi
else
  echo "  ℹ︎ 尚未生成口令文件：启动一次 aoomooa🉐刘海屏.app 后会自动生成 ${TOKEN_FILE}"
fi

echo
if [[ "${CONFIGURED}" -eq 0 ]]; then
  echo "ℹ︎ 未检测到上述三款 AI 桌面应用；脚本已就绪于 ${TARGET_DIR}，安装对应工具后重跑本脚本即可。"
elif [[ "${CLAUDE_CONFIGURED}" -eq 0 && "${DSH_CONFIGURED}" -eq 0 ]]; then
  echo "✓ 接入完成！Antigravity 下一轮对话即可自动亮灯。"
else
  echo "✓ 接入完成！接下来只需："
  if [[ "${CLAUDE_CONFIGURED}" -eq 1 ]]; then
    echo "  1. 重启 Claude Desktop，首次调用 set_notch_status 时选「始终允许 / Always Allow」"
    echo "  2. 在 Claude 设置 → 个人偏好（Custom Instructions）中粘入："
    echo "     仅在多步骤或较耗时的长任务中调用 set_notch_status 工具：开始长任务时传 working，停下来需要我确认/决策前传 attention，给出最终答复前传 done。普通的简短问答不要调用此工具。"
  fi
  if [[ "${DSH_CONFIGURED}" -eq 1 ]]; then
    echo "  · 如 DeepSeek Harness 正在运行，重启一次使插件生效。"
  fi
fi

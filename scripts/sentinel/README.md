# AI 任务哨兵接入指南（Antigravity · DeepSeek Harness · Claude）

AooMooa Notch 启动后，会在本机回环地址 **`127.0.0.1:17425`** 启动极简状态监听（空闲 `0.0%` CPU）：
- **口令鉴权**：首次启动自动生成 256-bit 随机口令，写入 `~/Library/Containers/com.aoomooa.notch/Data/Library/Application Support/aoomooa-sentinel/token`（权限 `0600`，仅当前用户可读）。
- **防跨站请求**：必须携带自定义请求头 `X-Notch-Token`，凡带 `Origin` 头的浏览器请求一律 `403` 拒绝。
- **隐私边界**：仅在内存中保存当前灯态与简短状态标签，不写日志、不落盘任何对话内容。

---

## 0. 手动测试（验证本机通道）

```bash
TOKEN="$(cat "$HOME/Library/Containers/com.aoomooa.notch/Data/Library/Application Support/aoomooa-sentinel/token")"
curl -s -X POST http://127.0.0.1:17425/status \
  -H "Content-Type: application/json" \
  -H "X-Notch-Token: $TOKEN" \
  -d '{"source":"antigravity","state":"working"}'
```

---

## 1. Antigravity（官方全局 Hook）

编辑 `~/.gemini/config/hooks.json`（把路径替换为你本机仓库绝对路径；仅挂非权限事件，绝不影响工具审批弹窗）：

```json
{
  "aoomooa-notch": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "/Users/aoomooa/Desktop/5_Tech/4_Apps/aoomooa_notch/scripts/sentinel/notch-hook.sh antigravity"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/aoomooa/Desktop/5_Tech/4_Apps/aoomooa_notch/scripts/sentinel/notch-hook.sh antigravity"
          }
        ]
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "/Users/aoomooa/Desktop/5_Tech/4_Apps/aoomooa_notch/scripts/sentinel/notch-hook.sh antigravity"
      }
    ]
  }
}
```

> 同一份 `notch-hook.sh` 也可直接复用于未来需要接的 Claude Code（`~/.claude/settings.json` 传参 `claude`）或 `@deepseek-ai/dsh-hooks-claude-code`（传参 `deepseek`）。

---

## 2. DeepSeek Harness (`dsh` 原生 Cordis 插件)

本目录已提供零依赖原生插件 `scripts/sentinel/dsh-notch-plugin/`，直接订阅 `dsh-session` 内置的 `session/event`：
- `turn/start` / `step/start` / `step/end` / `approval/decided` → 🔘 灰灯（工作中，刷新 5 分钟心跳）
- `approval/asked` → 🔴 红灯（需要确认）
- `turn/end` → 🟢 绿灯（已完成）/ 🔴 红灯（已出错）/ 熄灭
- 超时未更新 → 🟠 橙灯（很久没消息）

将该本地插件通过官方命令挂入 `desktop` profile（已自带 `cordis.patch.yml`，安装即自动启用）：

```bash
DSH="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
"$DSH" plugin --profile desktop add /Users/aoomooa/Desktop/5_Tech/4_Apps/aoomooa_notch/scripts/sentinel/dsh-notch-plugin
```

> 若使用 `web` profile，将命令中的 `desktop` 换为 `web` 即可。

---

## 3. Claude Desktop / Cowork（极简本地 MCP）

1. 编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`，加入：

```json
{
  "mcpServers": {
    "aoomooa-notch": {
      "command": "/usr/bin/python3",
      "args": [
        "/Users/aoomooa/Desktop/5_Tech/4_Apps/aoomooa_notch/scripts/sentinel/claude-mcp.py"
      ]
    }
  }
}
```

2. 重启 Claude Desktop。第一次触发 `set_notch_status` 时，请点击 **「始终允许 / Always Allow」**，防止工具权限弹窗反而阻塞流程。
3. 在 Claude 的 **全局自定义指令（Custom Instructions）** 中补充一句：

> 仅在多步骤或较耗时的长任务中调用 `set_notch_status` 工具：开始长任务时传 `working`，停下来需要我确认/决策前传 `attention`，给出最终答复前传 `done`。普通的简短问答不要调用此工具。

4. Claude 侧独立超时默认为 **20 分钟**（可在「设置 → aoomooa → AI 哨兵」修改），超时未收到更新会温和提示「很久没消息」。

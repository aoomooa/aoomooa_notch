# AI 任务哨兵接入指南（Antigravity · Claude · DeepSeek Harness）

AooMooa Notch 启动后，会在本机回环地址 **`127.0.0.1:17425`** 启动极简状态监听（空闲 `0.0%` CPU）：
- **口令鉴权**：首次启动自动生成 256-bit 随机口令，并自动镜像到 `~/.aoomooa-notch/token`（目录 `0700`、文件 `0600`，避开 macOS Desktop / Container TCC 拦截，仅当前用户可读）。
- **防跨站请求**：必须携带自定义请求头 `X-Notch-Token`，凡带 `Origin` 头的浏览器请求一律 `403` 拒绝。
- **隐私边界**：仅在内存中保存当前灯态与简短状态标签，不写日志、不落盘任何对话内容。

---

## 0. 安装脚本到本地非 TCC 目录

先把本目录脚本复制到 `~/.aoomooa-notch/`（避免仓库放在 `~/Desktop` 或 `~/Documents` 时被 macOS 拦截子进程执行）：

```bash
mkdir -p ~/.aoomooa-notch
cp scripts/sentinel/notch-hook.sh scripts/sentinel/claude-mcp.py ~/.aoomooa-notch/
chmod +x ~/.aoomooa-notch/notch-hook.sh ~/.aoomooa-notch/claude-mcp.py
rm -rf ~/.aoomooa-notch/dsh-notch-plugin
cp -R scripts/sentinel/dsh-notch-plugin ~/.aoomooa-notch/dsh-notch-plugin
```

手动验证本机通道是否畅通：

```bash
TOKEN="$(cat "$HOME/.aoomooa-notch/token")"
curl -s -X POST http://127.0.0.1:17425/status \
  -H "Content-Type: application/json" \
  -H "X-Notch-Token: $TOKEN" \
  -d '{"source":"antigravity","state":"working"}'
```

---

## 1. Antigravity（官方全局 Hook）

编辑 `~/.gemini/config/hooks.json`（把 `<你的用户名>` 换成你的 macOS 用户名；仅挂非权限事件，绝不影响工具审批弹窗）：

```json
{
  "aoomooa-notch": {
    "PreInvocation": [
      {
        "type": "command",
        "command": "/Users/<你的用户名>/.aoomooa-notch/notch-hook.sh antigravity"
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/<你的用户名>/.aoomooa-notch/notch-hook.sh antigravity"
          }
        ]
      }
    ],
    "Stop": [
      {
        "type": "command",
        "command": "/Users/<你的用户名>/.aoomooa-notch/notch-hook.sh antigravity"
      }
    ]
  }
}
```

> 同一份 `notch-hook.sh` 也可复用于 Claude Code（`~/.claude/settings.json` 传参 `claude`）或 `@deepseek-ai/dsh-hooks-claude-code`（传参 `deepseek`）。

---

## 2. DeepSeek Harness（`dsh` 原生 Cordis 插件）

本目录提供零依赖原生插件 `dsh-notch-plugin/`，直接订阅 `dsh-session` 内置的 `session/event`：
- `turn/start` / `step/start` / `step/end` / `approval/decided` → 灰灯（工作中，刷新超时心跳）
- `approval/asked` → 红灯（需要确认）
- `turn/end` → 绿灯（正常完成）/ 红灯（报错或被拦截）/ 熄灭（主动取消）
- 超时未更新 → 橙灯（很久没消息）

将已复制到 `~/.aoomooa-notch/dsh-notch-plugin` 的插件挂入 `desktop` profile（已自带 `cordis.patch.yml`，安装即自动启用）：

```bash
DSH="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
"$DSH" plugin --profile desktop add "$HOME/.aoomooa-notch/dsh-notch-plugin"
```

> 若使用 `web` profile，将命令中的 `desktop` 换为 `web` 即可。

---

## 3. Claude Desktop / Cowork（极简本地 MCP）

1. 编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`（把 `<你的用户名>` 换成你的 macOS 用户名）：

```json
{
  "mcpServers": {
    "aoomooa-notch": {
      "command": "/usr/bin/python3",
      "args": [
        "/Users/<你的用户名>/.aoomooa-notch/claude-mcp.py"
      ]
    }
  }
}
```

2. 重启 Claude Desktop。第一次触发 `set_notch_status` 时，请选择 **「始终允许 / Always Allow」**，避免弹窗打断长任务。
3. 在 Claude 的 **全局自定义指令（Custom Instructions）** 中补充一句：

> 仅在多步骤或较耗时的长任务中调用 `set_notch_status` 工具：开始长任务时传 `working`，停下来需要我确认/决策前传 `attention`，给出最终答复前传 `done`。普通的简短问答不要调用此工具。

4. 三个工具的超时阈值均可在 **设置 → 模块 → AI 哨兵** 独立调节，超时未收到更新会温和亮橙灯提示「很久没消息」。

# AI 任务哨兵接入指南（Antigravity · Claude · DeepSeek Harness）

> **说明**：AooMooa Notch 的三页刘海主体功能（播放控制、常用网站、系统状态、启动器、日历天气、计时器）**完全开箱即用**；**AI 任务哨兵**为可选进阶功能——为了做到 0% 闲时 CPU、零系统弹窗、不读取其他应用内存，需要给对应的 AI 工具接入随 App 内置的轻量插件。

AooMooa Notch 启动后，会在本机回环地址 **`127.0.0.1:17425`** 启动极简状态监听：
- **口令鉴权**：首次启动自动生成 256-bit 随机口令，并镜像到 `~/.aoomooa-notch/token`（目录 `0700`、文件 `0600`，仅当前用户可读）。
- **防跨站请求**：必须携带自定义请求头 `X-Notch-Token`，凡带 `Origin` 头的浏览器请求一律 `403` 拒绝。
- **隐私边界**：仅在内存中保存当前灯态与简短状态标签，不写日志、不落盘任何对话内容。

---

## 一键接入（推荐，无需 clone 仓库）

三款工具的轻量插件已**直接打包在 `aoomooa🉐刘海屏.app` 内部**。把 App 拖进 `/Applications` 并启动一次后，在终端运行这一行命令即可（也可在 **设置 → 模块 → AI 哨兵 → 试灯与接入配置** 一键复制）：

```bash
bash "/Applications/aoomooa🉐刘海屏.app/Contents/Resources/sentinel/install.sh"
```

脚本会自动完成以下工作（全部开源透明、改配置前先备份 `.bak`，绝不覆盖你原有的 Hook / MCP / 插件）：
1. 复制三款内置插件到 `~/.aoomooa-notch/`（避开 macOS Desktop / Container TCC 拦截）；
2. 自动检测本机已安装的 **Antigravity / Claude Desktop / DeepSeek Harness** 并合并写入对应配置；
3. 自动测试 `127.0.0.1:17425/health` 通道是否连通。

常用参数：
- 仅接入某一个工具：`--only antigravity` / `--only claude` / `--only deepseek`
- 完整卸载并还原配置：`bash "/Applications/aoomooa🉐刘海屏.app/Contents/Resources/sentinel/install.sh" --uninstall`

> **Claude 额外一步**：重启 Claude Desktop，首次触发 `set_notch_status` 时点击 **「始终允许 / Always Allow」**，并在 Claude 的 **个人偏好（Custom Instructions）** 粘贴下面这一句（也可在设置页一键复制）：
>
> `仅在多步骤或较耗时的长任务中调用 set_notch_status 工具：开始长任务时传 working，停下来需要我确认/决策前传 attention，给出最终答复前传 done。普通的简短问答不要调用此工具。`

---

## 手动接入参考（如需自行审查或定制）

### 0. 手动验证本机通道

```bash
TOKEN="$(cat "$HOME/.aoomooa-notch/token")"
curl -s -X POST http://127.0.0.1:17425/status \
  -H "Content-Type: application/json" \
  -H "X-Notch-Token: $TOKEN" \
  -d '{"source":"antigravity","state":"working"}'
```

### 1. Antigravity（官方全局 Hook）

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

### 2. DeepSeek Harness（`dsh` 原生 Cordis 插件）

`dsh-notch-plugin/` 为零依赖原生插件，直接订阅 `dsh-session` 内置的 `session/event`：
- `turn/start` / `step/start` / `step/end` / `approval/decided` → 灰灯（工作中，刷新超时心跳）
- `approval/asked` → 红灯（需要确认）
- `turn/end` → 绿灯（正常完成）/ 红灯（报错或被拦截）/ 熄灭（主动取消）
- 超时未更新 → 橙灯（很久没消息）

手动挂载命令（已自带 `cordis.patch.yml`，安装即自动启用）：

```bash
DSH="/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
"$DSH" plugin --profile desktop add "$HOME/.aoomooa-notch/dsh-notch-plugin"
```

> 若使用 `web` profile，将命令中的 `desktop` 换为 `web` 即可。

### 3. Claude Desktop / Cowork（极简本地 MCP）

编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`（把 `<你的用户名>` 换成你的 macOS 用户名）：

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

三个工具的超时阈值均可在 **设置 → 模块 → AI 哨兵** 独立调节，超时未收到更新会温和亮橙灯提示「很久没消息」。

# AGENTS.md — AooMooa Notch 开发规范与避坑守则

本文件为 AI 编程助手（Antigravity / Claude / DeepSeek Harness）在本仓库工作时的常驻规则，总结自历次迭代与踩坑复盘（详版见 [docs/DEVLOG.md](docs/DEVLOG.md)）。

## 1. 身份与视觉规范
- **应用信息**：显示名称固定为 `aoomooa🉐刘海屏`，Bundle ID 固定为 `com.aoomooa.notch`，XPC 助手为 `com.aoomooa.notch.XPCHelper`（未经用户明确要求，严禁修改）。
- **设计系统唯一来源**：所有 UI 颜色、字号、圆角、间距、动画时长与控件尺寸必须从 `boringNotch/private/DesignTokens.swift`（`DS.*`）取值，严禁在视图中硬编码魔法数字。
- **极简原则**：不写冗余的模块大标题或解释性废话；分组优先靠留白比例（如 3 倍间距）而非分割线；注意亮/暗两种系统外观下的可读性（设置页灰色圆点用 `Color(nsColor: .secondaryLabelColor)`，勿用仅适用于黑底刘海的半透明纯白）。

## 2. SwiftUI 常见陷阱规避
- **数字格式化**：端口号、ID 等严禁直接插值 `Text("\(port)")`（在德语等 Locale 下会把 `17425` 格式化成 `17.425`），必须使用 `Text(verbatim:)` 或 `String(port)`。
- **全局 Tint 污染**：`SettingsView` 顶层带有 `.tint(.effectiveAccent)`，内部普通按钮需显式声明 `.tint(.secondary)` 与 `.foregroundStyle(.primary)`，防止按钮文字被全部染红。

## 3. AI 任务哨兵（`AoomooaSentinel`）安全与跨进程边界
- **零打扰、零轮询、零落盘**：仅监听 `127.0.0.1:17425`，强制校验 `X-Notch-Token`（`0600`）并拒绝任何带 `Origin` 的请求（`403`）；空闲 CPU 必须为 `0%`，绝不写日志或落盘任何消息内容。
- **避开 macOS TCC 目录**：外部宿主（Claude Desktop / DeepSeek Harness）无法读取 App Container（`~/Library/Containers/com.aoomooa.notch/...`）或执行 `~/Desktop` 下的脚本。口令统一由 `BoringNotchXPCHelper` 镜像至 `~/.aoomooa-notch/token`，外部脚本统一由内置 `install.sh` 安装到 `~/.aoomooa-notch/`。
- **三工具适配器铁律**：
  - **Antigravity**：只挂 `PreInvocation`、`PostToolUse`、`Stop`，**严禁挂接 `PreToolUse`**（避免覆盖工具权限审批）；`Stop` 必须按严格白名单判定正常完成才亮绿灯。
  - **DeepSeek Harness (`dsh`)**：Cordis 插件通过 `ctx.on("session/event")` 监听，**不要写 `export const inject = ["session"]`**（实际服务名为复数 `sessions`）；解析 `turn/end` 的 `event.data.reason` 时必须兼容 `{ kind }` 对象与字符串。
  - **Claude Desktop**：云端执行任务，退出桌面 App 时不可自动清除 `.claude` 灯态；需要配合 Claude 设置「您的 Claude → 指令」中的全局触发词使模型主动调用 `set_notch_status`。
- **内置资源闭环**：`scripts/sentinel/` 作为 Xcode Folder Reference 打包在 `Contents/Resources/sentinel/` 内，确保仅下载 `.dmg` 的用户也能离线运行 `install.sh`。

## 4. 构建、截图与发布卫生
- **防止 `.build/` 临时包抢占 LaunchServices**：使用 `./scripts/build-install.sh` 编译并安装到 `/Applications/aoomooa🉐刘海屏.app`。若因单测或离屏截图在 `.build/Build/Products/Release/` 下单独构建过未签名的 `Boring Notch.app`，**任务结束前必须立即删除 `.build/Build/Products/Release/*.app`**，防止 macOS 开机自启或 `open` 命令错拉起 `.build/` 下的临时包。
- **离屏截图注意事项**：包含 `NSViewRepresentable`（如 `ScrollView`、`TextField`、手势层）的页面不可用 `ImageRenderer`（会出现黄色 `🚫` 占位框），应使用 `NSHostingView.cacheDisplay(in:to:)` 并临时屏蔽 `rotation3DEffect`。
- **Git 与发布纪律**：`dist/`、`*.dmg`、`*.zip` 保持在 `.gitignore` 中，绝不把二进制安装包提交进 Git 仓库。

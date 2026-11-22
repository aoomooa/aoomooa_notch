# AooMooa Notch 开发者日志（DevLog）

本日志记录每次重要迭代的架构演进、设计决策与踩坑复盘。

---

## 2026-11-21 ~ 11-22 · Session `v1.1.0`（极简三页重构 · AI 任务哨兵 · 媒体对称共存）

### 一、本次 Session 完成内容总结

1. **展开态三页极简化重构**
   - 移除文件架（Shelf）与 AirDrop 页面及全局拖拽监听，收敛为固定三页：
     - **第 1 页（首页）**：正在播放（实时封面取色）· 常用网站 2×2（`aoomooa` / `GitHub` / `Cloudflare` / `X`，支持从网页 `apple-mobile-web-app-title` / `application-name` / `og:site_name` / `<title>` 自动抓取真实站名与高清图标）· 独立 AI 入口（`DeepSeek` / `Gemini`）。
     - **第 2 页（工作台）**：5 行纯数字系统状态（CPU / 内存 / 磁盘 / 网络 / 温度，仅在页面可见时采样）· 4×2 本地 App 与网页混合启动器。
     - **第 3 页（时间）**：周日历与提醒事项（顶栏集成 `wttr.in` 紧凑天气胶囊）· 2×2 预设 + 滚轮紧凑计时器（修复滚轮页上滑误关刘海问题）。
   - 交互统一：悬停展开、移开 **3 秒延迟收起**、默认记住上次停留页、刘海任意空白处**右键打开设置或退出应用**。

2. **AI 任务哨兵（Antigravity · Claude · DeepSeek Harness）**
   - 在 `boringNotch/private/AoomooaSentinel.swift` 实现纯事件驱动的本机回环 HTTP 监听（`127.0.0.1:17425`），空闲 `0.0%` CPU、零系统通知弹窗、不落盘任何对话内容。
   - 安全边界：强制校验 `0600` 权限的 256-bit 随机口令（`X-Notch-Token`，常时间比较），拒绝一切携带 `Origin` 头的浏览器跨站请求（`403`）。
   - 视觉与灯语：收起态左耳排 AI 原生 Logo，右耳按 **`左1↔右1 · 左2↔右2 · 左3↔右3`** 水平一一对应亮灯：
     - ⚪️ **灰灯（柔和呼吸）**：工作中（`working`）
     - 🟢 **绿灯（常亮，不自动淡出）**：已完成（`done`）
     - 🔴 **红灯（常亮）**：需要确认 / 出错（`attention`）
     - 🟠 **橙灯（常亮）**：超过独立阈值很久没消息（`stale`，默认 AGY 5m / DS 5m / Claude 20m）
   - **媒体与 AI 镜像对称共存**：播放视频或音乐时，外侧对称伸出小封面与微降噪音频波形，与内侧 AI 保持 `12 pt`（3 倍组内间距）纯留白分组，无竖线；小封面叠加 **柔波扩散环 + 银幕主色呼吸溢光**，暂停播放即自动收翼。
   - **内置插件一键接入**：将 `scripts/sentinel/`（含 `install.sh`、`notch-hook.sh`、`claude-mcp.py`、`dsh-notch-plugin/`）直接打入 `aoomooa🉐刘海屏.app/Contents/Resources/sentinel/`，只下载 `.dmg` 的用户无需 clone 仓库即可一行命令自动完成三工具接入与卸载。

3. **设置精简、品牌化与 `v1.1.0` 发布**
   - 10 栏上游设置收敛为 **3 栏全中文设置**（`常规` · `模块` · `诊断与关于`），删除不再使用的系统音量/亮度浮窗替换、辅助功能授权与充电提醒。
   - 集成四眼猫矢量徽标 `AoomooaLogo.imageset`（`preserves-vector-representation`），启用独立版本号 **`1.1.0 (build 2)`**，新增 `scripts/package-dmg.sh` 一键封装并完成 GitHub Release `v1.1.0` 与个人站 `/notch` 页面同步上线。

---

### 二、为什么会踩坑：根因复盘与经验教训

#### 1. macOS 沙盒与 TCC 权限隔离坑（Claude / DSH 无法读口令或启动脚本）
- **现象**：Claude Desktop 启动 MCP 脚本报 `[Errno 1] Operation not permitted`；外部脚本读不到主程序生成的口令文件。
- **根因**：
  1. 主程序开启了 App Sandbox，口令写在 `~/Library/Containers/com.aoomooa.notch/...`，受 macOS **App Data TCC** 保护，外部进程（Claude / DSH）无权读取；
  2. 项目源码放在 `~/Desktop/...`，受 macOS **Desktop 文件夹 TCC** 保护，后台子进程直接执行桌面目录下的脚本会被系统静默拦截。
- **解法与教训**：跨进程共享的口令与插件脚本**绝不能放在 `~/Desktop`、`~/Documents` 或 App Container 内**。统一通过无沙盒的 `BoringNotchXPCHelper` 将口令镜像到 `~/.aoomooa-notch/token`（`0700` 目录 + `0600` 文件），并将所有外部执行的脚本复制到 `~/.aoomooa-notch/` 下运行。

#### 2. DeepSeek Harness (`dsh`) 插件静默卡死与误报红灯
- **现象 1**：插件在 DSH 里显示已启用，但完全不发请求。
  - **根因**：插件写了 `export const inject = ["session"]`，而检视 `dsh-session` 源码发现其注册的 Cordis 服务名是复数 **`"sessions"`**；Cordis 会无限等待不存在的 `"session"` 依赖且不抛错。实际上订阅 `ctx.on("session/event", ...)` 根本不需要 `inject`。
- **现象 2**：DSH 正常回复完却一直亮红灯；某个旧会话无法发消息。
  - **根因**：DSH v4 的 `turn/end` 事件里 `event.data.reason` 是对象 `{ kind: "completed" | "blocked" | "error" | "aborted" }` 而非字符串，直接 `String(reason)` 变成 `"[object Object]"` 落入异常分支误亮红灯；另外该测试会话曾被归档在 `~/.dsh/storages/workspace.json` 的 `archivedSessionIds` 中，被 DSH 自身的 `ArchivedSessionGate` 拦截返回 `blocked`。
- **教训**：对接第三方插件框架时，先核对宿主源码的真实服务注册名与事件 payload 结构（同时兼容 `string` 与 `{ kind }` 对象），绝不凭猜测写依赖声明。

#### 3. Antigravity 与 Claude 的生命周期差异坑
- **Antigravity**：
  - **不能挂 `PreToolUse`**：`PreToolUse` 需要返回权限决策（`allow/ask/deny`），挂接不当会干扰官方审批流；只挂 `PreInvocation`、`PostToolUse`、`Stop` 最安全。
  - **`Stop` 不等于成功**：报错、取消、达到上限都会触发 `Stop`，必须用严格白名单（仅明确完成原因才映射 `done` 绿灯，报错映射 `attention` 红灯，取消映射 `idle` 熄灯）。
- **Claude Desktop**：
  - **云端执行特性**：退出本地 Claude App 不会中止云端任务，因此本地 App 退出自动清灯逻辑必须跳过 `.claude`。
  - **被动 MCP 工具特性**：Claude Desktop 没有对话生命周期 Hook，仅在插件页开启「始终允许」不会让模型主动调用 `set_notch_status`；必须在 **设置 → 您的 Claude → 指令** 中配置全局触发指令，模型才会在每个新会话中主动同步状态灯。

#### 4. SwiftUI 区域格式化、全局染色与离屏渲染坑
- **端口号变成 `17.425`**：SwiftUI `Text("127.0.0.1:\(port)")` 会按系统 Locale 给 `UInt16` 加千分位分隔符（德语区为 `.`）。**凡渲染端口号、年份、无格式数字，一律用 `Text(verbatim:)` 或 `String(value)`**。
- **按钮文字全变红**：父视图 `.tint(.effectiveAccent)` 会把 Form 内普通按钮文字全部染成红色（导致“绿·已完成”显示红字）。**带语义色点的按钮必须显式加 `.tint(.secondary)` + `.foregroundStyle(.primary)`**。
- **离屏自动截图黄框与 3D 翻转**：
  - SwiftUI `ImageRenderer` 无法渲染 `NSViewRepresentable`（如 `ScrollView`、`TextField`、手势层），会画成黄底 `🚫` 占位符；
  - AppKit `NSView.cacheDisplay(in:to:)` 能完整渲染混合视图，但会翻转 `rotation3DEffect` 的 3D 坐标。截图包含 `NSViewRepresentable` 时应走 `cacheDisplay` 并临时关闭 3D 翻转。

#### 5. `.build/` 临时产物抢占 macOS 开机自启 + DMG 脱离源码仓库问题
- **现象 1**：开机后启动的是 `.build/Build/Products/Release/Boring Notch.app` 临时无沙盒包，而非 `/Applications/aoomooa🉐刘海屏.app`，导致口令路径错位。
  - **根因**：昨晚离屏截图编译的 `.build/` 产物具有相同 Bundle ID (`com.aoomooa.notch`) 且时间戳更新，被 macOS LaunchServices 优先选中。
  - **教训**：**任何临时编译或截图任务结束后，必须立即清理 `.build/Build/Products/Release/*.app`**，保证 `/Applications/aoomooa🉐刘海屏.app` 是本机唯一可启动包。
- **现象 2**：只从网页下载 `.dmg` 的用户本地没有 git 仓库里的 `scripts/sentinel/`。
  - **教训**：凡需要用户本机配合执行的外部插件/脚本，必须作为 Xcode Folder Reference 打进 `.app/Contents/Resources/`，让安装包本身自包含闭环。

#### 6. 计时器到点“闹钟”提示音与轻量化零点击交互
- **现象**：计时器倒计时结束后，原代码仅调用了一次 `NSSound(named: "Hero")?.play()`（走界面音效声道且仅 0.4 秒），几乎听不见；而第一版纯代码合成正弦波听感生硬，且展开刘海后还需要手点「完成」按钮才能消除刘海上的“时间到”状态。
- **根因与设计反思**：
  1. `NSSound(named:)` 走系统「界面音效」声道（容易被静音），且纯正弦波合成音缺乏苹果原生乐器采样质感；
  2. 刘海屏工具的核心定位是**轻量化、零打扰**——到点时应当靠**收起态双侧闪烁 + 铃声**提醒用户，用户只需把鼠标移到刘海屏等待展开，使命即告完成，绝不该强迫用户再点一次按钮。
- **解法**：
  1. 在 `AoomooaTimer.swift` 中使用 `AVAudioPlayer` 直接加载 macOS 系统内置 `ToneLibrary.framework` 的苹果原生清脆铃声（默认「水晶 Crystals」，处于纯正弦波与柔和环境乐之间的清脆水晶钟声，并在「设置 → 模块 → 计时器」支持一键切换「水晶 / 简报双音 / 信标 / 钟楼 / 急板 / 破晓」及即时试听）；
  2. **同心三层镜像共存**：收起态刘海统一由 `AoomooaSentinelLiveActivity` 承载三者共存，从左到右为 `[⏱ 铃声 · 🎬 视频封面] ── 12pt 留白 ── [AI 图标 1..3] ── [硬件刘海] ── [AI 呼吸灯 1..3] ── 12pt 留白 ── [〰️ 视频小波浪 · 0:23 铃的时间]`，左耳与右耳总宽严格对称，互不挤压；
  3. **鼠标悬停等待刘海展开即结束**：在 `ContentView.doOpen()` 中调用 `notchTimer.acknowledgeOnExpand()`，刘海展开瞬间立即止响并复位到 `.idle`，全程零点击。


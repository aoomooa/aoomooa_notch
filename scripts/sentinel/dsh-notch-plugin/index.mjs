//
// dsh-plugin-aoomooa-notch — DeepSeek Harness 原生 Cordis 插件
//
// 订阅内置 session/event 事件流（0 轮询、零第三方依赖）：
//   · turn/start, step/start, step/end, approval/decided -> working（工作中，刷新心跳）
//   · approval/asked                                     -> attention（需要确认）
//   · turn/end (completed)                               -> done（已完成）
//   · turn/end (error)                                   -> attention（已出错）
//   · turn/end (aborted / cancelled / interrupted)       -> idle（熄灯）
//

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const name = "aoomooa-notch-sentinel";
// 注意：dsh-session 的服务名是 "sessions"，而监听 session/event 本身不依赖 inject，
// 与内置 dsh-session-persistence-jsonl 保持一致，避免因服务名不匹配导致插件挂起。

const DEFAULT_PORT = Number(process.env.AOOMOOA_NOTCH_PORT || 17425);
const DEFAULT_TOKEN_FILES = [
  process.env.AOOMOOA_NOTCH_TOKEN_FILE,
  join(homedir(), ".aoomooa-notch", "token"),
  join(
    homedir(),
    "Library",
    "Containers",
    "com.aoomooa.notch",
    "Data",
    "Library",
    "Application Support",
    "aoomooa-sentinel",
    "token"
  ),
].filter(Boolean);

function readToken(customFile) {
  const candidates = customFile ? [customFile, ...DEFAULT_TOKEN_FILES] : DEFAULT_TOKEN_FILES;
  for (const file of candidates) {
    try {
      const value = readFileSync(file, "utf8").trim();
      if (value) return value;
    } catch {
      // try next candidate
    }
  }
  return "";
}

export function apply(ctx, config = {}) {
  const port = Number(config.port || DEFAULT_PORT);
  const customTokenFile = config.tokenFile || "";
  let cachedToken = readToken(customTokenFile);

  async function report(state, label) {
    if (!cachedToken) cachedToken = readToken(customTokenFile);
    if (!cachedToken) return;

    const payload = label
      ? { source: "deepseek", state, label }
      : { source: "deepseek", state };

    const send = (token) =>
      fetch(`http://127.0.0.1:${port}/status`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Notch-Token": token,
        },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(400),
      });

    try {
      const res = await send(cachedToken);
      if (res.status === 401) {
        // 刘海重新生成了口令时重读一次
        cachedToken = readToken(customTokenFile);
        if (cachedToken) await send(cachedToken);
      }
    } catch {
      // 刘海未启动或超时时静默忽略，绝不影响 DeepSeek Harness 运行
    }
  }

  ctx.on("session/event", (_session, event) => {
    const type = event?.type;
    switch (type) {
      case "turn/start":
      case "step/start":
      case "step/end":
      case "approval/decided":
        void report("working");
        break;
      case "approval/asked":
        void report("attention", "需要确认");
        break;
      case "turn/end": {
        // DeepSeek Harness v4 中 event.data.reason 是对象 { kind: "completed" | "aborted" | "blocked" | "error" | ... }
        const rawReason = event?.data?.reason;
        const reason = String(
          rawReason && typeof rawReason === "object" ? rawReason.kind : rawReason ?? ""
        )
          .trim()
          .toLowerCase();
        if (reason === "completed") {
          void report("done", "已完成");
        } else if (
          reason === "aborted" ||
          reason === "cancelled" ||
          reason === "canceled" ||
          reason === "interrupted"
        ) {
          void report("idle");
        } else if (reason === "blocked") {
          void report("attention", "会话已归档/拦截");
        } else {
          void report("attention", "已出错");
        }
        break;
      }
      default:
        break;
    }
  });
}

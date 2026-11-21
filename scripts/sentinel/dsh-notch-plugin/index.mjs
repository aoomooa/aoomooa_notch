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
export const inject = ["session"];

const DEFAULT_PORT = Number(process.env.AOOMOOA_NOTCH_PORT || 17425);
const DEFAULT_TOKEN_FILE =
  process.env.AOOMOOA_NOTCH_TOKEN_FILE ||
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
  );

function readToken(tokenFile) {
  try {
    return readFileSync(tokenFile, "utf8").trim();
  } catch {
    return "";
  }
}

export function apply(ctx, config = {}) {
  const port = Number(config.port || DEFAULT_PORT);
  const tokenFile = config.tokenFile || DEFAULT_TOKEN_FILE;
  let cachedToken = readToken(tokenFile);

  async function report(state, label) {
    if (!cachedToken) cachedToken = readToken(tokenFile);
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
        cachedToken = readToken(tokenFile);
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
        const reason = String(event?.data?.reason || "").toLowerCase();
        if (reason === "completed") {
          void report("done", "已完成");
        } else if (reason === "error") {
          void report("attention", "已出错");
        } else {
          void report("idle");
        }
        break;
      }
      default:
        break;
    }
  });
}

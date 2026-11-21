#!/usr/bin/env python3
"""
AooMooa Notch 极简本地 MCP Server（供 Claude Desktop / Cowork 使用）

· 仅依赖 macOS 自带 /usr/bin/python3 标准库，0 外部依赖、空闲 0% CPU
· 暴露单个工具：set_notch_status(state, label?)
· 仅连接本机 127.0.0.1，读取 0600 权限的 X-Notch-Token，不落盘、不写日志
"""

import json
import os
import sys
import urllib.error
import urllib.request

PORT = int(os.environ.get("AOOMOOA_NOTCH_PORT", "17425"))
TOKEN_FILES = [
    p
    for p in [
        os.environ.get("AOOMOOA_NOTCH_TOKEN_FILE"),
        os.path.expanduser("~/.aoomooa-notch/token"),
        os.path.expanduser(
            "~/Library/Containers/com.aoomooa.notch/Data/Library/Application Support/aoomooa-sentinel/token"
        ),
    ]
    if p
]

TOOL_SPEC = {
    "name": "set_notch_status",
    "description": (
        "Update the macOS AooMooa Notch status light for Claude. "
        "Call during multi-step or long-running tasks, or whenever the user asks to test the notch light "
        "(skip for quick casual one-line Q&A): "
        "state='working' at task start, state='attention' when waiting for user approval/decision, "
        "state='done' right before delivering the final answer, or state='idle' to clear."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "state": {
                "type": "string",
                "enum": ["working", "attention", "done", "idle"],
                "description": "Current task status light state.",
            },
            "label": {
                "type": "string",
                "description": "Optional short status label (max 20 chars), e.g. '等待确认' or '已完成'.",
            },
        },
        "required": ["state"],
        "additionalProperties": False,
    },
}


def read_token() -> str:
    for path in TOKEN_FILES:
        try:
            with open(path, "r", encoding="utf-8") as f:
                val = f.read().strip()
                if val:
                    return val
        except OSError:
            continue
    return ""


def post_status(state: str, label: str = "") -> tuple[bool, str]:
    token = read_token()
    if not token:
        return False, "AooMooa Notch token file not found (is AooMooa Notch running?)"

    body = {"source": "claude", "state": state}
    if label:
        body["label"] = label[:32]

    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/status",
        data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-Notch-Token": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=0.6) as resp:
            return resp.status == 200, "ok"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, f"unreachable ({e})"


def write_message(msg: dict) -> None:
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle_request(req: dict) -> None:
    method = req.get("method")
    req_id = req.get("id")
    params = req.get("params") or {}

    # Notifications have no id -> no response required
    if req_id is None:
        return

    if method == "initialize":
        proto = params.get("protocolVersion") or "2024-11-05"
        write_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": proto,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "aoomooa-notch-sentinel", "version": "1.0.0"},
                },
            }
        )
        return

    if method == "ping":
        write_message({"jsonrpc": "2.0", "id": req_id, "result": {}})
        return

    if method == "tools/list":
        write_message({"jsonrpc": "2.0", "id": req_id, "result": {"tools": [TOOL_SPEC]}})
        return

    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "set_notch_status":
            write_message(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Unknown tool: {name}"},
                }
            )
            return

        state = str(args.get("state") or "").strip().lower()
        label = str(args.get("label") or "").strip()
        if state not in ("working", "attention", "done", "idle"):
            write_message(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": "Invalid state"}],
                        "isError": True,
                    },
                }
            )
            return

        ok, detail = post_status(state, label)
        write_message(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [{"type": "text", "text": f"notch:{state} ({detail})"}],
                    "isError": not ok,
                },
            }
        )
        return

    write_message(
        {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Method not found: {method}"},
        }
    )


def main() -> None:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(req, dict):
            handle_request(req)


if __name__ == "__main__":
    main()

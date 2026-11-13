"""Run one embedded SketchUp chat turn through the signed-in Codex runtime."""

from __future__ import annotations

import base64
import binascii
import json
import queue
import re
import threading
from pathlib import Path
import subprocess
import sys
from typing import Any

MAX_EVENT_LINE = 12 * 1024 * 1024
MAX_IMAGE = 4 * 1024 * 1024
TURN_TIMEOUT_SECONDS = 240
PROCESS_FLAGS = getattr(subprocess, "CREATE_NO_WINDOW", 0)
FALLBACK_MODELS = [
    {"id": "gpt-6.1-sol", "label": "GPT-6.1-Sol"},
    {"id": "gpt-6-astra", "label": "GPT-6-Astra"},
    {"id": "gpt-6-sol", "label": "GPT-6-Sol"},
    {"id": "gpt-6-luna", "label": "GPT-6-Luna"},
    {"id": "gpt-5.6-sol", "label": "GPT-5.6-Sol"},
    {"id": "gpt-6.1-terra", "label": "GPT-6.1 Terra"},
    {"id": "gpt-5.6-terra", "label": "GPT-5.6-Terra"},
    {"id": "gpt-5.6-luna", "label": "GPT-5.6-Luna"},
    {"id": "gpt-5.5", "label": "GPT-5.5"},
]


class LoginRequired(RuntimeError):
    pass


def auth_status(candidates):
    for executable in candidates:
        try:
            status = subprocess.run(
                [executable, "login", "status"], stdin=subprocess.DEVNULL,
                capture_output=True, encoding="utf-8", errors="replace",
                timeout=5, creationflags=PROCESS_FLAGS,
            )
            if status.returncode == 0 and "logged in using chatgpt" in (status.stdout + status.stderr).lower():
                return {"ok": True, "state": "ready", "codex_path": executable,
                        "message": "Đã kết nối với tài khoản ChatGPT."}
            if status.returncode in (0, 1):
                return {"ok": True, "state": "signed_out", "codex_path": executable,
                        "message": "Hãy đăng nhập bằng tài khoản ChatGPT của bạn."}
        except (OSError, subprocess.TimeoutExpired):
            continue
    return {"ok": True, "state": "missing", "message": "Cần cài thành phần ChatGPT một lần trên máy này."}


def list_models(executable):
    if not executable:
        raise ValueError("Chưa tìm thấy Codex.")
    with subprocess.Popen(
        [executable, "app-server", "--listen", "stdio://"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8", creationflags=PROCESS_FLAGS,
    ) as child:
        inbox = queue.Queue()

        def read():
            for line in child.stdout:
                inbox.put(line)
            inbox.put(None)

        threading.Thread(target=read, daemon=True).start()

        def send(message):
            child.stdin.write(json.dumps(message) + "\n")
            child.stdin.flush()

        def call(identifier, method, params):
            send({"id": identifier, "method": method, "params": params})
            while True:
                line = inbox.get(timeout=15)
                if line is None:
                    raise RuntimeError("Codex đã đóng kết nối danh sách model.")
                reply = json.loads(line)
                if reply.get("id") == identifier:
                    if "error" in reply:
                        raise RuntimeError("Codex từ chối yêu cầu danh sách model.")
                    return reply["result"]

        try:
            call(1, "initialize", {"clientInfo": {"name": "nep_nha_design", "version": "1.4.2"}})
            send({"method": "initialized"})
            models = call(2, "model/list", {"includeHidden": False, "limit": 100})
            return [{"id": row["model"], "label": row.get("displayName") or row["model"]}
                    for row in models["data"] if row.get("model")]
        except queue.Empty as exc:
            raise RuntimeError("Codex chưa trả về danh sách model.") from exc
        finally:
            child.kill()

INSTRUCTIONS = """Bạn là Trợ lý AI của Nếp Nhà Design chạy bên trong SketchUp.
Trả lời bằng tiếng Việt, ngắn gọn và dễ hiểu cho người mới.
Chỉ dùng các công cụ MCP của nep_nha_design để đọc hoặc thay đổi SketchUp; không dùng shell.
Với chào hỏi hoặc câu hỏi chung, trả lời trực tiếp, không gọi công cụ SketchUp.
Khi người dùng hỏi về model hoặc viewport hiện tại, phải gọi công cụ phù hợp rồi mới trả lời.
Mọi kích thước kiến trúc dùng milimet. Không tuyên bố đã thay đổi model nếu chưa có kết quả công cụ.
Giai đoạn 1 chỉ hỗ trợ kiểm tra kết nối, đọc thông tin model, chụp viewport, tạo Tag và vật liệu.
Không được nói rằng có thể dựng tường, sàn, cửa hoặc mái trong giai đoạn này.
Không gọi clear_scene trừ khi chính người dùng yêu cầu rõ ràng xóa toàn bộ đối tượng trong model.
"""


def toml_string(value: str) -> str:
    """JSON strings are valid TOML basic strings and avoid shell quoting."""
    return json.dumps(value, ensure_ascii=False)


def codex_command(request: dict[str, Any]) -> list[str]:
    codex = request.get("codex_path")
    python = request.get("python_path")
    server = request.get("mcp_server_path")
    data_dir = request.get("data_dir")
    if not all(isinstance(item, str) and item for item in (codex, python, server, data_dir)):
        raise ValueError("Thiếu đường dẫn thành phần ChatGPT hoặc MCP.")
    if not Path(server).is_file():
        raise ValueError("Không tìm thấy máy chủ MCP của Nếp Nhà Design.")

    config = [
        "-c", 'sandbox_mode="read-only"',
        "-c", f"mcp_servers.nep_nha_design.command={toml_string(python)}",
        "-c", f"mcp_servers.nep_nha_design.args=[{toml_string(server)}]",
        "-c", "mcp_servers.nep_nha_design.startup_timeout_sec=30",
        "-c", "mcp_servers.nep_nha_design.tool_timeout_sec=45",
        "-c", 'mcp_servers.nep_nha_design.disabled_tools=["clear_scene"]',
    ]
    thread_id = request.get("thread_id")
    model = request.get("model", "")
    if not isinstance(model, str) or (model and not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", model)):
        raise ValueError("Tên model không hợp lệ.")
    if model:
        config.extend(["--model", model])
    if request.get("fast") is True:
        config.extend(["-c", 'model_reasoning_effort="low"'])
    if isinstance(thread_id, str) and thread_id:
        return [
            codex, "exec", "resume", "--json", "--skip-git-repo-check",
            "--ignore-user-config", "--ignore-rules", *config, thread_id, "-",
        ]
    return [
        codex, "exec", "--json", "--color", "never",
        "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
        "-C", data_dir, *config, "-",
    ]


def collect_images(value: Any, images: list[dict[str, str]]) -> None:
    """Find MCP image content in Codex JSONL events without depending on event internals."""
    if isinstance(value, dict):
        mime = value.get("mimeType") or value.get("mime_type")
        data = value.get("data") or value.get("image_base64")
        if isinstance(mime, str) and mime.startswith("image/") and isinstance(data, str):
            try:
                raw = base64.b64decode(data, validate=True)
            except (ValueError, binascii.Error):
                raw = b""
            if 0 < len(raw) <= MAX_IMAGE and not any(item["data"] == data for item in images):
                images.append({"mime_type": mime, "data": data})
        for child in value.values():
            collect_images(child, images)
    elif isinstance(value, list):
        for child in value:
            collect_images(child, images)


def parse_events(stdout: str) -> dict[str, Any]:
    thread_id: str | None = None
    messages: list[str] = []
    errors: list[str] = []
    images: list[dict[str, str]] = []
    for raw_line in stdout.splitlines():
        if not raw_line.strip():
            continue
        if len(raw_line.encode("utf-8")) > MAX_EVENT_LINE:
            raise RuntimeError("Phản hồi ChatGPT quá lớn.")
        try:
            event = json.loads(raw_line)
        except json.JSONDecodeError:
            continue
        collect_images(event, images)
        event_type = event.get("type")
        if event_type == "thread.started" and isinstance(event.get("thread_id"), str):
            thread_id = event["thread_id"]
        elif event_type == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message" and isinstance(item.get("text"), str):
                if item["text"].strip():
                    messages.append(item["text"].strip())
        elif event_type in {"error", "turn.failed"}:
            detail = event.get("message") or event.get("error") or event
            errors.append(detail if isinstance(detail, str) else json.dumps(detail, ensure_ascii=False))

    if not messages:
        detail = errors[-1] if errors else "ChatGPT chưa trả về nội dung cuối cùng."
        raise RuntimeError(detail[:1200])
    return {"ok": True, "text": messages[-1], "thread_id": thread_id, "images": images}


def run_turn(request: dict[str, Any]) -> dict[str, Any]:
    prompt = request.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("Nội dung chat đang trống.")
    full_prompt = f"{INSTRUCTIONS}\nYêu cầu hiện tại của người dùng:\n{prompt.strip()}"
    try:
        completed = subprocess.run(
            codex_command(request),
            input=full_prompt,
            cwd=request["data_dir"],
            creationflags=PROCESS_FLAGS,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=TURN_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("ChatGPT xử lý quá 4 phút. Hãy thử yêu cầu ngắn hơn.") from exc
    if completed.returncode:
        combined = f"{completed.stderr}\n{completed.stdout}".strip()
        lowered = combined.lower()
        if any(phrase in lowered for phrase in ("not logged in", "codex login", "authentication", "401 unauthorized")):
            raise LoginRequired("Phiên ChatGPT cần đăng nhập lại. Hãy bấm ‘Tiếp tục với ChatGPT’.")
        raise RuntimeError(combined[-1600:] or "Thành phần ChatGPT kết thúc bất thường.")
    return parse_events(completed.stdout)


def main() -> None:
    request: dict[str, Any] = {}
    try:
        if len(sys.argv) > 1:
            request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
        else:
            request = json.load(sys.stdin)
        if request.get("action") == "auth":
            result = auth_status(request.get("codex_candidates", []))
        elif request.get("action") == "models":
            try:
                models = list_models(request["codex_path"])
                result = {"ok": True, "models": models, "catalog": "codex"}
            except (ValueError, RuntimeError, OSError, KeyError, TypeError, json.JSONDecodeError):
                result = {"ok": True, "models": FALLBACK_MODELS, "catalog": "fallback"}
        elif request.get("action") in {"check_update", "download_update"}:
            from runpy import run_path
            updater = run_path(str(Path(__file__).with_name("update_worker.py")))
            result = updater["update"](request)
        else:
            result = run_turn(request)
    except LoginRequired as exc:
        result = {"ok": False, "auth_required": True, "error": str(exc)}
    except (ValueError, RuntimeError, OSError, KeyError, TypeError) as exc:
        result = {"ok": False, "error": str(exc)}
    encoded = (json.dumps(result, ensure_ascii=True) + "\n").encode("ascii")
    result_path = request.get("result_path") if isinstance(request, dict) else None
    if result_path:
        target = Path(result_path).resolve()
        data_dir = Path(request["data_dir"]).resolve()
        if target.parent != data_dir or target.suffix != ".json":
            raise ValueError("Đường dẫn tệp kết quả không hợp lệ.")
        target.write_bytes(encoded)
    else:
        sys.stdout.buffer.write(encoded)


if __name__ == "__main__":
    main()

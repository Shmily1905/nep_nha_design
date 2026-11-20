"""Connect the signed-in Google Antigravity CLI to the SketchUp chat panel."""

import base64
from contextlib import contextmanager
import json
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time

EFFORTS = ("minimal", "low", "medium", "high", "xhigh", "max", "ultra")
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
SERVER_NAME = "nep_nha_design"
TOOLS = {
    "ping_sketchup", "get_model_info", "capture_viewport", "ensure_tag", "upsert_material",
    "draw_geometry", "build_hip_roof", "inspect_drawing", "select_drawing", "edit_drawing",
    "measure_drawing", "set_drawing_axes", "drawing_camera", "prepare_hip_roof_face",
    "inspect_wall", "cut_existing_wall", "edit_selection", "build_model",
}


class GeminiLoginRequired(RuntimeError):
    pass


def find_cli(candidates):
    for candidate in candidates or []:
        found = shutil.which(candidate)
        if found and Path(found).suffix.lower() not in (".bat", ".cmd"):
            return str(Path(found).resolve())
    return None


def get_options(session, category):
    for option in session.get("configOptions") or []:
        if option.get("category") == category or option.get("id") == category:
            values = {}
            for row in option.get("options") or []:
                for value in row.get("options", [row]):
                    if isinstance(value.get("value"), str):
                        values[value["value"]] = value.get("name") or value["value"]
            return option["id"], option.get("currentValue"), values
    return None, None, {}


def permission_choice(params, tools):
    tool = params.get("toolCall") or {}
    metadata = tool.get("_meta") or {}
    raw = tool.get("rawInput") or {}
    # Accept only the tool identifiers constructed by the ACP server for our MCP.
    names = [tool.get("name"), metadata.get("toolName")]
    if isinstance(raw, dict) and raw.get("serverName") == SERVER_NAME:
        names.append(f"{SERVER_NAME}__{raw.get('toolName')}")
    allowed = any(name in {f"{SERVER_NAME}__{item}", f"mcp__{SERVER_NAME}__{item}", f"mcp_{SERVER_NAME}_{item}"}
                  for item in tools for name in names)
    if allowed:
        for choice in params.get("options") or []:
            if choice.get("kind") == "allow_once":
                return {"outcome": "selected", "optionId": choice["optionId"]}
    return {"outcome": "cancelled"}


class Acp:
    def __init__(self, child, timeout, tools):
        self.child = child
        self.deadline = time.monotonic() + timeout
        self.inbox = queue.Queue()
        self.identifier = 0
        self.tools = tools
        self.updates = []
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.child.stdout:
                if len(line) > 12 * 1024 * 1024:
                    self.inbox.put(ValueError("Phản hồi Antigravity quá lớn."))
                    break
                try:
                    self.inbox.put(json.loads(line))
                except json.JSONDecodeError:
                    continue
        finally:
            self.inbox.put(None)

    def send(self, **frame):
        self.child.stdin.write(json.dumps(dict(jsonrpc="2.0", **frame)) + "\n")
        self.child.stdin.flush()

    def call(self, method, params):
        self.identifier += 1
        identifier = self.identifier
        self.send(id=identifier, method=method, params=params)
        while True:
            try:
                frame = self.inbox.get(timeout=max(0, self.deadline - time.monotonic()))
            except queue.Empty as exc:
                raise RuntimeError("Antigravity xử lý quá thời gian.") from exc
            if isinstance(frame, Exception):
                raise frame
            if frame is None:
                raise RuntimeError("Antigravity đã đóng kết nối.")
            if not isinstance(frame, dict):
                continue
            if "method" in frame and "id" in frame:
                if frame["method"] == "session/request_permission":
                    outcome = permission_choice(frame.get("params") or {}, self.tools)
                    self.send(id=frame["id"], result={"outcome": outcome})
                else:
                    self.send(id=frame["id"], error={"code": -32601, "message": "Unsupported client request"})
            elif frame.get("method") == "session/update":
                self.updates.append((frame.get("params") or {}).get("update") or {})
            elif frame.get("id") == identifier:
                if "error" in frame:
                    error = frame["error"]
                    message = str(error.get("message", ""))[:500]
                    auth_error = re.search(r"auth|required to log|sign\s*in|log\s*in|credential", message, re.I)
                    if error.get("code") == -32000 or auth_error:
                        raise GeminiLoginRequired("Hãy đăng nhập Google trong Antigravity CLI bằng lệnh agy acp --login.")
                    raise RuntimeError(message or "Antigravity từ chối yêu cầu.")
                return frame.get("result") or {}


@contextmanager
def open_acp(executable, cwd, timeout, tools=()):
    if not executable or not Path(executable).is_file():
        raise ValueError("Chưa tìm thấy Antigravity CLI. Cài CLI của Google rồi tải lại danh sách Model.")
    cwd.mkdir(parents=True, exist_ok=True)
    with subprocess.Popen(
        [executable, "acp", "--sandbox", "--include-default-customizations=false"], cwd=cwd,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8", creationflags=NO_WINDOW,
    ) as child:
        try:
            client = Acp(child, timeout, tools)
            client.call("initialize", {
                "protocolVersion": 1, "clientCapabilities": {},
                "clientInfo": {"name": "nep_nha_design", "version": "1.15.0"},
            })
            yield client
        finally:
            if child.poll() is None:
                child.kill()


def close_session(client, session_id):
    try:
        client.call("session/close", {"sessionId": session_id})
    except (RuntimeError, OSError):
        pass


def workspace(request):
    return Path(request["data_dir"]).resolve() / "antigravity-workspace"


def gemini_catalog(request):
    executable = find_cli(request.get("agy_candidates"))
    if not executable:
        return {"ok": True, "state": "missing", "models": []}
    try:
        with open_acp(executable, workspace(request), 20) as client:
            session = client.call("session/new", {"cwd": str(workspace(request)), "mcpServers": []})
            try:
                _, current, models = get_options(session, "model")
                _, _, effort = get_options(session, "thought_level")
                catalog = [{"id": f"google:{mid}", "label": name, "efforts": list(effort)
                            if mid == current else []}
                           for mid, name in models.items() if mid.startswith("gemini-")]
                return {"ok": True, "state": "ready", "models": catalog, "agy_path": executable}
            finally:
                close_session(client, session["sessionId"])
    except GeminiLoginRequired as exc:
        return {"ok": False, "state": "signed_out", "agy_path": executable, "error": str(exc)}


def gemini_efforts(request):
    with open_acp(request.get("agy_path"), workspace(request), 20) as client:
        session = client.call("session/new", {"cwd": str(workspace(request)), "mcpServers": []})
        session_id = session["sessionId"]
        try:
            session = choose_model(client, session_id, session, request["model"])
            return {"ok": True, "model": request["model"], "efforts": list(get_options(session, "thought_level")[2])}
        finally:
            close_session(client, session_id)


def choose_model(client, session_id, session, selected):
    mid = selected.removeprefix("google:")
    option, current, models = get_options(session, "model")
    if not mid.startswith("gemini-") or mid not in models:
        raise ValueError("Tài khoản Antigravity hiện chưa có quyền dùng model Gemini đã chọn.")
    if mid != current:
        changed = client.call("session/set_config_option", {"sessionId": session_id, "configId": option, "value": mid})
        if get_options(changed, "model")[1] != mid:
            raise RuntimeError("Antigravity chưa áp dụng model đã chọn.")
        return changed
    return session


def prompt_blocks(text, image_flags):
    blocks = [{"type": "text", "text": text}]
    for filename in image_flags[1::2]:
        path = Path(filename)
        mime = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
        blocks.append({"type": "image", "mimeType": mime[path.suffix.lower()],
                       "data": base64.b64encode(path.read_bytes()).decode("ascii")})
    return blocks


def gemini_turn(request, image_flags, text, timeout):
    tool_use = request.get("action") not in ("auto_exterior", "render", "image_review") and not request.get("draft_skill")
    servers = []
    if tool_use:
        args = [request["mcp_server_path"], "--disable-clear"]
        if request.get("model_guard"):
            args.extend(("--model-guard", request["model_guard"]))
        servers.append({"name": SERVER_NAME, "command": request["python_path"], "args": args, "env": []})
    cwd = workspace(request)
    with open_acp(request.get("agy_path"), cwd, timeout, TOOLS if tool_use else ()) as client:
        params = {"cwd": str(cwd), "mcpServers": servers}
        previous = request.get("thread_id")
        if previous:
            session = client.call("session/resume", dict(params, sessionId=previous))
            session_id = session.get("sessionId") or previous
        else:
            session = client.call("session/new", params)
            session_id = session["sessionId"]
        try:
            mode_id, mode, modes = get_options(session, "mode")
            if mode and mode != "default" and "default" in modes:
                session = client.call("session/set_config_option", {
                    "sessionId": session_id, "configId": mode_id, "value": "default",
                })
            session = choose_model(client, session_id, session, request["model"])
            effort = request.get("effort")
            if effort:
                option, _, levels = get_options(session, "thought_level")
                if effort not in levels:
                    raise ValueError("Mức tư duy này không có trên model Gemini đã chọn.")
                changed = client.call("session/set_config_option", {
                    "sessionId": session_id, "configId": option, "value": effort,
                })
                if get_options(changed, "thought_level")[1] != effort:
                    raise RuntimeError("Antigravity chưa áp dụng mức tư duy đã chọn.")
            client.updates.clear()
            result = client.call("session/prompt", {"sessionId": session_id, "prompt": prompt_blocks(text, image_flags)})
            chunks, images = [], []
            for update in client.updates:
                content = update.get("content")
                if update.get("sessionUpdate") == "agent_message_chunk" and isinstance(content, dict):
                    if content.get("type") == "text":
                        chunks.append(content.get("text", ""))
                if (update.get("sessionUpdate") in ("tool_call", "tool_call_update")
                        and isinstance(content, list)):
                    for part in content:
                        block = part.get("content") or {}
                        if block.get("type") == "image" and (block.get("mimeType") or "").startswith("image/"):
                            images.append({"mime_type": block["mimeType"], "data": block["data"]})
            answer = "".join(chunks).strip()
            if result.get("stopReason") != "end_turn" or not answer:
                raise RuntimeError("Gemini chưa trả lời hoàn chỉnh cho lượt này.")
            return {"ok": True, "text": answer, "thread_id": session_id, "images": images}
        finally:
            close_session(client, session_id)

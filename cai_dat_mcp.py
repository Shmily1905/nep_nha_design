"""Set up the MCP server bundled with the SketchUp extension."""

import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent


def install_and_check(data_dir: Path) -> dict:
    environment = data_dir / "python-mcp"
    python = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    server = ROOT / "mcp_server.py"
    if not python.is_file():
        print("Đang tạo môi trường Python…")
        subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True, timeout=120)

    dependency_check = (
        "from importlib.metadata import version; "
        "from mcp.server.fastmcp import FastMCP, Image; "
        "raise SystemExit(version('mcp') != '1.29.0')"
    )
    ready = subprocess.run(
        [str(python), "-c", dependency_check], capture_output=True, timeout=20
    )
    if ready.returncode:
        print("Đang cài thư viện MCP…")
        pip = subprocess.run([str(python), "-m", "pip", "--version"], timeout=20)
        if pip.returncode:
            subprocess.run([str(python), "-m", "ensurepip"], check=True, timeout=90)
        subprocess.run(
            [str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(ROOT / "requirements.txt")],
            check=True,
            timeout=240,
        )

    print("Đang kiểm tra SketchUp…")
    ping = subprocess.run([str(python), str(server), "--ping"], capture_output=True, timeout=40)
    if ping.returncode:
        raise RuntimeError(ping.stderr.decode("utf-8", errors="replace").strip())
    reply = json.loads(ping.stdout)
    if reply.get("status") != "ok" or reply.get("product") != "nep-nha-design":
        raise RuntimeError("Cổng 9876 đang trả lời từ một cầu nối khác.")
    print(json.dumps(reply, ensure_ascii=True))

    config = {"mcpServers": {"nep-nha-design": {"command": str(python), "args": [str(server)]}}}
    target = data_dir / "cau-hinh-mcp.json"
    staged = target.with_suffix(".tmp")
    staged.write_text(json.dumps(config, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    staged.replace(target)
    return reply


if __name__ == "__main__":
    try:
        install_and_check(Path(sys.argv[1]).resolve())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Lỗi: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

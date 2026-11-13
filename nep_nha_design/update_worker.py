"""Fetch a versioned RBZ from the configured GitHub Releases repository."""

import hashlib
import json
from pathlib import Path
import re
import tempfile
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

from runpy import run_path

_credential = run_path(str(Path(__file__).with_name("github_credential.py")))
delete_token = _credential["delete_token"]
load_token = _credential["load_token"]
save_token = _credential["save_token"]
validate_token = _credential["validate_token"]

LIMIT = 32 * 1024 * 1024
HOSTS = {"api.github.com", "github.com", "release-assets.githubusercontent.com",
         "objects.githubusercontent.com"}
API_VERSION = "2022-11-28"


def trusted(url):
    address = urlsplit(url)
    if address.scheme != "https" or address.netloc not in HOSTS:
        raise ValueError("Địa chỉ tải bản cập nhật không thuộc GitHub Releases.")


class GitHubRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        trusted(newurl)
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if urlsplit(req.full_url).netloc != urlsplit(newurl).netloc:
            redirected.remove_header("Authorization")
        return redirected


def fetch(url, limit, token=None, accept="application/vnd.github+json"):
    trusted(url)
    headers = {
        "Accept": accept,
        "User-Agent": "Nep-Nha-Design-Updater",
        "X-GitHub-Api-Version": API_VERSION,
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(url, headers=headers)
    with build_opener(GitHubRedirect()).open(req, timeout=20) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Dữ liệu cập nhật vượt kích thước cho phép.")
    return data


def normalize_repository(value):
    repository = str(value or "").strip()
    repository = re.sub(r"^https://github\.com/", "", repository, flags=re.IGNORECASE).rstrip("/")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Hãy nhập kho GitHub theo dạng chủ-kho/tên-kho.")
    return repository


def repository_info(repository, token):
    return json.loads(fetch(f"https://api.github.com/repos/{repository}", 2**20, token))


def github_auth(request):
    action = request.get("action")
    repository = normalize_repository(request.get("repository"))
    if action == "github_logout":
        delete_token()
        return {"ok": True, "state": "signed_out", "message": "Đã đăng xuất GitHub."}
    if action == "github_save":
        token = validate_token(request.get("token", ""))
        try:
            info = repository_info(repository, token)
        except HTTPError as exc:
            if exc.code in (401, 403, 404):
                raise ValueError("Mã GitHub không có quyền đọc repository này.") from exc
            raise
        save_token(token)
        return {"ok": True, "state": "ready", "login": info.get("owner", {}).get("login", ""),
                "message": "Đã đăng nhập GitHub và lưu an toàn trên máy."}

    token = load_token()
    if not token:
        return {"ok": True, "state": "signed_out", "message": "Chưa đăng nhập GitHub để đọc bản phát hành riêng tư."}
    try:
        info = repository_info(repository, token)
    except HTTPError as exc:
        if exc.code in (401, 403, 404):
            return {"ok": True, "state": "signed_out",
                    "message": "Phiên GitHub đã hết hạn hoặc chưa được cấp quyền cho repository này."}
        raise
    return {"ok": True, "state": "ready", "login": info.get("owner", {}).get("login", ""),
            "message": "Đã đăng nhập GitHub. Đang tự kiểm tra cập nhật…"}


def update(request):
    repository = normalize_repository(request.get("repository"))
    token = load_token()
    try:
        release = json.loads(fetch(f"https://api.github.com/repos/{repository}/releases/latest", 2**20, token))
    except HTTPError as exc:
        if exc.code == 404:
            message = "Không đọc được bản phát hành. Hãy đăng nhập GitHub và cấp quyền Contents: read cho repository này."
            raise ValueError(message) from exc
        if exc.code in (401, 403):
            raise ValueError("Phiên GitHub đã hết hạn hoặc không đủ quyền đọc bản phát hành.") from exc
        raise
    tag = release.get("tag_name", "")
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)", tag)
    if not match:
        raise ValueError("Tag phát hành phải có dạng vX.Y.Z.")
    version = match[1]
    latest = tuple(map(int, version.split(".")))
    installed = tuple(map(int, request["version"].split(".")))
    if latest < installed:
        return {"ok": True, "message": f"Bản đang chạy mới hơn bản {version} trên GitHub."}
    filename = f"Nep-Nha-Design-Tro-Ly-ChatGPT-v{version}.rbz"
    asset = next((item for item in release.get("assets", []) if item["name"] == filename), {})
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        raise ValueError("Bản phát hành thiếu gói RBZ hoặc mã SHA-256.")
    if latest == installed:
        return {"ok": True, "message": f"Bạn đang dùng bản mới nhất ({version})."}
    if request["action"] == "check_update":
        return {"ok": True, "available": True, "version": version, "message": f"Có bản {version}."}
    if request.get("expected_version") != version:
        raise ValueError("Bản phát hành vừa thay đổi. Hãy kiểm tra lại.")
    asset_url = asset.get("url", "")
    data = fetch(asset_url, LIMIT, token, "application/octet-stream")
    if hashlib.sha256(data).hexdigest() != digest[7:]:
        raise ValueError("Mã SHA-256 không khớp. Đã dừng cài đặt.")
    with tempfile.NamedTemporaryFile(suffix=".rbz", delete=False) as file:
        path = Path(file.name)
        file.write(data)
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            for entry in entries:
                name = entry.filename
                parts = name.rstrip("/").split("/")
                if ("\\" in name or ":" in name or any(p in {"", ".", ".."} for p in parts)
                        or not (name == "nep_nha_design.rb" or name.startswith("nep_nha_design/"))
                        or (entry.external_attr >> 16) & 0o170000 == 0o120000):
                    raise ValueError("Gói cập nhật chứa đường dẫn không hợp lệ.")
            if (sum(e.file_size for e in entries) > LIMIT
                    or len({e.filename.casefold() for e in entries}) != len(entries)
                    or not {"nep_nha_design.rb", "nep_nha_design/main.rb"} <= set(archive.namelist())):
                raise ValueError("Cấu trúc gói cập nhật không hợp lệ.")
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        path.unlink(missing_ok=True)
        raise ValueError("Không thể xác minh cấu trúc gói RBZ.") from exc
    return {"ok": True, "path": str(path)}

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

LIMIT = 32 * 1024 * 1024
HOSTS = {"api.github.com", "github.com", "release-assets.githubusercontent.com",
         "objects.githubusercontent.com"}


def trusted(url):
    address = urlsplit(url)
    if address.scheme != "https" or address.netloc not in HOSTS:
        raise ValueError("Địa chỉ tải bản cập nhật không thuộc GitHub Releases.")


class GitHubRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        trusted(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url, limit):
    trusted(url)
    req = Request(url, headers={"User-Agent": "Nep-Nha-Design-Updater"})
    with build_opener(GitHubRedirect()).open(req, timeout=20) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Dữ liệu cập nhật vượt kích thước cho phép.")
    return data


def update(request):
    repository = request.get("repository", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Hãy nhập kho GitHub công khai theo dạng chủ-kho/tên-kho.")
    try:
        release = json.loads(fetch(f"https://api.github.com/repos/{repository}/releases/latest", 2**20))
    except HTTPError as exc:
        if exc.code == 404:
            raise ValueError("Kho GitHub chưa có bản phát hành công khai.") from exc
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
    data = fetch(f"https://github.com/{repository}/releases/download/{tag}/{filename}", LIMIT)
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

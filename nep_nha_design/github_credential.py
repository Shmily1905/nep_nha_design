"""Store the GitHub updater token in the operating system credential vault."""

from __future__ import annotations

import ctypes
from ctypes import wintypes
import re
import subprocess
import sys

SERVICE = "NepNhaDesign/GitHubUpdater"
ACCOUNT = "NepNhaDesign"


def validate_token(token: str) -> str:
    token = token.strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{20,255}", token):
        raise ValueError("Mã đăng nhập GitHub không đúng định dạng.")
    return token


class _CredentialW(ctypes.Structure):
    _fields_ = [
        ("Flags", wintypes.DWORD),
        ("Type", wintypes.DWORD),
        ("TargetName", wintypes.LPWSTR),
        ("Comment", wintypes.LPWSTR),
        ("LastWritten", wintypes.FILETIME),
        ("CredentialBlobSize", wintypes.DWORD),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)),
        ("Persist", wintypes.DWORD),
        ("AttributeCount", wintypes.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", wintypes.LPWSTR),
        ("UserName", wintypes.LPWSTR),
    ]


def _windows_api():
    api = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
    api.CredWriteW.argtypes = [ctypes.POINTER(_CredentialW), wintypes.DWORD]
    api.CredWriteW.restype = wintypes.BOOL
    api.CredReadW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.POINTER(ctypes.POINTER(_CredentialW)),
    ]
    api.CredReadW.restype = wintypes.BOOL
    api.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
    api.CredDeleteW.restype = wintypes.BOOL
    api.CredFree.argtypes = [ctypes.c_void_p]
    return api


def _windows_error(message: str) -> OSError:
    code = ctypes.get_last_error()
    return OSError(code, f"{message}: {ctypes.FormatError(code).strip()}")


def _windows_save(token: str) -> None:
    api = _windows_api()
    raw = token.encode("utf-8")
    blob = ctypes.create_string_buffer(raw)
    credential = _CredentialW()
    credential.Type = 1  # CRED_TYPE_GENERIC
    credential.TargetName = SERVICE
    credential.CredentialBlobSize = len(raw)
    credential.CredentialBlob = ctypes.cast(blob, ctypes.POINTER(ctypes.c_ubyte))
    credential.Persist = 2  # CRED_PERSIST_LOCAL_MACHINE, scoped to this Windows user
    credential.UserName = ACCOUNT
    if not api.CredWriteW(ctypes.byref(credential), 0):
        raise _windows_error("Không lưu được thông tin đăng nhập GitHub")


def _windows_load() -> str | None:
    api = _windows_api()
    pointer = ctypes.POINTER(_CredentialW)()
    if not api.CredReadW(SERVICE, 1, 0, ctypes.byref(pointer)):
        if ctypes.get_last_error() == 1168:  # ERROR_NOT_FOUND
            return None
        raise _windows_error("Không đọc được thông tin đăng nhập GitHub")
    try:
        credential = pointer.contents
        raw = ctypes.string_at(credential.CredentialBlob, credential.CredentialBlobSize)
        return validate_token(raw.decode("utf-8"))
    finally:
        api.CredFree(pointer)


def _windows_delete() -> None:
    api = _windows_api()
    if not api.CredDeleteW(SERVICE, 1, 0) and ctypes.get_last_error() != 1168:
        raise _windows_error("Không xóa được thông tin đăng nhập GitHub")


def _mac_run(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/usr/bin/security", *arguments], stdin=subprocess.DEVNULL,
        capture_output=True, text=True, encoding="utf-8", errors="replace",
        timeout=15, check=False,
    )


def save_token(token: str) -> None:
    token = validate_token(token)
    if sys.platform == "win32":
        _windows_save(token)
        return
    if sys.platform == "darwin":
        result = _mac_run(["add-generic-password", "-U", "-a", ACCOUNT,
                           "-s", SERVICE, "-w", token])
        if result.returncode:
            raise OSError("Không lưu được thông tin đăng nhập vào macOS Keychain.")
        return
    raise OSError("Hệ điều hành này chưa hỗ trợ kho thông tin đăng nhập an toàn.")


def load_token() -> str | None:
    if sys.platform == "win32":
        return _windows_load()
    if sys.platform == "darwin":
        result = _mac_run(["find-generic-password", "-a", ACCOUNT, "-s", SERVICE, "-w"])
        if result.returncode == 44:
            return None
        if result.returncode:
            raise OSError("Không đọc được thông tin đăng nhập từ macOS Keychain.")
        return validate_token(result.stdout)
    return None


def delete_token() -> None:
    if sys.platform == "win32":
        _windows_delete()
    elif sys.platform == "darwin":
        result = _mac_run(["delete-generic-password", "-a", ACCOUNT, "-s", SERVICE])
        if result.returncode not in (0, 44):
            raise OSError("Không xóa được thông tin đăng nhập khỏi macOS Keychain.")

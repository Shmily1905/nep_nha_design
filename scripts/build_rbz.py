"""Build the versioned SketchUp extension from the repository sources."""

import argparse
import ast
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "nep_nha_design"
PACKAGE_FILES = [
    "HUONG_DAN.txt",
    "build_model.rb",
    "cai_dat_mcp.py",
    "chat.html",
    "chat_worker.py",
    "github_credential.py",
    "logo.png",
    "main.rb",
    "mcp_server.py",
    "requirements.txt",
    "su_mcp_bridge.rb",
    "update_worker.py",
]
FILES = [
    "nep_nha_design.rb",
    *(f"nep_nha_design/{name}" for name in PACKAGE_FILES),
    *(path.relative_to(ROOT).as_posix() for path in sorted((PACKAGE / "design-skills").glob("*.md"))),
]
VERSIONS = {
    "nep_nha_design.rb": r"extension\.version = '([^']+)'",
    "nep_nha_design/main.rb": r"VERSION = '([^']+)'",
    "nep_nha_design/su_mcp_bridge.rb": r"VERSION = '([^']+)'",
    "nep_nha_design/chat_worker.py": r'"version": "([^"]+)"',
    "nep_nha_design/chat.html": r'aria-label="Phiên bản ([\d.]+)"',
    "nep_nha_design/HUONG_DAN.txt": r"Phiên bản ([\d.]+)",
}


def build(output_dir: Path, expected_tag: str | None) -> Path:
    version = None
    for filename, pattern in VERSIONS.items():
        match = re.search(pattern, (ROOT / filename).read_text(encoding="utf-8"))
        if not match or not re.fullmatch(r"\d+\.\d+\.\d+", match[1]):
            raise SystemExit(f"Cannot read version in {filename}")
        if version is not None and match[1] != version:
            raise SystemExit(f"Version mismatch in {filename}: expected {version}, got {match[1]}")
        version = match[1]
    if expected_tag and expected_tag != f"v{version}":
        raise SystemExit(f"Expected tag v{version}, got {expected_tag}")

    for source in PACKAGE.glob("*.py"):
        ast.parse(source.read_text(encoding="utf-8"), filename=str(source))

    missing = [filename for filename in FILES if not (ROOT / filename).is_file()]
    if missing:
        raise SystemExit(f"Missing package files: {', '.join(missing)}")

    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"Nep-Nha-Design-Tro-Ly-ChatGPT-v{version}.rbz"
    with ZipFile(output, "w") as archive:
        for filename in FILES:
            entry = ZipInfo(filename)
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, (ROOT / filename).read_bytes(), compress_type=ZIP_DEFLATED)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--tag", help="Required version tag when building a GitHub release.")
    arguments = parser.parse_args()
    print(build(arguments.output_dir, arguments.tag))

#!/usr/bin/env python3
"""Build cross-platform ForeverSuite + ForeverSuite_GJBridge ZIP release and Windows 1-Click .exe installer."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import zipfile

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from build_win_exe import (  # noqa: E402
    _resolve_writable_dist_dir,
    _write_addon_folder_to_zip,
    build_windows_installer_exe,
)

DEFAULT_PATCH_URL = "https://raw.githubusercontent.com/ssacho3-blip/WoW-ForeverSuite/main/dist/ForeverSuite-v{version}.zip"
STALE_RELEASE_ZIP_RE = re.compile(r"^ForeverSuite-v\d+\.\d+\.\d+\.zip$")


def _write_json_atomic(path: pathlib.Path, payload: dict) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out_f:
            out_f.write(text)
        os.replace(tmp_path, path)
    finally:
        tmp_path.unlink(missing_ok=True)


def _sync_manifest_patch_metadata(repo_root: pathlib.Path, version: str, patch_sha256: str) -> None:
    manifest_path = repo_root / "pinned_upstream.json"
    if not manifest_path.is_file() or not os.access(manifest_path, os.W_OK):
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["patch_zip_url"] = DEFAULT_PATCH_URL.format(version=version)
    manifest["patch_zip_sha256"] = patch_sha256
    _write_json_atomic(manifest_path, manifest)


def _cleanup_stale_release_zips(dist_dir: pathlib.Path, keep_name: str) -> list[str]:
    removed: list[str] = []
    dist_real = os.path.realpath(str(dist_dir)).rstrip(os.sep) + os.sep
    for item in sorted(dist_dir.iterdir()):
        if item.name == keep_name or not STALE_RELEASE_ZIP_RE.fullmatch(item.name):
            continue
        if item.is_symlink() or not item.is_file():
            continue
        if not os.path.realpath(str(item)).startswith(dist_real):
            continue
        item.unlink()
        removed.append(item.name)
    return removed


def build_release_zip(
    repo_root: pathlib.Path, version: str = "0.3.0", out_dir: pathlib.Path | None = None
) -> pathlib.Path:
    addon_folders = ("ForeverSuite", "ForeverSuite_GJBridge")
    dist_dir = _resolve_writable_dist_dir(repo_root, out_dir)

    final_zip = dist_dir / f"ForeverSuite-v{version}.zip"
    staging_zip = dist_dir / f".ForeverSuite-v{version}.staging.zip"

    with zipfile.ZipFile(staging_zip, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for folder in addon_folders:
            _write_addon_folder_to_zip(zf, repo_root, folder)

    os.replace(staging_zip, final_zip)
    if out_dir is None:
        patch_sha = hashlib.sha256(final_zip.read_bytes()).hexdigest().lower()
        _sync_manifest_patch_metadata(repo_root, version, patch_sha)
    exe_out = build_windows_installer_exe(repo_root, out_dir=dist_dir)
    if out_dir is None and final_zip.is_file() and final_zip.stat().st_size > 0 and exe_out.is_file():
        _cleanup_stale_release_zips(dist_dir, final_zip.name)
    return final_zip


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    out = build_release_zip(root)
    print(f"[OK] Built cross-platform package & Windows .exe installer in: {out.parent}")

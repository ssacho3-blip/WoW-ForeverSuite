#!/usr/bin/env python3
"""Build cross-platform ForeverSuite + ForeverSuite_GJBridge ZIP release and Windows 1-Click .exe installer."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys
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


def _sync_manifest_patch_metadata(repo_root: pathlib.Path, version: str, patch_sha256: str) -> None:
    manifest_path = repo_root / "pinned_upstream.json"
    if not manifest_path.is_file() or not os.access(manifest_path, os.W_OK):
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["patch_zip_url"] = DEFAULT_PATCH_URL.format(version=version)
    manifest["patch_zip_sha256"] = patch_sha256
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def build_release_zip(
    repo_root: pathlib.Path, version: str = "0.2.0", out_dir: pathlib.Path | None = None
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
    build_windows_installer_exe(repo_root, out_dir=dist_dir)
    return final_zip


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    out = build_release_zip(root)
    print(f"[OK] Built cross-platform package & Windows .exe installer in: {out.parent}")

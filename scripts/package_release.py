#!/usr/bin/env python3
"""Build cross-platform ForeverSuite + ForeverSuite_GJBridge ZIP release and Windows 1-Click .exe installer."""

from __future__ import annotations

import os
import pathlib
import sys
import zipfile

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from build_win_exe import _write_addon_folder_to_zip, build_windows_installer_exe  # noqa: E402


def build_release_zip(repo_root: pathlib.Path, version: str = "0.2.0") -> pathlib.Path:
    addon_folders = ("ForeverSuite", "ForeverSuite_GJBridge")
    dist_dir = repo_root / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)

    final_zip = dist_dir / f"ForeverSuite-v{version}.zip"
    staging_zip = dist_dir / f".ForeverSuite-v{version}.staging.zip"

    with zipfile.ZipFile(staging_zip, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for folder in addon_folders:
            _write_addon_folder_to_zip(zf, repo_root, folder)

    os.replace(staging_zip, final_zip)
    build_windows_installer_exe(repo_root)
    return final_zip


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    out = build_release_zip(root)
    print(f"[OK] Built cross-platform package & Windows .exe installer in: {out.parent}")

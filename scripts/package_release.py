#!/usr/bin/env python3
"""Build a cross-platform (Windows + macOS) ForeverSuite ZIP release atomically."""

from __future__ import annotations

import os
import pathlib
import zipfile


def build_release_zip(repo_root: pathlib.Path, version: str = "0.1.0") -> pathlib.Path:
    src_dir = repo_root / "ForeverSuite"
    toc_path = src_dir / "ForeverSuite.toc"
    if not toc_path.is_file():
        raise FileNotFoundError(f"Missing TOC file: {toc_path}")

    dist_dir = repo_root / "dist"
    dist_dir.mkdir(parents=True, exist_ok=True)

    final_zip = dist_dir / f"ForeverSuite-v{version}.zip"
    staging_zip = dist_dir / f".ForeverSuite-v{version}.staging.zip"

    with zipfile.ZipFile(staging_zip, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for file_path in sorted(src_dir.rglob("*")):
            if file_path.is_dir() or file_path.name.startswith("."):
                continue
            rel_posix = file_path.relative_to(repo_root).as_posix()
            raw = file_path.read_bytes()
            # Enforce LF line endings and UTF-8 without BOM for Win/Mac Lua parity
            if raw.startswith(b"\xef\xbb\xbf"):
                raise ValueError(f"UTF-8 BOM detected in {rel_posix}")
            normalized = raw.replace(b"\r\n", b"\n")
            zf.writestr(rel_posix, normalized)

    os.replace(staging_zip, final_zip)
    return final_zip


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    out = build_release_zip(root)
    print(f"[OK] Built cross-platform package: {out}")

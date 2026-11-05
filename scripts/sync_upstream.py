#!/usr/bin/env python3
"""Phase 5 Upstream Sync Tool: Verify & unpack a new GodJohnson ZIP, update pinned_upstream.json, and run checks."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import zipfile


def _count_files_in_dir(item: pathlib.Path) -> int:
    total = 0
    for p in item.rglob("*"):
        if p.is_file():
            total += 1
    return total


def _scan_single_folder(folders: dict[str, dict], item: pathlib.Path) -> None:
    if not item.is_dir() or item.name.startswith("."):
        return
    toc_file = item / f"{item.name}.toc"
    toc_sha256 = hashlib.sha256(toc_file.read_bytes()).hexdigest()
    folders[item.name] = {
        "toc_sha256": toc_sha256,
        "file_count": _count_files_in_dir(item),
    }


def _scan_extracted_folders(staging_dir: pathlib.Path) -> dict[str, dict]:
    folders: dict[str, dict] = {}
    for item in sorted(staging_dir.iterdir()):
        _scan_single_folder(folders, item)
    return folders


def _extract_and_swap_upstream(zip_path: pathlib.Path, extract_dest: pathlib.Path) -> dict[str, dict]:
    parent_dir = extract_dest.parent
    parent_dir.mkdir(parents=True, exist_ok=True)
    staging_dir = pathlib.Path(tempfile.mkdtemp(prefix=".gj_sync_stage_", dir=str(parent_dir)))
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(staging_dir)
        folders = _scan_extracted_folders(staging_dir)
        if extract_dest.exists():
            shutil.rmtree(extract_dest)
        os.replace(staging_dir, extract_dest)
        return folders
    finally:
        if staging_dir.exists():
            shutil.rmtree(staging_dir, ignore_errors=True)


def sync_upstream_zip(zip_path: pathlib.Path, extract_dest: pathlib.Path, repo_root: pathlib.Path) -> dict:
    zip_sha256 = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    zip_size = zip_path.stat().st_size
    folders = _extract_and_swap_upstream(zip_path, extract_dest)

    manifest_path = repo_root / "pinned_upstream.json"
    existing = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.is_file() else {}

    manifest = {
        "upstream_name": "GodJohnson Integrated Addon",
        "curseforge_project_id": existing.get("curseforge_project_id", 1707376),
        "version": existing.get("version", "5.0.132"),
        "release_revision": existing.get("release_revision", 484),
        "release_date": existing.get("release_date", "2026-11-04"),
        "target_client_build": existing.get("target_client_build", "1.60.1.70790"),
        "file_id": existing.get("file_id", 9432165),
        "file_name": zip_path.name,
        "download_url": existing.get(
            "download_url",
            "https://mediafilez.forgecdn.net/files/9432/165/GodJohnson-5.0.132.zip",
        ),
        "zip_sha256": zip_sha256,
        "zip_size_bytes": zip_size,
        "folder_count": len(folders),
        "folders": folders,
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    zpath = pathlib.Path(sys.argv[1]).resolve()
    edest = pathlib.Path(sys.argv[2]).resolve() if len(sys.argv) >= 3 else (root.parent / "GodJohnson_5.0.132")
    res = sync_upstream_zip(zpath, edest, root)
    print(f"[OK] Synced upstream {res['file_name']} ({res['folder_count']} folders, sha256={res['zip_sha256'][:16]}...)")

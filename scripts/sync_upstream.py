#!/usr/bin/env python3
"""Phase 5 Upstream Sync Tool: Fetch or verify a new GodJohnson ZIP, update pinned_upstream.json & Bridge.lua."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

CFWIDGET_API_TEMPLATE = "https://api.cfwidget.com/{project_id}"
FORGECDN_URL_TEMPLATE = "https://mediafilez.forgecdn.net/files/{high}/{low}/{file_name}"
ALLOWED_DOWNLOAD_HOSTS = frozenset(
    {
        "mediafilez.forgecdn.net",
        "edge.forgecdn.net",
        "www.curseforge.com",
        "api.cfwidget.com",
        "raw.githubusercontent.com",
        "github.com",
        "objects.githubusercontent.com",
    }
)
MAX_ZIP_UNCOMPRESSED_BYTES = 1_073_741_824
MAX_REDIRECT_HOPS = 5


def sanitize_zip_filename(file_name: str) -> str:
    clean_name = pathlib.PurePath(file_name.replace("\\", "/")).name
    if clean_name != file_name or not re.fullmatch(r"[\w.\-]+\.zip", clean_name):
        raise ValueError(f"Untrusted archive filename rejected: {file_name!r}")
    return clean_name


def validate_https_download_url(download_url: str) -> str:
    parsed = urllib.parse.urlparse(download_url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_DOWNLOAD_HOSTS:
        raise ValueError(f"Untrusted download URL rejected: {download_url!r}")
    return download_url


class SafeHTTPSRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Validate every redirect hop target scheme and host BEFORE following."""

    def __init__(self, max_hops: int = MAX_REDIRECT_HOPS) -> None:
        super().__init__()
        self.max_hops = max_hops
        self.hop_count = 0

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self.hop_count += 1
        if self.hop_count > self.max_hops:
            raise ValueError(f"Redirect hop limit exceeded ({self.max_hops})")
        target_url = urllib.parse.urljoin(req.full_url, newurl)
        validate_https_download_url(target_url)
        return super().redirect_request(req, fp, code, msg, headers, target_url)


def open_safe_https_url(url: str, timeout: int = 120):
    safe_url = validate_https_download_url(url)
    opener = urllib.request.build_opener(SafeHTTPSRedirectHandler())
    req = urllib.request.Request(safe_url, headers={"User-Agent": "ForeverSuiteSync/1.0"})
    return opener.open(req, timeout=timeout)


def _is_unsafe_zip_member_path(member_name: str) -> bool:
    norm = member_name.replace("\\", "/")
    parts = pathlib.PurePosixPath(norm).parts
    return norm.startswith("/") or ":" in norm or ".." in parts


def _validate_single_zip_info(info: zipfile.ZipInfo) -> int:
    mode = (info.external_attr >> 16) & 0o170000
    if _is_unsafe_zip_member_path(info.filename) or mode == 0o120000 or info.file_size > MAX_ZIP_UNCOMPRESSED_BYTES:
        raise ValueError(f"Unsafe zip entry rejected: {info.filename!r}")
    return int(info.file_size)


def validate_zip_archive_safety(zf: zipfile.ZipFile) -> None:
    total_uncompressed = 0
    for info in zf.infolist():
        total_uncompressed += _validate_single_zip_info(info)
        if total_uncompressed > MAX_ZIP_UNCOMPRESSED_BYTES:
            raise ValueError("Zip archive exceeds maximum uncompressed size limit")


def _is_within_root(target_real: str, root_real: str) -> bool:
    return target_real == root_real or target_real.startswith(root_real + os.sep)


def _assert_safe_target_realpath(root_real: str, target_path: pathlib.Path, allow_root: bool = False) -> None:
    target_real = os.path.realpath(str(target_path))
    ok = _is_within_root(target_real, root_real) if allow_root else target_real.startswith(root_real + os.sep)
    if not ok or target_path.is_symlink():
        raise ValueError(f"Zip extraction path escape or symlink blocked: {target_path}")


def _extract_single_zip_member(zf: zipfile.ZipFile, info: zipfile.ZipInfo, dest_dir: pathlib.Path, root_real: str) -> None:
    rel_clean = info.filename.replace("\\", "/").rstrip("/")
    if not rel_clean:
        return
    target = dest_dir / rel_clean
    _assert_safe_target_realpath(root_real, target.parent, allow_root=True)
    if info.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        _assert_safe_target_realpath(root_real, target, allow_root=False)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    _assert_safe_target_realpath(root_real, target.parent, allow_root=True)
    _assert_safe_target_realpath(root_real, target, allow_root=False)
    with zf.open(info, "r") as src_f, open(target, "wb") as dst_f:
        shutil.copyfileobj(src_f, dst_f)


def extract_zip_safely(zf: zipfile.ZipFile, dest_dir: pathlib.Path) -> None:
    validate_zip_archive_safety(zf)
    if dest_dir.is_symlink():
        raise ValueError("Staging destination must not be a symlink")
    root_real = os.path.realpath(str(dest_dir)).rstrip(os.sep)
    for info in zf.infolist():
        _extract_single_zip_member(zf, info, dest_dir, root_real)


def _count_files_in_dir(item: pathlib.Path) -> int:
    total = 0
    for p in item.rglob("*"):
        if p.is_file():
            total += 1
    return total


def _is_valid_addon_dir(item: pathlib.Path) -> bool:
    if not item.is_dir() or not re.fullmatch(r"GodJohnson[A-Za-z0-9_]*", item.name):
        return False
    return (item / f"{item.name}.toc").is_file()


def _scan_single_folder(folders: dict[str, dict], item: pathlib.Path) -> None:
    if not _is_valid_addon_dir(item):
        return
    toc_file = item / f"{item.name}.toc"
    toc_sha256 = hashlib.sha256(toc_file.read_bytes()).hexdigest()
    folders[item.name] = {
        "toc_sha256": toc_sha256,
        "file_count": _count_files_in_dir(item),
    }


def _has_direct_addon_dir(directory: pathlib.Path) -> bool:
    for item in directory.iterdir():
        if _is_valid_addon_dir(item):
            return True
    return False


def _unwrap_single_wrapper_dir(staging_dir: pathlib.Path) -> None:
    if _has_direct_addon_dir(staging_dir):
        return
    top_dirs = [d for d in sorted(staging_dir.iterdir()) if d.is_dir() and not d.is_symlink()]
    wrapper_candidates = [d for d in top_dirs if _has_direct_addon_dir(d)]
    if len(wrapper_candidates) > 1:
        raise ValueError("Ambiguous multiple top-level wrapper directories in upstream archive")
    if len(wrapper_candidates) != 1:
        return
    tmp_wrap = staging_dir / f".__unwrap_{os.getpid()}__"
    os.replace(wrapper_candidates[0], tmp_wrap)
    try:
        for child in sorted(tmp_wrap.iterdir()):
            os.replace(child, staging_dir / child.name)
    finally:
        shutil.rmtree(tmp_wrap, ignore_errors=True)


def _scan_extracted_folders(staging_dir: pathlib.Path) -> dict[str, dict]:
    _unwrap_single_wrapper_dir(staging_dir)
    folders: dict[str, dict] = {}
    for item in sorted(staging_dir.iterdir()):
        _scan_single_folder(folders, item)
    if not folders:
        raise ValueError("Extracted archive contains no valid GodJohnson addon folders")
    return folders


def _restore_text_snapshot(path: pathlib.Path, snapshot: str | None) -> None:
    if snapshot is None:
        path.unlink(missing_ok=True)
    else:
        _write_text_atomic(path, snapshot)


def _rollback_directory_swap(
    extract_dest: pathlib.Path, backup_dir: pathlib.Path | None, had_existing: bool
) -> None:
    if extract_dest.exists():
        shutil.rmtree(extract_dest, ignore_errors=True)
    if had_existing and backup_dir is not None and backup_dir.exists():
        os.replace(backup_dir, extract_dest)


SAFE_VERSION_RE = re.compile(r"^[0-9]+(?:\.[0-9A-Za-z_-]+)+$")


def validate_version_string(version: str) -> str:
    clean = str(version).strip()
    if not SAFE_VERSION_RE.fullmatch(clean):
        raise ValueError(f"Unsafe or malformed upstream version string: {version!r}")
    return clean


def _prepare_bridge_update(bridge_lua: pathlib.Path, version: str) -> tuple[str | None, str | None]:
    safe_ver = validate_version_string(version)
    if not bridge_lua.is_file():
        return None, None
    old_src = bridge_lua.read_text(encoding="utf-8")
    new_src = re.sub(r'ns\.UPSTREAM_PIN\s*=\s*"[^"]+"', lambda _m: f'ns.UPSTREAM_PIN = "{safe_ver}"', old_src, count=1)
    return old_src, new_src


def _commit_sync_transaction(
    staging_dir: pathlib.Path,
    extract_dest: pathlib.Path,
    manifest_path: pathlib.Path,
    manifest_json: str,
    bridge_lua: pathlib.Path,
    version: str,
) -> None:
    old_manifest = manifest_path.read_text(encoding="utf-8") if manifest_path.is_file() else None
    old_bridge, new_bridge = _prepare_bridge_update(bridge_lua, version)
    had_existing = extract_dest.exists()
    backup_dir: pathlib.Path | None = None
    if had_existing:
        backup_dir = extract_dest.parent / f".gj_sync_bak_{staging_dir.name.lstrip('.')}"
        if backup_dir.exists():
            shutil.rmtree(backup_dir, ignore_errors=True)
        os.replace(extract_dest, backup_dir)
    try:
        os.replace(staging_dir, extract_dest)
        _write_text_atomic(manifest_path, manifest_json)
        if new_bridge is not None and new_bridge != old_bridge:
            _write_text_atomic(bridge_lua, new_bridge)
    except BaseException:
        _rollback_directory_swap(extract_dest, backup_dir, had_existing)
        _restore_text_snapshot(manifest_path, old_manifest)
        if old_bridge is not None:
            _restore_text_snapshot(bridge_lua, old_bridge)
        raise
    if backup_dir is not None and backup_dir.exists():
        shutil.rmtree(backup_dir, ignore_errors=True)


def _parse_version_from_zip_or_toc(extract_dest: pathlib.Path, zip_name: str, fallback: str) -> str:
    m = re.search(r"GodJohnson-(\d+\.\d+\.\d+)\.zip", zip_name)
    if m:
        return m.group(1)
    toc_path = extract_dest / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc"
    if toc_path.is_file():
        m_toc = re.search(r"^##\s*Version:\s*(\S+)", toc_path.read_text(encoding="utf-8"), re.MULTILINE)
        if m_toc:
            return m_toc.group(1)
    return fallback


def _parse_release_revision(extract_dest: pathlib.Path, fallback: int) -> int:
    core_lua = extract_dest / "GodJohnsonGoldBorder" / "CompanionCore.lua"
    if not core_lua.is_file():
        return fallback
    m = re.search(r"releaseRevision\s*=\s*(\d+)", core_lua.read_text(encoding="utf-8", errors="replace"))
    return int(m.group(1)) if m else fallback


def build_forgecdn_url(file_id: int, file_name: str) -> str:
    safe_name = sanitize_zip_filename(file_name)
    return FORGECDN_URL_TEMPLATE.format(high=file_id // 1000, low=file_id % 1000, file_name=safe_name)


def _append_valid_cfwidget_entry(candidates: list[dict], entry: object) -> None:
    if isinstance(entry, dict) and entry.get("id"):
        candidates.append(entry)


def select_latest_cfwidget_file(payload: dict) -> dict:
    candidates: list[dict] = []
    _append_valid_cfwidget_entry(candidates, payload.get("download"))
    for item in payload.get("files", []):
        _append_valid_cfwidget_entry(candidates, item)
    if not candidates:
        raise RuntimeError("CFWidget payload contains no release files")
    return max(candidates, key=lambda row: int(row["id"]))


def _download_file_atomic(download_url: str, zip_path: pathlib.Path, expected_size: int) -> None:
    tmp_zip = zip_path.parent / f".{zip_path.name}.{os.getpid()}.part"
    try:
        with open_safe_https_url(download_url, timeout=120) as dl_resp, open(tmp_zip, "wb") as out_f:
            validate_https_download_url(dl_resp.geturl())
            shutil.copyfileobj(dl_resp, out_f)
        actual_size = tmp_zip.stat().st_size
        if expected_size > 0 and actual_size != expected_size:
            raise RuntimeError(f"Downloaded size mismatch: expected={expected_size} actual={actual_size}")
        os.replace(tmp_zip, zip_path)
    finally:
        tmp_zip.unlink(missing_ok=True)


def _is_verified_cached_zip(zip_path: pathlib.Path, expected_sha256: str | None) -> bool:
    if not expected_sha256 or not zip_path.is_file():
        return False
    actual = hashlib.sha256(zip_path.read_bytes()).hexdigest().lower()
    return actual == expected_sha256.lower()


def _resolve_private_cache_dir(repo_root: pathlib.Path, cache_dir: pathlib.Path | None) -> pathlib.Path:
    target_dir = cache_dir if cache_dir is not None else (repo_root / ".upstream_cache")
    target_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(target_dir, 0o700)
    return target_dir


def _trusted_sha_for_file(trusted_pin: dict | None, file_id: int) -> str | None:
    if not trusted_pin or int(trusted_pin.get("file_id", 0)) != file_id:
        return None
    sha = trusted_pin.get("zip_sha256")
    return str(sha) if sha else None


def fetch_latest_curseforge_zip(
    project_id: int = 1707376,
    cache_dir: pathlib.Path | None = None,
    trusted_pin: dict | None = None,
) -> tuple[pathlib.Path, dict]:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    target_dir = _resolve_private_cache_dir(repo_root, cache_dir)
    api_url = CFWIDGET_API_TEMPLATE.format(project_id=project_id)
    with open_safe_https_url(api_url, timeout=20) as resp:
        latest = select_latest_cfwidget_file(json.load(resp))
    file_id = int(latest["id"])
    file_name = sanitize_zip_filename(str(latest["name"]))
    download_url = build_forgecdn_url(file_id, file_name)
    zip_path = target_dir / file_name
    if not _is_verified_cached_zip(zip_path, _trusted_sha_for_file(trusted_pin, file_id)):
        _download_file_atomic(download_url, zip_path, int(latest.get("filesize", 0)))
    uploaded_at = str(latest.get("uploaded_at", "2026-11-09"))
    return zip_path, {"file_id": file_id, "download_url": download_url, "release_date": uploaded_at[:10]}


def _write_text_atomic(path: pathlib.Path, content: str) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = pathlib.Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out_f:
            out_f.write(content)
        os.replace(tmp_path, path)
    finally:
        tmp_path.unlink(missing_ok=True)


def _write_json_atomic(path: pathlib.Path, payload: dict) -> None:
    _write_text_atomic(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def resolve_default_extract_dir(repo_root: pathlib.Path) -> pathlib.Path:
    candidates = (
        repo_root.parent / "GodJohnson_5.0.132",
        pathlib.Path("/Users/choyoungseo/workspace/GodJohnson_5.0.132"),
    )
    for cand in candidates:
        if (cand / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc").is_file():
            return cand
    return candidates[0]


def verify_extracted_dir(repo_root: pathlib.Path, target_dir: pathlib.Path) -> int:
    manifest = _load_existing_manifest(repo_root / "pinned_upstream.json")
    folders = manifest.get("folders") or {}
    if not folders:
        raise ValueError("pinned_upstream.json contains no folder hashes")
    for folder_name, meta in folders.items():
        toc_file = target_dir / folder_name / f"{folder_name}.toc"
        if not toc_file.is_file():
            raise ValueError(f"Missing upstream TOC: {toc_file}")
        actual_sha = hashlib.sha256(toc_file.read_bytes()).hexdigest()
        if actual_sha != meta["toc_sha256"]:
            raise ValueError(f"Upstream TOC SHA-256 mismatch [{folder_name}]: {actual_sha} != {meta['toc_sha256']}")
    return len(folders)


def _load_existing_manifest(manifest_path: pathlib.Path) -> dict:
    if manifest_path.is_file():
        return json.loads(manifest_path.read_text(encoding="utf-8"))
    return {}


def _pick_meta_value(meta: dict, existing: dict, key: str, default: object) -> object:
    val = meta.get(key)
    if val is not None:
        return val
    return existing.get(key, default)


def _verify_expected_sha256(actual_sha256: str, expected_sha256: str | None) -> None:
    if expected_sha256 is None:
        return
    norm_expected = str(expected_sha256).strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", norm_expected) or actual_sha256.lower() != norm_expected:
        raise ValueError(f"Upstream SHA-256 mismatch: expected={norm_expected!r} actual={actual_sha256!r}")


def _preserve_patch_metadata(manifest: dict, meta: dict, existing: dict) -> None:
    patch_url = meta.get("patch_zip_url") or existing.get("patch_zip_url")
    patch_sha = meta.get("patch_zip_sha256") or existing.get("patch_zip_sha256")
    if isinstance(patch_url, str) and patch_url and isinstance(patch_sha, str) and patch_sha:
        manifest["patch_zip_url"] = patch_url
        manifest["patch_zip_sha256"] = patch_sha


def _build_manifest_payload(
    staging_dir: pathlib.Path,
    zip_path: pathlib.Path,
    zip_sha256: str,
    zip_size: int,
    folders: dict[str, dict],
    meta: dict,
    existing: dict,
) -> dict:
    version = validate_version_string(
        _parse_version_from_zip_or_toc(staging_dir, zip_path.name, str(existing.get("version", "5.0.132")))
    )
    revision = _parse_release_revision(staging_dir, int(existing.get("release_revision", 484)))
    file_id = int(_pick_meta_value(meta, existing, "file_id", 9432165))
    if file_id <= 0:
        raise ValueError(f"Invalid non-positive file_id: {file_id}")
    default_url = build_forgecdn_url(file_id, zip_path.name)
    download_url = validate_https_download_url(str(_pick_meta_value(meta, existing, "download_url", default_url)))
    release_date = str(_pick_meta_value(meta, existing, "release_date", "2026-11-09"))
    manifest = {
        "upstream_name": "GodJohnson Integrated Addon",
        "curseforge_project_id": int(existing.get("curseforge_project_id", 1707376)),
        "version": version,
        "release_revision": revision,
        "release_date": release_date,
        "target_client_build": str(existing.get("target_client_build", "1.60.1.70790")),
        "file_id": file_id,
        "file_name": zip_path.name,
        "download_url": download_url,
        "zip_sha256": zip_sha256,
        "zip_size_bytes": zip_size,
        "folder_count": len(folders),
        "folders": folders,
    }
    _preserve_patch_metadata(manifest, meta, existing)
    return manifest


def sync_upstream_zip(
    zip_path: pathlib.Path,
    extract_dest: pathlib.Path,
    repo_root: pathlib.Path,
    release_meta: dict | None = None,
    expected_sha256: str | None = None,
) -> dict:
    meta = release_meta or {}
    zip_sha256 = hashlib.sha256(zip_path.read_bytes()).hexdigest().lower()
    resolved_expected = expected_sha256 if expected_sha256 is not None else meta.get("expected_sha256")
    _verify_expected_sha256(zip_sha256, resolved_expected)
    zip_size = zip_path.stat().st_size

    manifest_path = repo_root / "pinned_upstream.json"
    existing = _load_existing_manifest(manifest_path)
    bridge_lua = repo_root / "ForeverSuite_GJBridge" / "Bridge.lua"

    parent_dir = extract_dest.parent
    parent_dir.mkdir(parents=True, exist_ok=True)
    staging_dir = pathlib.Path(tempfile.mkdtemp(prefix=".gj_sync_stage_", dir=str(parent_dir)))
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            extract_zip_safely(zf, staging_dir)
        folders = _scan_extracted_folders(staging_dir)
        manifest = _build_manifest_payload(staging_dir, zip_path, zip_sha256, zip_size, folders, meta, existing)
        manifest_json = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
        _commit_sync_transaction(staging_dir, extract_dest, manifest_path, manifest_json, bridge_lua, manifest["version"])
        return manifest
    finally:
        if staging_dir.exists():
            shutil.rmtree(staging_dir, ignore_errors=True)


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Sync or verify GodJohnson upstream archive.")
    parser.add_argument("zip_path", nargs="?", help="Local upstream .zip path")
    parser.add_argument("extract_dest", nargs="?", help="Target directory for extracted GodJohnson folders")
    parser.add_argument("--fetch-latest", action="store_true", help="Fetch latest CurseForge release")
    parser.add_argument("--expected-sha256", dest="expected_sha256", default=None, help="Expected 64-hex SHA-256")
    parser.add_argument("--print-extract-dir", action="store_true", help="Print resolved default extract dir and exit")
    parser.add_argument("--verify-dir", dest="verify_dir", default=None, help="Verify extracted TOC hashes in DIR")
    return parser


def _resolve_sync_targets(parsed: argparse.Namespace, root: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, dict]:
    if parsed.fetch_latest or not parsed.zip_path:
        raw_dest = parsed.extract_dest or parsed.zip_path
        edest = pathlib.Path(raw_dest).resolve() if raw_dest else resolve_default_extract_dir(root)
        existing = _load_existing_manifest(root / "pinned_upstream.json")
        zpath, meta = fetch_latest_curseforge_zip(trusted_pin=existing)
        return zpath, edest, meta
    edest = pathlib.Path(parsed.extract_dest).resolve() if parsed.extract_dest else resolve_default_extract_dir(root)
    return pathlib.Path(parsed.zip_path).resolve(), edest, {}


def main(argv: list[str] | None = None) -> int:
    parsed = _build_arg_parser().parse_args(argv if argv is not None else sys.argv[1:])
    root = pathlib.Path(__file__).resolve().parent.parent
    if parsed.print_extract_dir:
        print(str(resolve_default_extract_dir(root)))
        return 0
    if parsed.verify_dir:
        count = verify_extracted_dir(root, pathlib.Path(parsed.verify_dir).resolve())
        print(f"[OK] Verified {count} upstream folders in {parsed.verify_dir}")
        return 0
    zpath, edest, meta = _resolve_sync_targets(parsed, root)
    res = sync_upstream_zip(zpath, edest, root, release_meta=meta, expected_sha256=parsed.expected_sha256)
    print(
        f"[OK] Synced upstream {res['file_name']} v{res['version']} (rev {res['release_revision']}, "
        f"{res['folder_count']} folders, sha256={res['zip_sha256'][:16]}...)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

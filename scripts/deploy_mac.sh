#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WOW_ADDONS_DIR="${1:-/Applications/World of Warcraft/_forever_/Interface/AddOns}"
GJ_EXTRACTED_DIR="${2:-/Users/choyoungseo/workspace/GodJohnson_5.0.132}"

if [[ ! -d "${WOW_ADDONS_DIR}" ]]; then
  echo "[ERROR] WoW Forever AddOns 경로가 존재하지 않습니다: ${WOW_ADDONS_DIR}" >&2
  exit 1
fi

python3 - "${REPO_ROOT}" "${WOW_ADDONS_DIR}" "${GJ_EXTRACTED_DIR}" <<'PY'
import hashlib
import json
import os
import shutil
import sys
import tempfile

repo_root, addons_dir, gj_dir = sys.argv[1], sys.argv[2], sys.argv[3]

manifest_path = os.path.join(repo_root, "pinned_upstream.json")
with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)

def validate_toc_dir(folder_path: str, folder_name: str) -> None:
    toc_path = os.path.join(folder_path, f"{folder_name}.toc")
    if not os.path.isfile(toc_path):
        raise FileNotFoundError(f"TOC 파일 누락: {toc_path}")
    with open(toc_path, "r", encoding="utf-8") as tf:
        for raw_line in tf:
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            rel = line.replace("\\", "/")
            full = os.path.join(folder_path, rel)
            if not os.path.isfile(full):
                raise FileNotFoundError(f"[{folder_name}] TOC 참조 파일 누락: {rel}")

# 1. Validate ForeverSuite & ForeverSuite_GJBridge
sources_to_deploy = {}
for own_addon in ("ForeverSuite", "ForeverSuite_GJBridge"):
    own_src = os.path.join(repo_root, own_addon)
    validate_toc_dir(own_src, own_addon)
    sources_to_deploy[own_addon] = own_src

# 2. Validate GodJohnson 21 folders against pinned_upstream.json if gj_dir exists
if os.path.isdir(gj_dir):
    expected_folders = manifest["folders"]
    for gj_folder, meta in expected_folders.items():
        src_folder = os.path.join(gj_dir, gj_folder)
        if not os.path.isdir(src_folder):
            raise FileNotFoundError(f"업스트림 폴더 누락: {src_folder}")
        validate_toc_dir(src_folder, gj_folder)
        toc_file = os.path.join(src_folder, f"{gj_folder}.toc")
        with open(toc_file, "rb") as tf:
            actual_hash = hashlib.sha256(tf.read()).hexdigest()
        if actual_hash != meta["toc_sha256"]:
            raise RuntimeError(
                f"업스트림 TOC 해시 불일치 차단 [{gj_folder}]: expected={meta['toc_sha256']} actual={actual_hash}"
            )
        sources_to_deploy[gj_folder] = src_folder

staging_parent = tempfile.mkdtemp(prefix=".ForeverSuite_stage_", dir=addons_dir)
backup_parent = os.path.join(addons_dir, ".ForeverSuite_prev_backup")

try:
    for name, src_path in sources_to_deploy.items():
        shutil.copytree(src_path, os.path.join(staging_parent, name))

    if os.path.exists(backup_parent):
        shutil.rmtree(backup_parent)
    os.makedirs(backup_parent, exist_ok=True)

    for name in sorted(sources_to_deploy.keys()):
        target_dir = os.path.join(addons_dir, name)
        stage_dir = os.path.join(staging_parent, name)
        bk_dir = os.path.join(backup_parent, name)
        if os.path.exists(target_dir):
            os.replace(target_dir, bk_dir)
        os.replace(stage_dir, target_dir)
finally:
    if os.path.exists(staging_parent):
        shutil.rmtree(staging_parent, ignore_errors=True)

print(f"[OK] 원자적 배포 완료: 총 {len(sources_to_deploy)}개 애드온 폴더 → {addons_dir} (백업: {backup_parent})")
PY

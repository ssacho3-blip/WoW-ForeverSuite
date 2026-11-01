#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}/ForeverSuite"
WOW_ADDONS_DIR="${1:-/Applications/World of Warcraft/_forever_/Interface/AddOns}"
TARGET_DIR="${WOW_ADDONS_DIR}/ForeverSuite"

if [[ ! -f "${SRC_DIR}/ForeverSuite.toc" ]]; then
  echo "[ERROR] ForeverSuite.toc 파일을 찾을 수 없습니다: ${SRC_DIR}" >&2
  exit 1
fi

if [[ ! -d "${WOW_ADDONS_DIR}" ]]; then
  echo "[ERROR] WoW Forever AddOns 경로가 존재하지 않습니다: ${WOW_ADDONS_DIR}" >&2
  exit 1
fi

python3 - "${SRC_DIR}" "${WOW_ADDONS_DIR}" "${TARGET_DIR}" <<'PY'
import os
import shutil
import sys
import tempfile

src_dir, addons_dir, target_dir = sys.argv[1], sys.argv[2], sys.argv[3]

# Validate every file recorded in ForeverSuite.toc exists before staging
toc_path = os.path.join(src_dir, "ForeverSuite.toc")
with open(toc_path, "r", encoding="utf-8") as f:
    for raw_line in f:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        rel = line.replace("\\", "/")
        full = os.path.join(src_dir, rel)
        if not os.path.isfile(full):
            raise FileNotFoundError(f"TOC 참조 파일 누락: {rel}")

staging_parent = tempfile.mkdtemp(prefix=".ForeverSuite_stage_", dir=addons_dir)
staging_target = os.path.join(staging_parent, "ForeverSuite")
backup_target = os.path.join(addons_dir, ".ForeverSuite_prev_backup")

try:
    shutil.copytree(src_dir, staging_target)
    if os.path.exists(backup_target):
        shutil.rmtree(backup_target)
    if os.path.exists(target_dir):
        os.replace(target_dir, backup_target)
    os.replace(staging_target, target_dir)
    if os.path.exists(backup_target):
        shutil.rmtree(backup_target)
finally:
    if os.path.exists(staging_parent):
        shutil.rmtree(staging_parent, ignore_errors=True)

print(f"[OK] ForeverSuite 원자적 배포 완료 → {target_dir}")
PY

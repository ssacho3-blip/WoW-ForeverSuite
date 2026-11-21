"""Static Lua Hygiene, TOC Parity, Order, Line-Budget, and Optional Luacheck Gate Tests."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys

TESTS_DIR = pathlib.Path(__file__).resolve().parent
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from test_forever_suite import _verify_single_lua_file_compliance  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_DIRS = (
    REPO_ROOT / "ForeverSuite",
    REPO_ROOT / "ForeverSuite_GJBridge",
)
MAX_LUA_LINES = 700


def _parse_toc_entries(addon_dir: pathlib.Path) -> list[pathlib.Path]:
    toc_path = addon_dir / f"{addon_dir.name}.toc"
    assert toc_path.is_file(), f"Missing TOC file: {toc_path}"
    entries: list[pathlib.Path] = []
    for raw in toc_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        assert "\\" not in line, f"Windows backslash found in TOC {toc_path.name}: {line}"
        entries.append(addon_dir / line)
    return entries


def _verify_addon_dir(addon_dir: pathlib.Path) -> list[pathlib.Path]:
    toc_files = _parse_toc_entries(addon_dir)
    disk_lua = sorted(addon_dir.rglob("*.lua"))
    assert sorted(toc_files) == disk_lua, (
        f"TOC <-> disk .lua mismatch in {addon_dir.name}: "
        f"toc={[p.name for p in toc_files]} disk={[p.name for p in disk_lua]}"
    )
    for lua_path in toc_files:
        lines = lua_path.read_text(encoding="utf-8").splitlines()
        assert len(lines) < MAX_LUA_LINES, (
            f"{addon_dir.name}/{lua_path.relative_to(addon_dir)} exceeds {MAX_LUA_LINES}-line budget ({len(lines)} lines)"
        )
        _verify_single_lua_file_compliance(lua_path)
    return toc_files


def test_toc_lua_parity_order_line_budget_and_syntax_across_all_addons() -> None:
    fs_toc = _verify_addon_dir(REPO_ROOT / "ForeverSuite")
    fs_names = [p.name for p in fs_toc]
    assert fs_names.index("QuestTrackerModel.lua") < fs_names.index("QuestTracker.lua")

    bridge_toc = _verify_addon_dir(REPO_ROOT / "ForeverSuite_GJBridge")
    assert [p.name for p in bridge_toc] == ["State.lua", "Branding.lua", "Bridge.lua"]


def test_luacheck_config_and_optional_binary_gate() -> None:
    rc_path = REPO_ROOT / ".luacheckrc"
    assert rc_path.is_file()
    assert 'std = "lua51"' in rc_path.read_text(encoding="utf-8")

    luacheck_bin = shutil.which("luacheck")
    if luacheck_bin is None:
        return

    proc = subprocess.run(
        [luacheck_bin, "--config", str(rc_path), "ForeverSuite", "ForeverSuite_GJBridge"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"luacheck failed:\n{proc.stdout}\n{proc.stderr}"


def test_suite_version_parity_across_toc_lua_and_builder() -> None:
    import json
    import re

    fs_toc = (REPO_ROOT / "ForeverSuite" / "ForeverSuite.toc").read_text(encoding="utf-8")
    gj_toc = (REPO_ROOT / "ForeverSuite_GJBridge" / "ForeverSuite_GJBridge.toc").read_text(encoding="utf-8")
    init_lua = (REPO_ROOT / "ForeverSuite" / "Core" / "Init.lua").read_text(encoding="utf-8")
    state_lua = (REPO_ROOT / "ForeverSuite_GJBridge" / "State.lua").read_text(encoding="utf-8")
    builder_py = (REPO_ROOT / "scripts" / "build_win_exe.py").read_text(encoding="utf-8")
    manifest = json.loads((REPO_ROOT / "pinned_upstream.json").read_text(encoding="utf-8"))

    fs_ver = re.search(r"^##\s*Version:\s*([\w.\-]+)", fs_toc, re.MULTILINE).group(1)
    gj_ver = re.search(r"^##\s*Version:\s*([\w.\-]+)", gj_toc, re.MULTILINE).group(1)
    init_ver = re.search(r'local\s+ver\s*=\s*"([\w.\-]+)"', init_lua).group(1)
    state_ver = re.search(r'ns\.VERSION\s*=\s*"([\w.\-]+)"', state_lua).group(1)
    b_read_ver = re.search(r'def\s+read_suite_version\([^)]*default:\s*str\s*=\s*"([\w.\-]+)"', builder_py).group(1)
    b_ps1_ver = re.search(r'def\s+build_embedded_ps1_script\([^)]*suite_version:\s*str\s*=\s*"([\w.\-]+)"', builder_py).group(1)
    patch_url = str(manifest.get("patch_zip_url", ""))
    m_patch = re.search(r"ForeverSuite-v([\w.\-]+)\.zip$", patch_url)
    patch_ver = m_patch.group(1) if m_patch else None

    assert len({fs_ver, gj_ver, init_ver, state_ver, b_read_ver, b_ps1_ver, patch_ver}) == 1, (
        f"Version mismatch: fs_toc={fs_ver}, gj_toc={gj_ver}, init={init_ver}, state={state_ver}, "
        f"read_default={b_read_ver}, ps1_default={b_ps1_ver}, manifest_patch={patch_ver}"
    )

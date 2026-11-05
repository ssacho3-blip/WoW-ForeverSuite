"""BDD/DDT Test Suite for ForeverSuite_GJBridge, Single-Owner Arbitration, and Windows 1-Click .exe Builder."""

from __future__ import annotations

import base64
import hashlib
import io
import json
import pathlib
import re
import struct
import zipfile
from typing import Any

import pytest

from binary_api_manifest import FORBIDDEN_COMBAT_AUTOMATION_APIS, FORBIDDEN_LEGACY_APIS
from build_win_exe import build_windows_installer_exe
from lua51_engine import LuaTable, parse_lua51
from package_release import build_release_zip
from wow_forever_mock import WoWForeverMockRuntime

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"
BRIDGE_ROOT = REPO_ROOT / "ForeverSuite_GJBridge"
GJ_EXTRACTED_ROOT = REPO_ROOT.parent / "GodJohnson_5.0.132"


def load_bridge(rt: WoWForeverMockRuntime) -> LuaTable:
    bridge_ns = LuaTable()
    bridge_lua = (BRIDGE_ROOT / "Bridge.lua").read_text(encoding="utf-8")
    rt.vm.run_chunk(bridge_lua, filename="Bridge.lua", chunk_args=("ForeverSuite_GJBridge", bridge_ns))
    return bridge_ns


# ---------------------------------------------------------------------------
# 1. Static Compliance & Upstream Pin Integrity (Phase 0 & Phase 1)
# ---------------------------------------------------------------------------


def _extract_first_code_line(src: str) -> str:
    for line in src.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("--"):
            return stripped
    return ""


def _strip_lua_comments(src: str) -> str:
    return "\n".join(line.split("--", 1)[0] for line in src.splitlines())


def test_gj_bridge_toc_and_lua_static_compliance() -> None:
    toc_path = BRIDGE_ROOT / "ForeverSuite_GJBridge.toc"
    assert toc_path.is_file()
    raw_toc = toc_path.read_text(encoding="utf-8")
    assert "## Dependencies: GodJohnsonGoldBorder, ForeverSuite" in raw_toc
    assert "16001" in raw_toc
    assert "Bridge.lua" in raw_toc

    lua_path = BRIDGE_ROOT / "Bridge.lua"
    raw_bytes = lua_path.read_bytes()
    assert not raw_bytes.startswith(b"\xef\xbb\xbf")
    assert b"\r\n" not in raw_bytes

    src = raw_bytes.decode("utf-8")
    first_code_line = _extract_first_code_line(src)
    assert re.match(r"^local\s+[A-Za-z0-9_]+\s*,\s*ns\s*=\s*\.\.\.$", first_code_line)
    parse_lua51(src, filename="Bridge.lua")

    code_no_comments = _strip_lua_comments(src)
    tokens = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", code_no_comments))
    assert not (tokens & FORBIDDEN_LEGACY_APIS)
    assert not (tokens & FORBIDDEN_COMBAT_AUTOMATION_APIS)


def _verify_extracted_toc_hashes(folders: dict[str, Any]) -> None:
    for folder_name, meta in folders.items():
        toc_file = GJ_EXTRACTED_ROOT / folder_name / f"{folder_name}.toc"
        assert toc_file.is_file(), f"Missing upstream TOC: {toc_file}"
        actual_sha256 = hashlib.sha256(toc_file.read_bytes()).hexdigest()
        assert actual_sha256 == meta["toc_sha256"], f"Upstream TOC mutated: {folder_name}"


def test_pinned_upstream_manifest_and_21_folders_unmodified() -> None:
    manifest_path = REPO_ROOT / "pinned_upstream.json"
    assert manifest_path.is_file()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["version"] == "5.0.132"
    assert manifest["folder_count"] == 21
    assert len(manifest["folders"]) == 21

    font_choice_folders = [k for k in manifest["folders"] if str(k).startswith("GodJohnsonFontChoice_")]
    assert len(font_choice_folders) == 14
    _verify_extracted_toc_hashes(manifest["folders"])


# ---------------------------------------------------------------------------
# 2. ForeverSuite_GJBridge Runtime Overrides & Unavailable Guard (Phase 1)
# ---------------------------------------------------------------------------


def test_bridge_unavailable_when_gj_companion_absent() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()
    bridge = load_bridge(rt)

    assert bridge.get("status") == "UNAVAILABLE"
    targets = bridge.get("targets")
    for key in ("sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper"):
        assert targets.get(key) == "UNAVAILABLE"

    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITEGJ", "status")
    assert any("UNAVAILABLE" in m for m in rt.chat_messages)


def test_bridge_branding_overrides_and_deferred_launcher_skin() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()

    # Install a mock GJCompanion matching GodJohnson 5.0.132 structure
    rt.vm.run_chunk(
        """
        GJCompanion = {
            version = "5.0.132",
            ExtraSchemas = {
                vitalAlerts = {
                    { key = "hpTemplate", default = "[갓존슨] {자원} {퍼센트}% 남았습니다!" },
                },
            },
        }
        function GJCompanion.Say(s)
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd36a갓존슨:|r " .. tostring(s))
        end
        function GJCompanion.OpenYouTube()
            DEFAULT_CHAT_FRAME:AddMessage("YOUTUBE_OPENED")
        end
        function GJCompanion.BuildYouTubeButton(parent, heading, ButtonFn)
            local b = CreateFrame("Button", "MockYTBtn", parent)
            GJCompanion.YouTubeButton = b
        end
        function GJCompanion.BuildHome404(p)
            local logo = CreateFrame("Button", nil, p)
            local notice = p:CreateFontString(nil, "OVERLAY")
            notice:SetText("원본 스트리머 공지문")
            GJCompanion.Home404 = { frame = p, logo = logo, notice = notice }
        end
        function GJCompanion.TradeManager404Config()
            if not GJCompanion._tradeCfg then
                GJCompanion._tradeCfg = { record = true, notify = true, limit = 50 }
            end
            return GJCompanion._tradeCfg
        end
        function GJCompanion.ExtraSettings(key)
            if key == "merchantAutomation" then
                return { repair = false, sell = false }
            elseif key == "automation" then
                return { accept = false, complete = false }
            end
            return {}
        end
        function GJCompanion.FishingSettings()
            return { enabled = false, doubleClick = false }
        end
        """
    )

    bridge = load_bridge(rt)
    assert bridge.get("status") == "ACTIVE"
    targets = bridge.get("targets")
    assert targets.get("sayPrefix") == "APPLIED"
    assert targets.get("youtubeLink") == "APPLIED"
    assert targets.get("homeScreen") == "APPLIED"
    assert targets.get("tradeWhisper") == "APPLIED"
    # Launcher does not exist yet -> PENDING
    assert targets.get("launcherIcon") == "PENDING"

    # 1. Verify C.Say prefix is replaced
    rt.chat_messages.clear()
    rt.vm.run_chunk('GJCompanion.Say("테스트 메시지")')
    joined_say = "\n".join(rt.chat_messages)
    assert "[포에버]:" in joined_say and "갓존슨:" not in joined_say

    # 2. Verify OpenYouTube is neutralized & BuildYouTubeButton hides button
    rt.chat_messages.clear()
    rt.vm.run_chunk("GJCompanion.OpenYouTube()")
    joined_yt = "\n".join(rt.chat_messages)
    assert "YOUTUBE_OPENED" not in joined_yt
    assert "포에버 개인용 통합 환경" in joined_yt

    rt.vm.run_chunk("GJCompanion.BuildYouTubeButton(UIParent, nil, nil)")
    yt_btn = rt.vm.G["GJCompanion"].get("YouTubeButton")
    assert yt_btn.get("_shown") is False

    # 3. Verify BuildHome404 replaces streamer notice
    rt.vm.run_chunk("GJCompanion.BuildHome404(UIParent)")
    home_notice = rt.vm.G["GJCompanion"].get("Home404").get("notice").get("_text")
    assert "포에버 개인용 통합 애드온" in home_notice
    assert "원본 21개 폴더 무수정" in home_notice

    # 4. Verify TradeManager404Config notify defaults to false & vitalAlerts template cleaned
    cfg = rt.vm.run_chunk("return GJCompanion.TradeManager404Config()")[0]
    assert cfg.get("notify") is False
    vital_tpl = (
        rt.vm.G["GJCompanion"]
        .get("ExtraSchemas")
        .get("vitalAlerts")
        .get(1)
        .get("default")
    )
    assert vital_tpl.startswith("[알림]")

    # 5. Now simulate deferred creation of GodJohnsonGoldBorderLauncher on PLAYER_LOGIN
    rt.vm.run_chunk(
        """
        local l = CreateFrame("Button", "GodJohnsonGoldBorderLauncher", UIParent)
        local tex = l:CreateTexture(nil, "ARTWORK")
        tex._texId = nil
        function tex:SetTexture(id) self._texId = id end
        l.logo = tex
        """
    )
    rt.fire_event("PLAYER_LOGIN")
    assert targets.get("launcherIcon") == "APPLIED"
    launcher_logo_tex = rt.vm.G["GodJohnsonGoldBorderLauncher"].get("logo").get("_texId")
    assert launcher_logo_tex == 134063


# ---------------------------------------------------------------------------
# 3. Single-Owner Arbitration DDT (Phase 2 — Opus Conditions #3 & #4)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("gj_repair", "gj_sell", "gj_quest", "gj_fishing", "expected_fs_repair", "expected_fs_sell", "expected_fs_quest", "expected_fs_fishing"),
    [
        # Case 1: GJ has all 4 OFF -> ForeverSuite owns all 4
        (False, False, False, False, True, True, True, True),
        # Case 2: GJ has all 4 ON -> ForeverSuite yields all 4 (0 double execution)
        (True, True, True, True, False, False, False, False),
        # Case 3: Mixed (GJ owns repair & fishing; FS owns sell & quest)
        (True, False, False, True, False, True, True, False),
        # Case 4: Unreadable / corrupted GJ settings ("corrupt" string instead of boolean) -> Fail-Safe YIELD!
        ("corrupt", "corrupt", "corrupt", "corrupt", False, False, False, False),
    ],
)
def test_single_owner_arbitration_matrix_ddt(
    gj_repair: Any,
    gj_sell: Any,
    gj_quest: Any,
    gj_fishing: Any,
    expected_fs_repair: bool,
    expected_fs_sell: bool,
    expected_fs_quest: bool,
    expected_fs_fishing: bool,
) -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()

    def to_lua_lit(val: Any) -> str:
        if isinstance(val, bool):
            return "true" if val else "false"
        return f'"{val}"'

    rt.vm.run_chunk(
        f"""
        GJCompanion = {{
            version = "5.0.132",
            ExtraSettings = function(key)
                if key == "merchantAutomation" then
                    return {{ repair = {to_lua_lit(gj_repair)}, sell = {to_lua_lit(gj_sell)} }}
                elseif key == "automation" then
                    return {{ accept = {to_lua_lit(gj_quest)}, complete = {to_lua_lit(gj_quest)} }}
                end
                return {{}}
            end,
            FishingSettings = function()
                return {{ enabled = {to_lua_lit(gj_fishing)}, doubleClick = {to_lua_lit(gj_fishing)} }}
            end,
        }}
        """
    )

    load_bridge(rt)

    # Check ForeverSuite feature yield flags
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("repair")')[0] is (not expected_fs_repair)
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("sell")')[0] is (not expected_fs_sell)
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("questAuto")')[0] is (not expected_fs_quest)
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("fishing")')[0] is (not expected_fs_fishing)
    # Condition #3: /way is NEVER yielded to GJ
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("way")')[0] is False

    # Verify runtime behavior on MERCHANT_SHOW (repair + junk sell)
    rt.repair_cost = 500
    rt.can_merchant_repair = True
    rt.bags[0]["items"][1] = {"itemID": 9001, "stackCount": 2, "quality": 0, "isLocked": False, "hasNoValue": False}
    rt.repair_calls.clear()
    rt.sold_bag_slots.clear()

    rt.fire_event("MERCHANT_SHOW")
    assert (len(rt.repair_calls) == 1) is expected_fs_repair
    assert (len(rt.sold_bag_slots) == 1) is expected_fs_sell

    # Verify runtime behavior on QUEST_DETAIL (questAuto)
    rt.accepted_quests = 0
    rt.fire_event("QUEST_DETAIL")
    assert (rt.accepted_quests == 1) is expected_fs_quest

    # Verify runtime behavior on WorldFrame double-right-click (fishing)
    rt.equipped_items[16] = 6256
    rt.fire_event("PLAYER_EQUIPMENT_CHANGED", 16)
    rt.override_bindings.clear()
    wf = rt.vm.G["WorldFrame"]
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    rt.now += 0.20
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    assert (len(rt.override_bindings) == 1) is expected_fs_fishing


# ---------------------------------------------------------------------------
# 4. Windows 1-Click .exe Installer PE32+ Binary & Payload Verification (Phase 4)
# ---------------------------------------------------------------------------


def test_windows_one_click_exe_pe32plus_and_payload_integrity() -> None:
    zip_out = build_release_zip(REPO_ROOT, version="0.2.0")
    assert zip_out.is_file()
    with zipfile.ZipFile(zip_out, "r") as zf:
        names = set(zf.namelist())
        assert "ForeverSuite/ForeverSuite.toc" in names
        assert "ForeverSuite_GJBridge/ForeverSuite_GJBridge.toc" in names
        assert "ForeverSuite_GJBridge/Bridge.lua" in names

    exe_path = build_windows_installer_exe(REPO_ROOT)
    assert exe_path.is_file()
    raw = exe_path.read_bytes()

    # 1. Verify DOS & PE32+ (AMD64) headers
    assert raw[:2] == b"MZ"
    e_lfanew = struct.unpack_from("<I", raw, 0x3C)[0]
    assert e_lfanew == 0x80
    assert raw[0x80:0x84] == b"PE\x00\x00"
    machine, num_sections, _, _, _, opt_size, _ = struct.unpack_from("<HHIIIHH", raw, 0x84)
    assert machine == 0x8664  # IMAGE_FILE_MACHINE_AMD64
    assert num_sections == 2
    assert opt_size == 0xF0

    opt_magic = struct.unpack_from("<H", raw, 0x98)[0]
    assert opt_magic == 0x020B  # PE32+ (64-bit)

    # 2. Verify KERNEL32.dll imports in .data
    assert b"KERNEL32.dll\x00" in raw
    for api_name in (
        b"GetModuleFileNameA",
        b"SetEnvironmentVariableA",
        b"CreateProcessA",
        b"WaitForSingleObject",
        b"ExitProcess",
    ):
        assert api_name in raw

    # 3. Verify embedded PowerShell script and Base64 ZIP payload
    start_marker = b"__FS_PS1_START__"
    end_marker = b"__FS_PS1_END__"
    assert start_marker in raw and end_marker in raw
    ps1_bytes = raw.rsplit(start_marker, 1)[1].split(end_marker, 1)[0]
    ps1_text = ps1_bytes.decode("utf-8")
    assert "2cf3a5044f379aa2071dd734c35c6094c8765f923965db6afd39cae7736d1efd" in ps1_text
    assert "GodJohnson-5.0.132.zip" in ps1_text

    m = re.search(r'FromBase64String\("([A-Za-z0-9+/=]+)"\)', ps1_text)
    assert m is not None
    embedded_zip_bytes = base64.b64decode(m.group(1))
    with zipfile.ZipFile(io.BytesIO(embedded_zip_bytes), "r") as ezf:
        enames = set(ezf.namelist())
        assert "ForeverSuite/ForeverSuite.toc" in enames
        assert "ForeverSuite_GJBridge/ForeverSuite_GJBridge.toc" in enames

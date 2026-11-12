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
from build_win_exe import _validate_manifest_security, build_embedded_ps1_script, build_windows_installer_exe
from lua51_engine import LuaTable, parse_lua51
from package_release import build_release_zip
from sync_upstream import (
    SafeHTTPSRedirectHandler,
    _is_verified_cached_zip,
    _parse_release_revision,
    _parse_version_from_zip_or_toc,
    _trusted_sha_for_file,
    build_forgecdn_url,
    extract_zip_safely,
    sanitize_zip_filename,
    select_latest_cfwidget_file,
    sync_upstream_zip,
    validate_https_download_url,
    validate_zip_archive_safety,
)
from wow_forever_mock import WoWForeverMockRuntime

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"
BRIDGE_ROOT = REPO_ROOT / "ForeverSuite_GJBridge"


def _resolve_gj_extracted_root() -> pathlib.Path:
    for cand in (
        REPO_ROOT.parent / "GodJohnson_5.0.132",
        pathlib.Path("/Users/choyoungseo/workspace/GodJohnson_5.0.132"),
        pathlib.Path("/Applications/World of Warcraft/_forever_/Interface/AddOns"),
    ):
        if (cand / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc").is_file():
            return cand
    return REPO_ROOT.parent / "GodJohnson_5.0.132"


GJ_EXTRACTED_ROOT = _resolve_gj_extracted_root()


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
    assert manifest["version"] == "5.0.213"
    assert manifest["file_id"] == 9520137
    assert manifest["release_revision"] == 565
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
    for key in ("sayPrefix", "youtubeLink", "homeScreen", "launcherIcon", "tradeWhisper", "questSound"):
        assert targets.get(key) == "UNAVAILABLE"
    assert targets.get("cursorTrail") is None

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


def test_quest_sound_oishii_removed_and_replaced_with_clean_alarm() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()

    rt.vm.run_chunk(
        """
        GJCompanion = {
            version = "5.0.132",
            NotificationSoundNames = {
                oishii_high = "하이톤 오이쉬",
                oishii_deep = "걸쭉 오이쉬",
                dingdong = "띵동",
                quest_complete = "NPC퀘스트 완료",
            },
            ExtraSchemas = {
                questAnnounce = {
                    { key = "questSound", default = "oishii_high" },
                    { key = "objectiveSound", default = "oishii_deep" },
                    { key = "questTemplate", default = "[갓존슨] {퀘스트} 퀘스트 완료!" },
                    { key = "objectiveTemplate", default = "[갓존슨] {퀘스트}: {목표} 완료!" },
                },
            },
            _questCfg = {
                questSound = "oishii_high",
                objectiveSound = "oishii_deep",
                questTemplate = "[갓존슨] {퀘스트} 퀘스트 완료!",
                objectiveTemplate = "[갓존슨] {퀘스트}: {목표} 완료!",
            },
            _bookCfg = {
                acquisitionSound = "oishii_high",
            },
            _playedSounds = {},
        }
        function GJCompanion.ExtraSettings(key)
            if key == "questAnnounce" then
                return GJCompanion._questCfg
            elseif key == "libraryBooksAccess471" then
                return GJCompanion._bookCfg
            end
            return {}
        end
        function GJCompanion.PlayNotificationSound(key, volume, source, importance, channel)
            GJCompanion._playedSounds[#GJCompanion._playedSounds + 1] = key
            return true
        end
        """
    )

    bridge = load_bridge(rt)
    assert bridge.get("targets").get("questSound") == "APPLIED"

    # 1. Schema defaults must no longer be oishii_high / oishii_deep
    qa_schema = rt.vm.G["GJCompanion"].get("ExtraSchemas").get("questAnnounce")
    assert qa_schema.get(1).get("default") == "dingdong"
    assert qa_schema.get(2).get("default") == "dingdong"
    assert qa_schema.get(3).get("default").startswith("[포에버]")

    # 2. Existing saved profile settings must be sanitized from oishii -> dingdong
    q_cfg = rt.vm.run_chunk('return GJCompanion.ExtraSettings("questAnnounce")')[0]
    assert q_cfg.get("questSound") == "dingdong"
    assert q_cfg.get("objectiveSound") == "dingdong"
    assert q_cfg.get("questTemplate").startswith("[포에버]")
    assert q_cfg.get("objectiveTemplate").startswith("[포에버]")

    b_cfg = rt.vm.run_chunk('return GJCompanion.ExtraSettings("libraryBooksAccess471")')[0]
    assert b_cfg.get("acquisitionSound") == "dingdong"

    # 3. Direct PlayNotificationSound("oishii_high" / "oishii_deep") must remap to "dingdong"
    rt.vm.run_chunk('GJCompanion.PlayNotificationSound("oishii_high", 100, "quest", 2, "SFX")')
    rt.vm.run_chunk('GJCompanion.PlayNotificationSound("oishii_deep", 100, "quest", 2, "SFX")')
    played = rt.vm.G["GJCompanion"].get("_playedSounds")
    assert played.get(1) == "dingdong"
    assert played.get(2) == "dingdong"


def test_cursor_trail_untouched_and_accidental_sanitization_restored() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()

    rt.vm.run_chunk(
        """
        local trailFrame = CreateFrame("Frame", "GodJohnsonCursorTrail", UIParent)
        trailFrame:Show()

        GJCompanion = {
            version = "5.0.132",
            ExtraSchemas = {
                cursorTrail = {
                    { key = "enabled", default = true },
                    { key = "style", default = "orbTrial" },
                },
            },
            _cursorCfg = {
                enabled = true,
                style = "chainTrial",
            },
            _refreshCount = 0,
        }
        function GJCompanion.ExtraSettings(key)
            if key == "cursorTrail" then
                return GJCompanion._cursorCfg
            end
            return {}
        end
        function GJCompanion.RefreshCursorTrail()
            GJCompanion._refreshCount = GJCompanion._refreshCount + 1
        end
        """
    )

    bridge = load_bridge(rt)
    assert bridge.get("targets").get("cursorTrail") is None

    ct_schema = rt.vm.G["GJCompanion"].get("ExtraSchemas").get("cursorTrail")
    assert ct_schema.get(1).get("default") is True
    assert ct_schema.get(2).get("default") == "orbTrial"

    ct_cfg = rt.vm.run_chunk('return GJCompanion.ExtraSettings("cursorTrail")')[0]
    assert ct_cfg.get("enabled") is True
    assert ct_cfg.get("style") == "chainTrial"

    trail_frame = rt.vm.G["GodJohnsonCursorTrail"]
    assert trail_frame.get("_shown") is True

    # Verify marked-settings recovery branch when _fsgjCursorLightningSanitized was previously set
    rt.vm.run_chunk(
        """
        GJCompanion._cursorCfg.enabled = false
        GJCompanion._cursorCfg.style = "dot"
        GJCompanion._cursorCfg._fsgjCursorLightningSanitized = true
        ForeverSuite_GJBridge.SanitizeLiveGJSettings()
        """
    )
    assert ct_cfg.get("enabled") is True
    assert ct_cfg.get("style") == "chainTrial"
    assert ct_cfg.get("_fsgjCursorLightningSanitized") is None
    assert rt.vm.G["GJCompanion"].get("_refreshCount") == 1


def _assert_utility_zero_actionbar_symbols() -> None:
    utility_src = (ADDON_ROOT / "Modules" / "Utility.lua").read_text(encoding="utf-8")
    utility_code = _strip_lua_comments(utility_src)
    forbidden_actionbar_symbols = (
        "ActionButton",
        "MainMenuBar",
        "MainActionBar",
        "MultiBar",
        "SetShowGrid",
        "PROXY_SHOW_ACTIONBAR",
        "MultiActionBar_Update",
        "ActionBarController_UpdateAll",
    )
    for sym in forbidden_actionbar_symbols:
        assert sym not in utility_code, f"Zero-Taint Violation: Utility.lua must not reference {sym}"


def _assert_bars_slash_command_behavior(rt: WoWForeverMockRuntime, ns: LuaTable) -> None:
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "bars")
    assert rt.vm.G.get("_togglesCalled") is None
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] == 0
    assert "전투 중에는 스킬창 설정을 변경할 수 없습니다" in "\n".join(rt.chat_messages)

    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "bars")
    assert rt.cvars["alwaysShowActionBars"] == "1"
    toggles = rt.vm.G.get("_togglesCalled")
    assert toggles is not None
    assert toggles.get(1) is False
    assert "/reload" in "\n".join(rt.chat_messages)

    rt.vm.run_chunk("SetActionBarToggles = nil")
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "bars")
    joined_err = "\n".join(rt.chat_messages)
    assert "스킬창 설정 API 호출에 실패" in joined_err
    assert "표시 해제 완료" not in joined_err


def test_zero_actionbar_taint_and_combat_safe_bars_command() -> None:
    _assert_utility_zero_actionbar_symbols()
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.vm.run_chunk(
        """
        ForeverSuiteDB = {
            schemaVersion = 2,
            account = {
                utility = {
                    extraActionBars = true,
                    extraActionBarMode = "STANDARD",
                },
            },
        }
        _togglesCalled = nil
        function SetActionBarToggles(b1, b2, b3, b4, alwaysShow, b5, b6, b7)
            _togglesCalled = { b1, b2, b3, b4, alwaysShow, b5, b6, b7 }
        end
        MainMenuBar = CreateFrame("Frame", "MainMenuBar", UIParent)
        MultiBarBottomLeft = CreateFrame("Frame", "MultiBarBottomLeft", UIParent)
        MultiBarBottomLeft:Show()
        """
    )

    ns = rt.boot_session()
    rt.fire_event("PLAYER_ENTERING_WORLD")

    assert rt.vm.G.get("_togglesCalled") is None
    assert rt.vm.G["MultiBarBottomLeft"]["_shown"] is True

    util_acct = ns["ProfileManager"]["runtimeAccount"]["utility"]
    assert util_acct.get("extraActionBars") is None
    assert util_acct.get("extraActionBarMode") is None
    assert util_acct.get("_extraBarsRollback20261106") is True
    assert util_acct.get("_extraBarsRollback20261107") is True

    fish_btn = rt.vm.G.get("ForeverSuiteFishingButton")
    assert fish_btn is not None
    assert fish_btn.get("_shown") is False
    rt.combat_lockdown = True
    rt.fire_event("PLAYER_REGEN_DISABLED")
    assert rt.addon_action_blocked_count == 0
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] == 0
    _assert_bars_slash_command_behavior(rt, ns)


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


def test_windows_one_click_exe_pe32plus_and_payload_integrity(tmp_path: pathlib.Path) -> None:
    zip_out = build_release_zip(REPO_ROOT, version="0.2.0", out_dir=tmp_path)
    assert zip_out.is_file()
    with zipfile.ZipFile(zip_out, "r") as zf:
        names = set(zf.namelist())
        assert "ForeverSuite/ForeverSuite.toc" in names
        assert "ForeverSuite_GJBridge/ForeverSuite_GJBridge.toc" in names
        assert "ForeverSuite_GJBridge/Bridge.lua" in names

    exe_path = build_windows_installer_exe(REPO_ROOT, out_dir=tmp_path)
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
    assert "ae532c87b3591f2c6d9685d0ad28515371527a7950c9acb85acbb0df25cec6c5" in ps1_text
    assert "GodJohnson-5.0.213.zip" in ps1_text
    assert "ForeverSuite_AutoUpdate" in ps1_text
    assert "Register-ScheduledTask" in ps1_text
    assert "Security hash mismatch blocked" in ps1_text
    assert "$AutoUpdaterBody = @'" in ps1_text
    assert "autoupdate_error.log" in ps1_text
    assert ps1_text.index("$Swapped +=") < ps1_text.index("Move-Item -Path $DirItem.FullName -Destination $Dest -Force")
    assert "$PatchChanged" in ps1_text
    assert "[Net.SecurityProtocolType]::Tls12" in ps1_text
    assert "Untrusted URI scheme or host blocked:" in ps1_text
    assert "Invalid upstream SHA-256 format blocked" in ps1_text
    assert "Assert-SafeHttpsUri $ManifestUri" in ps1_text
    assert "Assert-SafeHttpsUri $RemoteDlUrl" in ps1_text
    assert "[IO.Path]::GetFileName($RawFileName)" in ps1_text
    assert "Unsafe upstream archive filename blocked" in ps1_text
    assert "Untrusted addon folder blocked:" in ps1_text
    assert r"System32\WindowsPowerShell\v1.0\powershell.exe" in ps1_text

    m = re.search(r'FromBase64String\("([A-Za-z0-9+/=]+)"\)', ps1_text)
    assert m is not None
    embedded_zip_bytes = base64.b64decode(m.group(1))
    with zipfile.ZipFile(io.BytesIO(embedded_zip_bytes), "r") as ezf:
        enames = set(ezf.namelist())
        assert "ForeverSuite/ForeverSuite.toc" in enames
        assert "ForeverSuite_GJBridge/ForeverSuite_GJBridge.toc" in enames


def test_sync_upstream_helpers_and_hermetic_zip_sync(tmp_path: pathlib.Path) -> None:
    assert (
        build_forgecdn_url(9520137, "GodJohnson-5.0.213.zip")
        == "https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip"
    )
    selected = select_latest_cfwidget_file(
        {
            "download": {"id": 9432165, "name": "GodJohnson-5.0.132.zip"},
            "files": [
                {"id": 9511692, "name": "GodJohnson-5.0.212.zip"},
                {"id": 9520137, "name": "GodJohnson-5.0.213.zip"},
            ],
        }
    )
    assert selected["id"] == 9520137

    fake_zip = tmp_path / "GodJohnson-5.0.299.zip"
    with zipfile.ZipFile(fake_zip, "w") as zf:
        zf.writestr("GodJohnsonGoldBorder/GodJohnsonGoldBorder.toc", "## Interface: 16001\n## Version: 5.0.299\n")
        zf.writestr("GodJohnsonGoldBorder/CompanionCore.lua", "C.releaseRevision = 777\n")

    fake_sha = hashlib.sha256(fake_zip.read_bytes()).hexdigest()
    assert _is_verified_cached_zip(fake_zip, fake_sha) is True
    assert _is_verified_cached_zip(fake_zip, "0" * 64) is False
    assert _is_verified_cached_zip(fake_zip, None) is False
    assert _trusted_sha_for_file({"file_id": 9999001, "zip_sha256": fake_sha}, 9999001) == fake_sha
    assert _trusted_sha_for_file({"file_id": 9999001, "zip_sha256": fake_sha}, 9999002) is None

    fake_repo = tmp_path / "repo"
    (fake_repo / "ForeverSuite_GJBridge").mkdir(parents=True)
    (fake_repo / "ForeverSuite_GJBridge" / "Bridge.lua").write_text('ns.UPSTREAM_PIN = "5.0.132"\n', encoding="utf-8")
    extract_dest = tmp_path / "extracted_gj"
    manifest = sync_upstream_zip(
        fake_zip,
        extract_dest,
        fake_repo,
        release_meta={"file_id": 9999001, "release_date": "2026-11-10"},
    )
    assert manifest["version"] == "5.0.299"
    assert manifest["release_revision"] == 777
    assert manifest["file_id"] == 9999001
    assert _parse_version_from_zip_or_toc(extract_dest, "custom.zip", "0.0.0") == "5.0.299"
    assert _parse_release_revision(extract_dest, 100) == 777
    assert 'ns.UPSTREAM_PIN = "5.0.299"' in (fake_repo / "ForeverSuite_GJBridge" / "Bridge.lua").read_text(
        encoding="utf-8"
    )


def test_partial_ownership_tables_idempotent_lifecycle_hooks_and_fishing_secure_btn() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()

    # 1. Verify ForeverSuiteFishingButton registers AnyUp/AnyDown and PostClick handler
    btn = rt.vm.G.get("ForeverSuiteFishingButton")
    assert btn is not None
    assert btn.get("_scripts").get("PostClick") is not None

    # 2. Partial automation table ({ accept = true }, complete = nil) & idempotent ApplyLifecycleHooks
    rt.vm.run_chunk(
        """
        _hookCount = 0
        local origHook = hooksecurefunc
        hooksecurefunc = function(tbl, key, fn)
            _hookCount = _hookCount + 1
            if origHook then return origHook(tbl, key, fn) end
        end
        GJCompanion = {
            version = "5.0.132",
            ExtraSettings = function(key)
                if key == "merchantAutomation" then
                    return { repair = false, sell = false }
                elseif key == "automation" then
                    return { accept = true }
                end
                return {}
            end,
            FishingSettings = function()
                return { enabled = true }
            end,
            RestoreLauncher = function() end,
            CommitSettings = function() end,
        }
        """
    )
    bridge = load_bridge(rt)
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("questAuto")')[0] is True
    assert rt.vm.run_chunk('return ForeverSuite.IsFeatureYielded("fishing")')[0] is False
    hooks_first = rt.vm.G.get("_hookCount")
    assert hooks_first > 0

    # Calling ApplyLifecycleHooks a second time must NOT register duplicate hooksecurefunc callbacks
    rt.vm._invoke_callable(bridge["ApplyLifecycleHooks"], ())
    assert rt.vm.G.get("_hookCount") == hooks_first


def _assert_redirect_handler_security() -> None:
    import urllib.request

    req = urllib.request.Request("https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip")
    handler = SafeHTTPSRedirectHandler(max_hops=2)
    hop1 = handler.redirect_request(req, None, 302, "Found", {}, "https://edge.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip")
    assert hop1 is not None
    with pytest.raises(ValueError, match="Untrusted download URL"):
        handler.redirect_request(req, None, 302, "Found", {}, "http://edge.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip")

    handler_hops = SafeHTTPSRedirectHandler(max_hops=1)
    handler_hops.redirect_request(req, None, 302, "Found", {}, "https://edge.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip")
    with pytest.raises(ValueError, match="Redirect hop limit exceeded"):
        handler_hops.redirect_request(req, None, 302, "Found", {}, "https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip")


def _assert_ps1_security_helpers() -> None:
    import base64

    valid_manifest = {
        "download_url": "https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip",
        "zip_sha256": "a" * 64,
        "version": "5.0.213",
        "file_name": "GodJohnson-5.0.213.zip",
    }
    ps1 = build_embedded_ps1_script(valid_manifest, base64.b64encode(b"PK").decode("ascii"))
    assert "function Assert-SafeHttpsUri" in ps1
    assert "function Open-SafeHttpsResponse" in ps1
    assert "function Assert-NoReparsePoint" in ps1
    assert "function Expand-SafeZipArchive" in ps1
    assert "DirectorySeparatorChar" in ps1
    assert "AllowAutoRedirect = $false" in ps1

    bad_manifest = dict(valid_manifest, download_url="https://evil.example.com/GodJohnson-5.0.213.zip")
    with pytest.raises(ValueError, match="allowed host"):
        _validate_manifest_security(bad_manifest)


def _assert_safe_zip_extraction_and_sibling_escape(tmp_path: pathlib.Path) -> None:
    good_zip = tmp_path / "good_top_level.zip"
    with zipfile.ZipFile(good_zip, "w") as zf_good:
        zf_good.writestr("README.txt", "root-file")
        zf_good.writestr("GodJohnsonGoldBorder/", "")
        zf_good.writestr("GodJohnsonGoldBorder/GodJohnsonGoldBorder.toc", "## Version: 5.0.213\n")
    good_dest = tmp_path / "good_stage"
    good_dest.mkdir()
    with zipfile.ZipFile(good_zip, "r") as zf_good_read:
        extract_zip_safely(zf_good_read, good_dest)
    assert (good_dest / "README.txt").read_text(encoding="utf-8") == "root-file"
    assert (good_dest / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc").is_file()

    # Sibling-prefix escape: /tmp/.../stage_dest vs /tmp/.../stage_dest_evil
    sibling_dir = tmp_path / "stage_dest_evil"
    sibling_dir.mkdir()
    dest_dir = tmp_path / "stage_dest"
    dest_dir.mkdir()
    (dest_dir / "link").symlink_to(sibling_dir, target_is_directory=True)
    link_zip = tmp_path / "link_escape.zip"
    with zipfile.ZipFile(link_zip, "w") as zf_link:
        zf_link.writestr("link/payload.lua", "print('escaped')")
    with zipfile.ZipFile(link_zip, "r") as zf_link_read:
        with pytest.raises(ValueError, match="Zip extraction path escape or symlink blocked"):
            extract_zip_safely(zf_link_read, dest_dir)
    assert not (sibling_dir / "payload.lua").exists()


def test_sync_upstream_security_guards_path_traversal_zipslip_and_https(tmp_path: pathlib.Path) -> None:
    assert sanitize_zip_filename("GodJohnson-5.0.213.zip") == "GodJohnson-5.0.213.zip"
    for bad_name in ("../evil.zip", "..\\evil.zip", "/etc/passwd.zip", "payload.exe"):
        with pytest.raises(ValueError, match="Untrusted archive filename"):
            sanitize_zip_filename(bad_name)

    valid_url = "https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip"
    assert validate_https_download_url(valid_url) == valid_url
    for bad_url in ("http://mediafilez.forgecdn.net/files/1/2/a.zip", "https://evil.example.com/a.zip"):
        with pytest.raises(ValueError, match="Untrusted download URL"):
            validate_https_download_url(bad_url)

    slip_zip = tmp_path / "slip.zip"
    with zipfile.ZipFile(slip_zip, "w") as zf:
        zf.writestr("../escape.lua", "print(1)")
    with zipfile.ZipFile(slip_zip, "r") as zf_read:
        with pytest.raises(ValueError, match="Unsafe zip entry"):
            validate_zip_archive_safety(zf_read)

    _assert_safe_zip_extraction_and_sibling_escape(tmp_path)
    _assert_redirect_handler_security()
    _assert_ps1_security_helpers()


def test_forbidden_tooltip_guard_and_refundable_junk_skip_and_entry_pool_reuse() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    inv = ns["ModuleManager"]["modules"]["Inventory"]["definition"]
    util = ns["ModuleManager"]["modules"]["Utility"]["definition"]

    gt = rt.vm.G["GameTooltip"]
    gt["_lines"].clear()
    gt["IsForbidden"] = lambda *_a: True
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9001))
    assert len(gt["_lines"]) == 0
    gt["IsForbidden"] = lambda *_a: False

    rt.bags[0]["items"][1] = {"itemID": 9001, "quality": 0, "stackCount": 1, "isLocked": False, "isRefundable": True}
    rt.bags[0]["items"][2] = {"itemID": 9001, "quality": 0, "stackCount": 1, "isLocked": False, "isRefundable": False}
    rt.fire_event("MERCHANT_SHOW")
    assert len(rt.sold_bag_slots) == 1
    first_entry_ref = util["reusableSellEntryPool"][1]
    assert first_entry_ref is not None

    rt.bags[0]["items"][2] = {"itemID": 9001, "quality": 0, "stackCount": 2, "isLocked": False, "isRefundable": False}
    rt.fire_event("MERCHANT_SHOW")
    assert util["reusableSellEntryPool"][1] is first_entry_ref


def _make_wrapped_gj_zip(zip_path: pathlib.Path, prefixes: tuple[str, ...], version: str = "5.0.300") -> str:
    with zipfile.ZipFile(zip_path, "w") as zf:
        for prefix in prefixes:
            zf.writestr(f"{prefix}/GodJohnsonGoldBorder/GodJohnsonGoldBorder.toc", f"## Version: {version}\n")
            zf.writestr(f"{prefix}/GodJohnsonGoldBorder/CompanionCore.lua", "C.releaseRevision = 801\n")
    return hashlib.sha256(zip_path.read_bytes()).hexdigest().lower()


def test_v030_ac3_sync_upstream_patch_preservation_sha_guard_wrapper_unwrap_and_cleanup(
    tmp_path: pathlib.Path, capsys: pytest.CaptureFixture[str]
) -> None:
    from package_release import _cleanup_stale_release_zips
    from sync_upstream import (
        _build_arg_parser,
        _resolve_sync_targets,
        main as sync_main,
        resolve_default_extract_dir,
        verify_extracted_dir,
    )

    fake_repo = tmp_path / "repo"
    (fake_repo / "ForeverSuite_GJBridge").mkdir(parents=True)
    bridge_path = fake_repo / "ForeverSuite_GJBridge" / "Bridge.lua"
    bridge_path.write_text('ns.UPSTREAM_PIN = "5.0.213"\n', encoding="utf-8")
    pin_path = fake_repo / "pinned_upstream.json"
    pin_path.write_text(
        json.dumps(
            {
                "version": "5.0.213",
                "patch_zip_url": "https://raw.githubusercontent.com/ssacho3-blip/WoW-ForeverSuite/main/dist/ForeverSuite-v0.3.0.zip",
                "patch_zip_sha256": "f" * 64,
            }
        ),
        encoding="utf-8",
    )

    wrapped_zip = tmp_path / "GodJohnson-5.0.300.zip"
    wrapped_sha = _make_wrapped_gj_zip(wrapped_zip, ("GodJohnson-v5.0.300",))
    extract_dest = tmp_path / "gj_dest"

    with pytest.raises(ValueError, match="Upstream SHA-256 mismatch"):
        sync_upstream_zip(wrapped_zip, extract_dest, fake_repo, expected_sha256="0" * 64)
    assert not extract_dest.exists()
    assert json.loads(pin_path.read_text(encoding="utf-8"))["version"] == "5.0.213"
    assert 'ns.UPSTREAM_PIN = "5.0.213"' in bridge_path.read_text(encoding="utf-8")

    manifest = sync_upstream_zip(wrapped_zip, extract_dest, fake_repo, expected_sha256=wrapped_sha)
    assert manifest["version"] == "5.0.300"
    assert manifest["patch_zip_sha256"] == "f" * 64
    assert (extract_dest / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc").is_file()

    ambig_zip = tmp_path / "GodJohnson-5.0.301.zip"
    _make_wrapped_gj_zip(ambig_zip, ("WrapA", "WrapB"))
    with pytest.raises(ValueError, match="Ambiguous multiple top-level wrapper directories"):
        sync_upstream_zip(ambig_zip, tmp_path / "ambig_dest", fake_repo)

    assert sync_main(["--print-extract-dir"]) == 0
    printed_dir = capsys.readouterr().out.strip()
    assert printed_dir == str(resolve_default_extract_dir(REPO_ROOT))
    assert verify_extracted_dir(fake_repo, extract_dest) == 1
    ap = _build_arg_parser()
    resolved_zip, resolved_dest, _ = _resolve_sync_targets(ap.parse_args([str(wrapped_zip), str(extract_dest)]), fake_repo)
    assert resolved_zip == wrapped_zip.resolve() and resolved_dest == extract_dest.resolve()

    dist_dir = tmp_path / "dist"
    dist_dir.mkdir()
    for fname in ("ForeverSuite-v0.1.0.zip", "ForeverSuite-v0.2.0.zip", "ForeverSuite-v0.3.0.zip", "ForeverSuite_Offline_Installer.exe"):
        (dist_dir / fname).write_bytes(b"ok")
    removed = _cleanup_stale_release_zips(dist_dir, "ForeverSuite-v0.3.0.zip")
    assert removed == ["ForeverSuite-v0.1.0.zip", "ForeverSuite-v0.2.0.zip"]
    assert (dist_dir / "ForeverSuite-v0.3.0.zip").is_file()
    assert (dist_dir / "ForeverSuite_Offline_Installer.exe").is_file()

    ps1 = build_embedded_ps1_script(
        {
            "download_url": "https://mediafilez.forgecdn.net/files/9520/137/GodJohnson-5.0.213.zip",
            "zip_sha256": "a" * 64,
            "version": "5.0.213",
            "file_name": "GodJohnson-5.0.213.zip",
        },
        base64.b64encode(b"PK").decode("ascii"),
    )
    assert "(v0.3.0)" in ps1


def test_v030_codex_review_sync_recoverable_swap_and_empty_expected_sha256(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import os

    fake_repo = tmp_path / "repo"
    (fake_repo / "ForeverSuite_GJBridge").mkdir(parents=True)
    (fake_repo / "ForeverSuite_GJBridge" / "Bridge.lua").write_text('ns.UPSTREAM_PIN = "5.0.213"\n', encoding="utf-8")

    old_zip = tmp_path / "GodJohnson-5.0.213.zip"
    old_sha = _make_wrapped_gj_zip(old_zip, ("GodJohnson-v5.0.213",), version="5.0.213")
    new_zip = tmp_path / "GodJohnson-5.0.300.zip"
    new_sha = _make_wrapped_gj_zip(new_zip, ("GodJohnson-v5.0.300",), version="5.0.300")
    extract_dest = tmp_path / "gj_dest"

    # 1. Empty string expected_sha256="" must fail closed (must NOT coerce to None)
    with pytest.raises(ValueError, match="Upstream SHA-256 mismatch"):
        sync_upstream_zip(old_zip, extract_dest, fake_repo, expected_sha256="")
    assert not extract_dest.exists()

    # 2. Populate initial valid upstream tree
    sync_upstream_zip(old_zip, extract_dest, fake_repo, expected_sha256=old_sha)
    toc_file = extract_dest / "GodJohnsonGoldBorder" / "GodJohnsonGoldBorder.toc"
    assert "5.0.213" in toc_file.read_text(encoding="utf-8")

    # 3. Simulate failure when swapping staging_dir -> extract_dest; backup must restore 5.0.213
    real_replace = os.replace

    def flaky_replace(src: os.PathLike[str] | str, dst: os.PathLike[str] | str) -> None:
        src_p, dst_p = pathlib.Path(src), pathlib.Path(dst)
        if src_p.name.startswith(".gj_sync_stage_") and dst_p == extract_dest:
            raise OSError("simulated os.replace failure during stage swap")
        real_replace(src, dst)

    monkeypatch.setattr(os, "replace", flaky_replace)
    with pytest.raises(OSError, match="simulated os.replace failure"):
        sync_upstream_zip(new_zip, extract_dest, fake_repo, expected_sha256=new_sha)
    monkeypatch.setattr(os, "replace", real_replace)

    assert toc_file.is_file()
    assert "5.0.213" in toc_file.read_text(encoding="utf-8")

    # 3b. Invalid metadata (file_id) or unsafe TOC version (quote injection) must fail pre-swap
    with pytest.raises(ValueError):
        sync_upstream_zip(new_zip, extract_dest, fake_repo, release_meta={"file_id": "bad_id"}, expected_sha256=new_sha)
    bad_ver_zip = tmp_path / "custom_upstream.zip"
    bad_ver_sha = _make_wrapped_gj_zip(bad_ver_zip, ("GodJohnson-custom",), version='5.0."300')
    with pytest.raises(ValueError, match="Unsafe or malformed upstream version"):
        sync_upstream_zip(bad_ver_zip, extract_dest, fake_repo, expected_sha256=bad_ver_sha)
    assert "5.0.213" in toc_file.read_text(encoding="utf-8")
    assert json.loads((fake_repo / "pinned_upstream.json").read_text(encoding="utf-8"))["version"] == "5.0.213"

    # 3c. Failure during Bridge.lua write (after extract_dest + manifest write) must roll back ALL three
    import sync_upstream as su_mod

    real_write_text = su_mod._write_text_atomic

    def fail_on_bridge(path: pathlib.Path, content: str) -> None:
        if path.name == "Bridge.lua":
            raise OSError("simulated Bridge.lua write failure")
        real_write_text(path, content)

    monkeypatch.setattr(su_mod, "_write_text_atomic", fail_on_bridge)
    with pytest.raises(OSError, match="simulated Bridge.lua write failure"):
        sync_upstream_zip(new_zip, extract_dest, fake_repo, expected_sha256=new_sha)
    monkeypatch.setattr(su_mod, "_write_text_atomic", real_write_text)

    assert "5.0.213" in toc_file.read_text(encoding="utf-8")
    assert json.loads((fake_repo / "pinned_upstream.json").read_text(encoding="utf-8"))["version"] == "5.0.213"
    assert 'ns.UPSTREAM_PIN = "5.0.213"' in (fake_repo / "ForeverSuite_GJBridge" / "Bridge.lua").read_text(encoding="utf-8")

    # 4. Normal overwrite of existing extract_dest succeeds and cleans backup
    sync_upstream_zip(new_zip, extract_dest, fake_repo, expected_sha256=new_sha)
    assert "5.0.300" in toc_file.read_text(encoding="utf-8")
    leftover_baks = list(tmp_path.glob(".gj_sync_bak_*"))
    assert leftover_baks == []



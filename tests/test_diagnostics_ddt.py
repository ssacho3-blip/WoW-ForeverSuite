"""DDT tests for Phase 0 Diagnostics Taint Canary & GJBridge UsageCanary."""

from __future__ import annotations

import pathlib

from lua51_engine import LuaTable
from wow_forever_mock import SecretValue, WoWForeverMockRuntime

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"
BRIDGE_ROOT = REPO_ROOT / "ForeverSuite_GJBridge"


def _load_bridge(rt: WoWForeverMockRuntime) -> LuaTable:
    bridge_ns = LuaTable()
    toc_path = BRIDGE_ROOT / "ForeverSuite_GJBridge.toc"
    for raw_line in toc_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        lua_path = BRIDGE_ROOT / line.replace("\\", "/")
        rt.vm.run_chunk(lua_path.read_text(encoding="utf-8"), filename=lua_path.name, chunk_args=("ForeverSuite_GJBridge", bridge_ns))
    return bridge_ns


def test_phase0_taint_canary_records_blocked_forbidden_caps_ring_and_guards_secrets() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    diag = ns["Diagnostics"]

    # 1. Records ADDON_ACTION_BLOCKED & ADDON_ACTION_FORBIDDEN with combat state
    rt.combat_lockdown = True
    rt.fire_event("ADDON_ACTION_BLOCKED", "ForeverSuite", "Button:SetPassThroughButtons()")
    rt.fire_event("ADDON_ACTION_FORBIDDEN", "GodJohnsonGoldBorder", "Frame:Show()")

    store = rt.vm.G["ForeverSuiteDB"]["_diagnostics"]
    assert store["taintTotal"] == 2
    assert store["taintCounts"]["ForeverSuite:Button:SetPassThroughButtons()"] == 1
    assert store["taintCounts"]["GodJohnsonGoldBorder:Frame:Show()"] == 1
    assert diag["sessionBlocked"] == 1
    assert diag["sessionForbidden"] == 1
    assert store["taintRecent"][1]["inCombat"] is True

    # 2. Secret payloads never throw and degrade safely to UNKNOWN
    rt.fire_event("ADDON_ACTION_BLOCKED", SecretValue("secAddon"), SecretValue("secFn"))
    assert store["taintTotal"] == 3
    assert store["taintCounts"]["UNKNOWN_ADDON:UNKNOWN_FUNC"] == 1

    # 3. Ring buffer hard-caps recent events at 100
    for i in range(115):
        rt.fire_event("ADDON_ACTION_BLOCKED", "ForeverSuite", f"Fn{i}")
    recent = store["taintRecent"]
    assert len([k for k in recent.keys() if isinstance(k, int)]) == 100

    # 4. /fsdiag prints summary and /fsdiag reset clears counters
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITEDIAG", "")
    assert any("진단 카나리" in m for m in rt.chat_messages)
    rt.run_slash("FOREVERSUITEDIAG", "reset")
    assert store["taintTotal"] == 0
    assert diag["sessionBlocked"] == 0

    # 5. Read-only future schema profile blocks writes without throwing
    ns["ProfileManager"]["readOnly"] = True
    rt.fire_event("ADDON_ACTION_BLOCKED", "ForeverSuite", "NoWrite")
    assert store["taintTotal"] == 0
    assert diag["sessionBlocked"] == 1


def test_phase0_gj_usage_canary_hooks_readonly_without_mutating_gj_frames() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    create_frame = rt.vm.G["CreateFrame"]
    atlas_panel = create_frame("Frame", "GodJohnsonAtlasPanel", rt.vm.G["UIParent"])
    launcher = create_frame("Button", "GodJohnsonGoldBorderLauncher", rt.vm.G["UIParent"])
    atlas_keys_before = set(atlas_panel.keys())

    ns = rt.boot_session()
    _load_bridge(rt)
    rt.fire_event("PLAYER_LOGIN")
    # Second scan must be idempotent (no double-hook!)
    rt.fire_event("PLAYER_ENTERING_WORLD")

    # Zero custom fields mutated onto GJ frame itself (Zero-Taint invariant)
    assert set(atlas_panel.keys()) == atlas_keys_before

    # Showing tracked GJ panel increments usage count once per OnShow
    rt._fire_widget_script(atlas_panel, "OnShow")
    rt._fire_widget_script(atlas_panel, "OnShow")
    rt._fire_widget_script(launcher, "OnShow")

    gj_usage = rt.vm.G["ForeverSuiteDB"]["_diagnostics"]["gjUsage"]
    assert gj_usage["GodJohnsonAtlasPanel"]["count"] == 2
    assert "GodJohnsonGoldBorderLauncher" not in gj_usage
    assert rt.vm._invoke_callable(ns["Diagnostics"]["GetSummary"], (ns["Diagnostics"],))[0]["gjTrackedPanels"] == 1

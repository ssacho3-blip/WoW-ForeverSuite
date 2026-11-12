"""ATDD, BDD/DDT, Static Compliance, and Runtime Verification Suite for ForeverSuite (WOWF-20261101-001)."""

from __future__ import annotations

import pathlib
import re
import sys
import zipfile

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"
TESTS_DIR = REPO_ROOT / "tests"
SCRIPTS_DIR = REPO_ROOT / "scripts"

for p in (str(TESTS_DIR), str(SCRIPTS_DIR)):
    if p not in sys.path:
        sys.path.insert(0, p)

from binary_api_manifest import (  # noqa: E402
    FORBIDDEN_COMBAT_AUTOMATION_APIS,
    FORBIDDEN_LEGACY_APIS,
    extract_c_api_calls_from_lua,
    verify_symbols_in_local_binary,
)
from lua51_engine import Lua51VM, LuaSyntaxError, LuaTable, parse_lua51  # noqa: E402
from package_release import build_release_zip  # noqa: E402
from wow_forever_mock import (  # noqa: E402
    FailClosedUnknownAPIError,
    SecretValue,
    WoWForeverMockRuntime,
)


# ---------------------------------------------------------------------------
# 0. Lua 5.1 Engine Self-Verification & Fail-Closed Mock Self-Tests
# ---------------------------------------------------------------------------


def test_lua51_engine_semantics_and_52_rejection() -> None:
    vm = Lua51VM()
    out = vm.run_chunk(
        """
        local a, b = ...
        local count = 0
        local function bump(step)
            count = count + (step or 1)
            return count, a
        end
        local r1, r2 = bump(4)
        -- Strict Lua 5.1 xpcall does not forward varargs to fn
        local forwarded = "unset"
        xpcall(function(x) forwarded = x end, function(e) return e end, 99)
        return r1, r2, b, forwarded
        """,
        chunk_args=("ForeverSuite", 11701),
    )
    assert out == (4, "ForeverSuite", 11701, None)

    with pytest.raises(LuaSyntaxError):
        parse_lua51("local x = 10 // 3")
    with pytest.raises(LuaSyntaxError):
        parse_lua51("goto done")


def test_mock_fail_closed_blocks_unknown_c_api() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    with pytest.raises(FailClosedUnknownAPIError):
        rt.vm.run_chunk("return C_Container.NonExistentHallucinatedFunction()")


# ---------------------------------------------------------------------------
# 1. Static Lua 5.1 Syntax, Binary Symbol Verification & Blizzard Compliance
# ---------------------------------------------------------------------------


def _first_non_comment_line(src: str) -> str:
    for line in src.splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("--"):
            return stripped
    return ""


def _strip_comments(src: str) -> str:
    return "\n".join(line.split("--", 1)[0] for line in src.splitlines())


def _verify_single_lua_file_compliance(lua_file: pathlib.Path) -> set[str]:
    assert lua_file.is_file(), f"Missing file in TOC: {lua_file}"
    raw = lua_file.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM forbidden: {lua_file.name}"
    assert b"\r\n" not in raw, f"CRLF forbidden in Lua source: {lua_file.name}"

    src = raw.decode("utf-8")
    first_code_line = _first_non_comment_line(src)
    assert re.match(r"^local\s+[A-Za-z0-9_]+\s*,\s*ns\s*=\s*\.\.\.$", first_code_line), (
        f"{lua_file.name} must start with 'local ..., ns = ...'"
    )
    parse_lua51(src, filename=lua_file.name)

    code_no_comments = _strip_comments(src)
    code_without_c_namespaces = re.sub(r"\bC_[A-Za-z0-9_]+\.[A-Za-z0-9_]+\b", "", code_no_comments)
    tokens = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", code_without_c_namespaces))

    assert not (tokens & FORBIDDEN_LEGACY_APIS), f"{lua_file.name} uses removed legacy APIs"
    assert not (tokens & FORBIDDEN_COMBAT_AUTOMATION_APIS), f"{lua_file.name} uses forbidden combat APIs"
    assert "BAG_UPDATE" not in re.findall(r'"(BAG_UPDATE)"', code_no_comments)
    return extract_c_api_calls_from_lua(src)


def test_toc_and_all_lua_files_static_compliance() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    meta, files = rt.parse_toc_files()

    assert "11701" in meta["Interface"]
    assert meta["SavedVariables"] == "ForeverSuiteDB"
    assert meta["SavedVariablesPerCharacter"] == "ForeverSuiteCharDB"
    assert meta["AddonCompartmentFunc"] == "ForeverSuite_OnAddonCompartmentClick"
    assert len(files) == 15

    all_c_calls: set[str] = set()
    for lua_file in files:
        all_c_calls |= _verify_single_lua_file_compliance(lua_file)

    ok, missing = verify_symbols_in_local_binary(all_c_calls)
    assert ok, f"Unverified C_* symbols missing from WoW Forever 1.60.1 binary: {missing}"


# ---------------------------------------------------------------------------
# 2. AC-1: Load Integrity, /reload x3 Stability & Zero Global Leaks (_G diff)
# ---------------------------------------------------------------------------


def test_ac1_load_integrity_reload_3x_and_global_hygiene() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    assert ns["VERSION"] == "0.2.0"

    allowed_globals = {
        "ForeverSuite",
        "ForeverSuiteDB",
        "ForeverSuiteCharDB",
        "ForeverSuite_OnAddonCompartmentClick",
        "ForeverSuite_OnAddonCompartmentEnter",
        "ForeverSuite_OnAddonCompartmentLeave",
        "SLASH_FOREVERSUITE1",
        "SLASH_FOREVERSUITE2",
        "SLASH_FOREVERSUITEWAY1",
    }

    for _ in range(3):
        ns = rt.simulate_reload()
        leaked = rt.leaked_globals() - allowed_globals
        assert leaked == set(), f"Unexpected global variable leak in _G: {leaked}"

    # Verify /fs probe records ground-truth API report into ForeverSuiteDB.lastProbe
    rt.run_slash("FOREVERSUITE", "probe")
    probe = rt.vm.G["ForeverSuiteDB"]["lastProbe"]
    assert probe["version"] == "1.60.1"
    assert probe["build"] == "70707"
    assert probe["tocVersion"] == 11701
    assert probe["namespaces"]["C_Container"]["present"] is True


# ---------------------------------------------------------------------------
# 3. AC-2: Module Fault Isolation (3 errors / 60s -> FAULTED & Resource Reclaim)
# ---------------------------------------------------------------------------


def _find_settings_row_for_module(panel: LuaTable, module_name: str) -> LuaTable | None:
    for _, row in panel["rows"].items():
        if row["moduleName"] == module_name:
            return row
    return None


def test_ac2_fault_isolation_circuit_breaker_and_settings_display() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    mm = ns["ModuleManager"]

    # Inject a runtime fault into Quest module's QUEST_DETAIL listener
    quest_rec = rt.vm._invoke_callable(mm["GetModule"], (mm, "Quest"))[0]
    quest_def = quest_rec["definition"]

    def failing_handler(*_a):
        raise RuntimeError("Simulated Questie-bridge nil dereference")

    quest_def["OnQuestDetail"] = failing_handler
    # Re-enable Quest cleanly so ctx wraps the injected handler
    rt.vm._invoke_callable(mm["DisableModule"], (mm, "Quest"))
    rt.vm._invoke_callable(mm["EnableModule"], (mm, "Quest", True))

    for step in range(3):
        rt.now += 10.0
        rt.fire_event("QUEST_DETAIL")
        if step < 2:
            assert quest_rec["state"] == "ENABLED"

    # After 3rd error within 60s -> FAULTED, resources reclaimed, other modules still ENABLED!
    assert quest_rec["state"] == "FAULTED"
    assert "Simulated Questie-bridge nil dereference" in quest_rec["lastError"]
    assert "Quest" not in ns["EventBus"]["ownerRecords"]

    # Verify sibling module (Utility) continues dispatching cleanly without interference
    rt.loot_slots = [1, 2]
    rt.fire_event("LOOT_READY")
    assert rt.looted_slots == [2, 1]

    # Verify SettingsPanel displays FAULTED error summary
    rt.run_slash("FOREVERSUITE", "ui")
    quest_row = _find_settings_row_for_module(ns["SettingsPanel"], "Quest")
    assert quest_row is not None
    assert "오류 격리:" in quest_row["descLabel"]["_text"]
    assert "FAULTED" in quest_row["badgeLabel"]["_text"]


# ---------------------------------------------------------------------------
# 4. AC-3: Combat Lockdown Safety (Fishing Double-Click & CombatQueue Zero Block)
# ---------------------------------------------------------------------------


def test_ac3_combat_lockdown_safety_and_fishing_double_release() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()

    # Equip fishing pole out of combat -> sound boost activates & saves crash recovery ledger
    rt.equipped_items[16] = 6256
    rt.fire_event("PLAYER_EQUIPMENT_CHANGED", 16)
    assert rt.cvars["Sound_SFXVolume"] == "1.0"
    assert rt.vm.G["ForeverSuiteDB"]["pendingCVarRestores"]["Sound_SFXVolume"] == "0.5"

    # Double-right-click WorldFrame out of combat (dt = 0.20s)
    wf = rt.vm.G["WorldFrame"]
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    rt.now += 0.20
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    assert len(rt.override_bindings) == 1

    # Layer 1 release: 0.05s timer clears temporary override binding automatically
    rt.advance_time(0.06)
    assert len(rt.override_bindings) == 0

    # Re-trigger override binding, then immediately enter Combat Lockdown!
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    rt.now += 0.18
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    assert len(rt.override_bindings) == 1

    rt.combat_lockdown = True
    rt.fire_event("PLAYER_REGEN_DISABLED")
    # Zero ADDON_ACTION_BLOCKED! Protected clear is safely queued onto CombatQueue
    assert rt.addon_action_blocked_count == 0
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] >= 1

    # Leaving combat flushes CombatQueue and clears override binding cleanly
    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    assert rt.addon_action_blocked_count == 0
    assert len(rt.override_bindings) == 0
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] == 0


# ---------------------------------------------------------------------------
# 5. AC-4: C_Secrets / issecretvalue Guard Compliance
# ---------------------------------------------------------------------------


def test_ac4_secret_value_guard_in_combat_health_and_auras() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    combat_mod = ns["ModuleManager"]["modules"]["Combat"]["definition"]

    # Normal non-secret low health triggers banner
    rt.player_hp = 200
    rt.player_max_hp = 1000
    rt.fire_event("UNIT_HEALTH", "player")
    assert combat_mod["lastHealthStatus"] == "LOW"
    assert combat_mod["alertFrame"]["_shown"] is True

    # Inject SecretValue (traps any arithmetic/comparison/concat if unguarded!)
    rt.combat_lockdown = True
    rt.player_hp = SecretValue("UnitHealth:player")
    rt.fire_event("UNIT_HEALTH", "player")
    assert combat_mod["lastHealthStatus"] == "UNAVAILABLE"
    assert combat_mod["alertFrame"]["_shown"] is False


# ---------------------------------------------------------------------------
# 6. AC-5: Profile Hierarchy, Idempotent Migration, Future Read-Only & Crash CVar
# ---------------------------------------------------------------------------


def _assert_future_schema_readonly(pm_future: LuaTable, rt_future: WoWForeverMockRuntime) -> None:
    assert pm_future["readOnly"] is True
    assert rt_future.vm._invoke_callable(pm_future["CanWrite"], (pm_future,))[0] is False
    for scope in ("account", "class", "char"):
        ok_set, err_code = rt_future.vm._invoke_callable(pm_future["Set"], (pm_future, "utility", "maxSellBatch", 3, scope))
        assert ok_set is False
        assert err_code == "READ_ONLY"
    assert rt_future.vm._invoke_callable(pm_future["Get"], (pm_future, "utility", "maxSellBatch"))[0] == 12
    ok_mod, mod_code = rt_future.vm._invoke_callable(pm_future["SetModuleEnabled"], (pm_future, "Quest", False, "account"))
    assert ok_mod is False
    assert mod_code == "READ_ONLY"
    ok_prot, prot_code = rt_future.vm._invoke_callable(pm_future["SetProtectedItem"], (pm_future, 9001, True))
    assert ok_prot is False
    assert prot_code == "READ_ONLY"
    ok_qgrp, qgrp_code = rt_future.vm._invoke_callable(
        pm_future["SetQuestGroupCollapsed"], (pm_future, "zone:엘윈 숲", True)
    )
    assert ok_qgrp is False
    assert qgrp_code == "READ_ONLY"
    ok_qclr, qclr_code = rt_future.vm._invoke_callable(pm_future["ClearCollapsedQuestGroups"], (pm_future,))
    assert ok_qclr is False
    assert qclr_code == "READ_ONLY"


def test_ac5_profile_hierarchy_migration_readonly_and_crash_cvar() -> None:
    # A. v1 -> v2 migration + _backup preservation + idempotency + crash CVar recovery
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_class = "PRIEST"
    rt.cvars["Sound_SFXVolume"] = "1.0"  # Stuck boosted volume after simulated crash
    rt.vm.G["ForeverSuiteDB"] = LuaTable(
        {
            "schemaVersion": 1,
            "settings": LuaTable({"utility": LuaTable({"autoRepair": False})}),
            "modules": LuaTable({"Combat": LuaTable({"enabled": False})}),
            "pendingCVarRestores": LuaTable({"Sound_SFXVolume": "0.45"}),
        }
    )
    ns = rt.boot_session()
    pm = ns["ProfileManager"]
    db = rt.vm.G["ForeverSuiteDB"]

    assert db["schemaVersion"] == 2
    assert db["_backup"][1] is not None
    assert rt.cvars["Sound_SFXVolume"] == "0.45"  # Restored automatically after crash!
    assert rt.vm._invoke_callable(pm["Get"], (pm, "utility", "autoRepair"))[0] is False

    # Character > Class > Account > Default precedence
    rt.vm._invoke_callable(pm["Set"], (pm, "utility", "maxSellBatch", 10, "account"))
    rt.vm._invoke_callable(pm["Set"], (pm, "utility", "maxSellBatch", 8, "class"))
    assert rt.vm._invoke_callable(pm["Get"], (pm, "utility", "maxSellBatch"))[0] == 8
    rt.vm._invoke_callable(pm["Set"], (pm, "utility", "maxSellBatch", 5, "char"))
    assert rt.vm._invoke_callable(pm["Get"], (pm, "utility", "maxSellBatch"))[0] == 5

    # Idempotent re-init check
    ns2 = rt.simulate_reload()
    assert rt.vm.G["ForeverSuiteDB"]["schemaVersion"] == 2
    assert rt.vm._invoke_callable(ns2["ProfileManager"]["Get"], (ns2["ProfileManager"], "utility", "maxSellBatch"))[0] == 5

    # B. Future schemaVersion (v99) -> strict Read-Only mode without mutating DB or session state (B-01)
    rt_future = WoWForeverMockRuntime(ADDON_ROOT)
    future_db = LuaTable({"schemaVersion": 99, "futureField": "preserve_me"})
    rt_future.vm.G["ForeverSuiteDB"] = future_db
    ns_future = rt_future.boot_session()
    _assert_future_schema_readonly(ns_future["ProfileManager"], rt_future)
    assert rt_future.vm.G["ForeverSuiteDB"]["schemaVersion"] == 99
    assert rt_future.vm.G["ForeverSuiteDB"]["futureField"] == "preserve_me"

    # C. Corrupted non-table DB -> backup & clean default recovery
    rt_corrupt = WoWForeverMockRuntime(ADDON_ROOT)
    rt_corrupt.vm.G["ForeverSuiteDB"] = "corrupted_payload"
    ns_corrupt = rt_corrupt.boot_session()
    assert ns_corrupt["ProfileManager"]["corruptedRecovered"] is True
    assert rt_corrupt.vm.G["ForeverSuiteDB"]["_corruptedBackup"] == "corrupted_payload"


# ---------------------------------------------------------------------------
# 7. AC-6: Economic Safety (12-Item Cap, Protected Item, Repair Fallback, Ledger)
# ---------------------------------------------------------------------------


def _make_bag_test_item(idx: int) -> dict[str, object]:
    if idx < 20:
        return {"itemID": 9001, "quality": 0, "stackCount": 1, "isLocked": False}
    if idx == 20:
        return {"itemID": 9099, "quality": 0, "stackCount": 1, "isLocked": False}
    if idx == 21:
        return {"itemID": 9002, "quality": 0, "stackCount": 1, "isLocked": True}
    return {"itemID": 2001, "quality": 2, "stackCount": 1, "isLocked": False}


def _populate_test_bags(rt: WoWForeverMockRuntime) -> None:
    for idx in range(23):
        bag_cursor = idx // 16
        slot_cursor = (idx % 16) + 1
        rt.bags[bag_cursor]["items"][slot_cursor] = _make_bag_test_item(idx)


def _collect_remaining_item_ids(rt: WoWForeverMockRuntime) -> set[int]:
    remaining: set[int] = set()
    for bag in rt.bags.values():
        for item in bag["items"].values():
            remaining.add(int(item["itemID"]))
    return remaining


def test_ac6_economic_safety_buyback_cap_repair_fallback_and_ledger() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    pm = ns["ProfileManager"]
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    # Protect item 9099
    rt.vm._invoke_callable(pm["SetProtectedItem"], (pm, 9099, True))
    _populate_test_bags(rt)

    initial_money = rt.player_money

    # Shift held -> 0 items sold, 0 repairs
    rt.shift_down = True
    rt.repair_cost = 1500
    rt.fire_event("MERCHANT_SHOW")
    assert len(rt.sold_bag_slots) == 0
    assert len(rt.repair_calls) == 0
    rt.fire_event("MERCHANT_CLOSED")

    # Release Shift; guild funds insufficient -> falls back to personal gold; sells max 12 items!
    rt.shift_down = False
    rt.can_guild_repair = True
    rt.guild_withdraw_limit = 500  # Less than 1500 repair_cost
    rt.guild_bank_money = 500
    rt.fire_event("MERCHANT_SHOW")

    assert rt.repair_calls == [False]  # Personal gold fallback
    assert len(rt.sold_bag_slots) == 12  # Hard buyback cap <= 12!

    # Protected item 9099, locked item 9002, and uncommon item 2001 remain untouched in bag 1
    remaining_ids = _collect_remaining_item_ids(rt)
    assert {9099, 9002, 2001}.issubset(remaining_ids)

    # Simulate an unclassified mail/trade gold change -> recorded as 'other'
    rt.player_money += 777
    rt.fire_event("PLAYER_MONEY")

    # Insufficient personal gold -> does NOT repair
    rt.repair_cost = 999_999_999
    rt.fire_event("MERCHANT_SHOW")
    assert len(rt.repair_calls) == 1  # Unchanged

    net_ledger = rt.vm._invoke_callable(econ["GetNetDelta"], (econ,))[0]
    assert net_ledger == (rt.player_money - initial_money)
    assert econ["ledger"]["other"] == 777


# ---------------------------------------------------------------------------
# 8. AC-7: External Addon Coexistence (YIELDED), Zero Idle Ticker & /way Guard
# ---------------------------------------------------------------------------


def test_ac7_coexistence_yield_zero_idle_tickers_and_waypoint_guard() -> None:
    # A. Coexistence: Baganator, Questie, TomTom, Auctionator pre-loaded -> YIELDED with 0 hooks
    rt_co = WoWForeverMockRuntime(ADDON_ROOT)
    rt_co.loaded_external_addons = {"Baganator", "Questie", "TomTom", "Auctionator"}
    ns_co = rt_co.boot_session()
    mm_co = ns_co["ModuleManager"]

    for mod_name in ("Inventory", "Quest", "Map", "Economy"):
        rec = mm_co["modules"][mod_name]
        assert rec["state"] == "YIELDED", f"{mod_name} must yield to external addon"
        assert mod_name not in ns_co["EventBus"]["ownerRecords"], f"{mod_name} must register 0 event hooks"

    # B. Standalone Performance & Map /way Behavior
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.profiler_enabled = False
    ns = rt.boot_session()
    mm = ns["ModuleManager"]

    # Idle ticker count MUST be 0 when WorldMapFrame is closed!
    assert rt.vm._invoke_callable(mm["TotalActiveTickers"], (mm,))[0] == 0

    # Open WorldMapFrame -> starts 0.15s ticker; instance nil position -> '플레이어: —'; close -> 0 tickers
    wmf = rt.vm.G["WorldMapFrame"]
    rt.vm._invoke_callable(wmf["Show"], (wmf,))
    assert rt.vm._invoke_callable(mm["TotalActiveTickers"], (mm,))[0] == 1
    assert "42.5, 65.2" in mm["modules"]["Map"]["definition"]["lastCoordText"]

    rt.player_pos = None  # Inside dungeon instance
    rt.advance_time(0.16)
    assert mm["modules"]["Map"]["definition"]["lastCoordText"] == "플레이어: —"

    rt.vm._invoke_callable(wmf["Hide"], (wmf,))
    assert rt.vm._invoke_callable(mm["TotalActiveTickers"], (mm,))[0] == 0

    # Zero Fabricated Status: profiler disabled -> displays '측정 불가'
    perf_str = rt.vm._invoke_callable(ns["SettingsPanel"]["QueryPerformanceText"], (ns["SettingsPanel"],))[0]
    assert "평균 CPU: 측정 불가" in perf_str

    # /way guard when CanSetUserWaypointOnMap == False
    rt.can_set_waypoint = False
    rt.run_slash("FOREVERSUITEWAY", "55.2 41.8 광맥")
    assert rt.user_waypoint is None

    # /way on valid outdoor map -> sets waypoint + enables SuperTrack
    rt.can_set_waypoint = True
    rt.run_slash("FOREVERSUITEWAY", "55.2 41.8 광맥")
    assert rt.user_waypoint is not None
    assert rt.super_tracked_waypoint is True


# ---------------------------------------------------------------------------
# 9. Cross-Platform (Windows + macOS) Release Package Verification
# ---------------------------------------------------------------------------


def test_cross_platform_zip_packaging_lf_and_posix_paths(tmp_path: pathlib.Path) -> None:
    zip_out = build_release_zip(REPO_ROOT, version="0.1.0", out_dir=tmp_path)
    assert zip_out.is_file()
    with zipfile.ZipFile(zip_out, "r") as zf:
        names = zf.namelist()
        assert "ForeverSuite/ForeverSuite.toc" in names
        assert "ForeverSuite/Core/Init.lua" in names
        for name in names:
            assert "\\" not in name
            data = zf.read(name)
            assert b"\r\n" not in data
            assert not data.startswith(b"\xef\xbb\xbf")


def test_eventbus_reentrancy_and_money_reason_ttl() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    # Guild repair must not leave stale PendingMoneyReason
    rt.can_guild_repair = True
    rt.guild_withdraw_limit = 5000
    rt.guild_bank_money = 5000
    rt.repair_cost = 1200
    rt.fire_event("MERCHANT_SHOW")
    assert rt.repair_calls == [True]
    assert ns["PendingMoneyReason"] is None

    # Stale PendingMoneyReason (> 2.0s) must expire and record under 'other'
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("QUEST",))
    rt.now += 5.0
    rt.player_money += 350
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["quest"] == 0
    assert econ["ledger"]["other"] == 350


# ---------------------------------------------------------------------------
# 10. Post-Review Regression Tests (Tombstone Dispatch, Secret Item/Tooltip,
#     Combat Fishing Override Deferral, Named Frame Reuse, Batch Money Queue)
# ---------------------------------------------------------------------------


def test_eventbus_mid_dispatch_unregister_does_not_skip_next_listener() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    eb = ns["EventBus"]

    called: list[str] = []

    def handler_a(_ev: str, *_a: object) -> None:
        called.append("A")
        rt.vm._invoke_callable(eb["UnregisterOwner"], (eb, "OwnerA"))

    def handler_b(_ev: str, *_a: object) -> None:
        called.append("B")

    rt.vm._invoke_callable(eb["RegisterEvent"], (eb, "OwnerA", "CUSTOM_TEST_EVENT", handler_a))
    rt.vm._invoke_callable(eb["RegisterEvent"], (eb, "OwnerB", "CUSTOM_TEST_EVENT", handler_b))

    rt.fire_event("CUSTOM_TEST_EVENT")
    assert called == ["A", "B"], "Unregistering OwnerA mid-dispatch must NOT skip OwnerB"

    called.clear()
    rt.fire_event("CUSTOM_TEST_EVENT")
    assert called == ["B"], "OwnerA tombstone must be swept cleanly after outer dispatch"


def test_secret_values_in_utility_sell_repair_and_inventory_tooltip() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()

    # Verify type(SecretValue) == 'number' in Lua VM (real WoW C_Secrets semantics)
    assert rt.vm.G["type"](SecretValue("hp")) == "number"

    # Secret sellPrice & guild bank values must degrade gracefully without SecretValueViolationError
    rt.item_db[9888] = (
        "비밀 유물",
        "|Hitem:9888|h[비밀 유물]|h",
        0,
        SecretValue("ilvl"),
        1,
        "기타",
        "잡동사니",
        1,
        "",
        134000,
        SecretValue("sellPrice"),
        15,
        0,
    )
    rt.bags[0]["items"][1] = {"itemID": 9888, "quality": 0, "stackCount": SecretValue("stack"), "isLocked": False}
    rt.can_guild_repair = True
    rt.guild_withdraw_limit = SecretValue("guildWithdraw")  # type: ignore[assignment]
    rt.guild_bank_money = SecretValue("guildBank")  # type: ignore[assignment]
    rt.repair_cost = 400

    # Merchant open: guild secret falls back to personal gold repair; secret-priced junk skipped safely
    rt.fire_event("MERCHANT_SHOW")
    assert rt.repair_calls == [False]
    assert len(rt.sold_bag_slots) == 0

    # Tooltip enrichment on secret item level & secret sellPrice -> renders '—' without crash
    inv = ns["ModuleManager"]["modules"]["Inventory"]["definition"]
    gt = rt.vm.G["GameTooltip"]
    gt["_lines"].clear()
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9888))
    assert any("—" in line for line in gt["_lines"])


def test_profession_fishing_override_entered_combat_within_50ms_defers_clear() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.equipped_items[16] = 6256  # Fishing Pole equipped
    ns = rt.boot_session()
    prof = ns["ModuleManager"]["modules"]["Profession"]["definition"]

    wf = rt.vm.G["WorldFrame"]
    # Double right-click out of combat -> sets BUTTON2 override binding and schedules 0.05s clear
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    rt.advance_time(0.12)
    rt._fire_widget_script(wf, "OnMouseDown", "RightButton")
    assert prof["overrideActive"] is True
    assert len(rt.override_bindings) == 1

    # Player gets aggro 0.02s later BEFORE 0.05s timer expires!
    rt.combat_lockdown = True
    rt.advance_time(0.06)  # 0.05s timer fires WHILE InCombatLockdown() == True

    assert rt.addon_action_blocked_count == 0, "Must never call ClearOverrideBindings during InCombatLockdown"
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] >= 1

    # Combat ends -> CombatQueue flushes and clears override binding cleanly
    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    assert rt.addon_action_blocked_count == 0
    assert prof["overrideActive"] is False
    assert len(rt.override_bindings) == 0


def _count_matching_named_frames(rt: WoWForeverMockRuntime, names: set[str]) -> int:
    total = 0
    for f in rt.frames:
        if f["_name"] in names:
            total += 1
    return total


def _toggle_core_ui_modules_once(rt: WoWForeverMockRuntime, mm: LuaTable) -> None:
    for mod_name in ("Inventory", "Map", "Quest", "Combat"):
        rt.vm._invoke_callable(mm["DisableModule"], (mm, mod_name))
        assert rt.vm._invoke_callable(mm["EnableModule"], (mm, mod_name, True))[0] is True


def test_module_disable_enable_reuses_named_frames_and_batch_money_reasons() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    mm = ns["ModuleManager"]
    econ = mm["modules"]["Economy"]["definition"]
    target_names = {
        "ForeverSuiteBagHUD",
        "ForeverSuiteMapCoordHolder",
        "ForeverSuiteQuestTracker",
        "ForeverSuiteHealthAlertFrame",
    }

    assert _count_matching_named_frames(rt, target_names) == 4

    # Toggle Disable -> Enable 4 times; named frames must be reused 100% with 0 duplicates
    for _ in range(4):
        _toggle_core_ui_modules_once(rt, mm)

    assert _count_matching_named_frames(rt, target_names) == 4

    # Simultaneous personal repair (-800c) + 5 junk items sold (+125c * 5 = +625c) in single MERCHANT_SHOW
    for slot_idx in range(1, 6):
        rt.bags[0]["items"][slot_idx] = {"itemID": 9001, "quality": 0, "stackCount": 1, "isLocked": False}
    rt.repair_cost = 800
    rt.can_guild_repair = False
    rt.fire_event("MERCHANT_SHOW")

    assert econ["ledger"]["repair"] == -800
    assert econ["ledger"]["vendorSell"] == 5 * 125
    assert econ["ledger"]["other"] == 0


def test_pending_money_reason_expired_not_consumed_and_same_sign_no_cross_consume() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    # 1. Expired 1.5s TTL entry at t+1.7s MUST NOT be consumed (must NOT leak up to 2.0s!)
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 125))
    rt.now += 1.7
    rt.player_money += 850
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["vendorSell"] == 0
    assert econ["ledger"]["other"] == 850

    # 2. Same-sign VENDOR_SELL (+125) and QUEST (+900) queued concurrently MUST NOT cross-consume!
    rt.vm._invoke_callable(ns["ClearPendingMoneyReasons"], ())
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 125))
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("QUEST", 1.5, 1, 900))

    # Quest reward arrives first (+900) -> attributes strictly to QUEST, leaving VENDOR_SELL (+125) intact
    rt.player_money += 900
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["quest"] == 900
    assert econ["ledger"]["vendorSell"] == 0

    # Vendor sale arrives second (+125) -> attributes strictly to VENDOR_SELL
    rt.player_money += 125
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["vendorSell"] == 125

    # 3. Coalesced server batch: 3x VENDOR_SELL (+100, +150, +250) arriving as one +500 PLAYER_MONEY event
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 100))
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 150))
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 250))
    rt.player_money += 500
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["vendorSell"] == 125 + 500


def test_economy_first_event_after_enable_is_attributed_and_readonly_preserves_pending_cvar() -> None:
    # A. Economy Disable/Enable & trackSessionGold pause/resume MUST attribute the very first transaction after resume!
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    mm = ns["ModuleManager"]
    pm = ns["ProfileManager"]
    econ = mm["modules"]["Economy"]["definition"]

    # Pause via trackSessionGold=False, earn +400 untracked, then re-enable trackSessionGold=True
    rt.vm._invoke_callable(pm["Set"], (pm, "economy", "trackSessionGold", False, "account"))
    rt.player_money += 400
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["other"] == 0

    rt.vm._invoke_callable(pm["Set"], (pm, "economy", "trackSessionGold", True, "account"))
    # Immediately sell an item for +250c: first event MUST be attributed (not swallowed!)
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 1.5, 1, 250))
    rt.player_money += 250
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["vendorSell"] == 250
    assert econ["ledger"]["other"] == 0

    # Also test ModuleManager DisableModule -> money change -> EnableModule -> first event attributed!
    rt.vm._invoke_callable(mm["DisableModule"], (mm, "Economy"))
    rt.player_money += 1000
    rt.vm._invoke_callable(mm["EnableModule"], (mm, "Economy", True))
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("QUEST", 1.5, 1, 600))
    rt.player_money += 600
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["quest"] == 600
    assert econ["ledger"]["vendorSell"] == 250  # Prior session ledger preserved across toggle!

    # B. Read-Only future schema MUST NOT mutate or execute pendingCVarRestores
    rt_ro = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ro.cvars["Sound_SFXVolume"] = "0.9"
    rt_ro.vm.G["ForeverSuiteDB"] = LuaTable(
        {
            "schemaVersion": 99,
            "pendingCVarRestores": LuaTable({"Sound_SFXVolume": "0.3"}),
        }
    )
    ns_ro = rt_ro.boot_session()
    assert ns_ro["ProfileManager"]["readOnly"] is True
    assert rt_ro.cvars["Sound_SFXVolume"] == "0.9"
    assert rt_ro.vm.G["ForeverSuiteDB"]["pendingCVarRestores"]["Sound_SFXVolume"] == "0.3"

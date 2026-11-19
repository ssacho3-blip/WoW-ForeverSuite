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


def _node_name(node: object) -> str | None:
    if isinstance(node, tuple) and len(node) >= 2 and node[0] == "var" and isinstance(node[1], str):
        return node[1]
    return None


def _call_name(node: object) -> str | None:
    if isinstance(node, tuple) and node and node[0] == "call":
        return _node_name(node[1])
    return None


def _unwrap_paren(expr: object) -> object:
    while isinstance(expr, tuple) and expr and expr[0] == "paren":
        expr = expr[1]
    return expr


def _is_api(node: object, name: str) -> bool:
    node = _unwrap_paren(node)
    if _node_name(node) == name:
        return True
    return (
        isinstance(node, tuple)
        and node[0] == "index"
        and _node_name(node[1]) == "_G"
        and len(node) >= 3
        and node[2] == ("lit", name)
    )


def _is_call_api(node: object, name: str) -> bool:
    return isinstance(node, tuple) and bool(node) and node[0] == "call" and _is_api(node[1], name)


def _expr_uses_build(expr: object, tainted: set[str]) -> bool:
    if isinstance(expr, list):
        return any(_expr_uses_build(item, tainted) for item in expr)
    if not isinstance(expr, tuple) or not expr:
        return False
    if expr[0] == "var" and isinstance(expr[1], str) and expr[1] in tainted:
        return True
    if _is_call_api(expr, "GetBuildInfo"):
        return True
    return any(_expr_uses_build(child, tainted) for child in expr[1:])


def _is_positive_sendchat_guard(cond: object) -> bool:
    cond = _unwrap_paren(cond)
    if isinstance(cond, tuple) and cond and cond[0] == "unop" and cond[1] == "not":
        return False
    return _is_api(cond, "SendChatMessage") or "SendChatMessage" in _expr_names(cond) and not (
        isinstance(cond, tuple) and cond[0] == "unop"
    )


def _expr_names(expr: object) -> set[str]:
    found: set[str] = set()
    if isinstance(expr, list):
        for item in expr:
            found |= _expr_names(item)
        return found
    if isinstance(expr, tuple) and expr:
        if expr[0] == "var" and isinstance(expr[1], str):
            found.add(expr[1])
        for child in expr[1:]:
            found |= _expr_names(child)
    return found


def _mark_assign(names: object, exprs: object, tainted: set[str]) -> None:
    if not isinstance(names, list):
        return
    values = exprs if isinstance(exprs, list) else []
    for idx, name in enumerate(names):
        if not isinstance(name, str):
            continue
        expr = values[idx] if idx < len(values) else None
        if expr is not None and _expr_uses_build(expr, tainted):
            tainted.add(name)
        else:
            tainted.discard(name)


def _lua_issue(node: object, tainted: set[str], guarded: bool) -> str | None:
    if isinstance(node, list):
        for item in node:
            found = _lua_issue(item, tainted, guarded)
            if found:
                return found
        return None
    if not isinstance(node, tuple) or not node or not isinstance(node[0], str):
        return None
    kind = node[0]
    if kind in ("local", "assign") and len(node) >= 3:
        _mark_assign(node[1], node[2], tainted)
    if kind == "binop" and len(node) >= 4 and node[1] == ">=" and node[3] == ("lit", 100000):
        if _expr_uses_build(node[2], tainted):
            return "build"
    if kind == "expr_stat" and _is_call_api(node[1], "SendChatMessage") and not guarded:
        return "chat"
    if kind == "if" and len(node) >= 2:
        clauses = node[1] if isinstance(node[1], list) else []
        for clause in clauses:
            if isinstance(clause, tuple) and len(clause) >= 2:
                cond, body = clause[0], clause[1]
                found = _lua_issue(cond, tainted, guarded)
                if found:
                    return found
                found = _lua_issue(body, tainted, guarded or _is_positive_sendchat_guard(cond))
                if found:
                    return found
        else_body = node[2] if len(node) > 2 else None
        if else_body is not None:
            return _lua_issue(else_body, tainted, guarded)
        return None
    for child in node[1:]:
        found = _lua_issue(child, tainted, guarded)
        if found:
            return found
    return None


def _lua_static_issue(code: str) -> str | None:
    src = code if code.lstrip().startswith("local ") else "local _, ns = ...\n" + code
    tree = parse_lua51(src, "fixture.lua")
    return _lua_issue(tree, set(), False)


def _has_unguarded_sendchat(code: str) -> bool:
    return _lua_static_issue("local _, ns = ...\n" + code) == "chat"


def _has_build_version_trap(code: str) -> bool:
    return _lua_static_issue("local _, ns = ...\n" + code) == "build"


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
    code_without_c_namespaces = re.sub(
        r'\bC_[A-Za-z0-9_]+\.[A-Za-z0-9_]+\b|\b(?:_G\.)?C_[A-Za-z0-9_]+\s*,\s*"[A-Za-z0-9_]+"',
        "",
        code_no_comments,
    )
    tokens = set(re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", code_without_c_namespaces))

    assert not (tokens & FORBIDDEN_LEGACY_APIS), f"{lua_file.name} uses removed legacy APIs"
    assert not (tokens & FORBIDDEN_COMBAT_AUTOMATION_APIS), f"{lua_file.name} uses forbidden combat APIs"
    assert not (tokens & {"GetFrameStrata", "WOW_PROJECT_CLASSIC"}), (
        f"{lua_file.name} uses restricted Forever 1.60.1 API (forever-lint parity)"
    )
    issue = _lua_issue(parse_lua51(src, lua_file.name), set(), False)
    assert issue != "chat", f"{lua_file.name} calls SendChatMessage without a capability guard"
    assert issue != "build", f"{lua_file.name} uses >=100000 GetBuildInfo version trap"
    assert "BAG_UPDATE" not in re.findall(r'"(BAG_UPDATE)"', code_no_comments)
    return extract_c_api_calls_from_lua(src)


def test_toc_and_all_lua_files_static_compliance() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    meta, files = rt.parse_toc_files()

    assert "16001" in meta["Interface"]
    assert "120105" in meta["Interface"]
    assert meta["SavedVariables"] == "ForeverSuiteDB"
    assert meta["SavedVariablesPerCharacter"] == "ForeverSuiteCharDB"
    assert meta["AddonCompartmentFunc"] == "ForeverSuite_OnAddonCompartmentClick"
    assert len(files) == 18

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
    assert ns["VERSION"] == "0.3.6"

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
    assert probe["build"] == "70938"
    assert probe["tocVersion"] == 16001
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
    # A. Coexistence: Questie, Auctionator, Leatrix_Plus -> YIELDED; TomTom & Baganator -> FeatureYield only
    rt_co = WoWForeverMockRuntime(ADDON_ROOT)
    rt_co.loaded_external_addons = {"Baganator", "Questie", "TomTom", "Auctionator", "Leatrix_Plus"}
    ns_co = rt_co.boot_session()
    mm_co = ns_co["ModuleManager"]

    for mod_name in ("Quest", "Economy", "Utility"):
        rec = mm_co["modules"][mod_name]
        assert rec["state"] == "YIELDED", f"{mod_name} must yield to external addon"
        assert mod_name not in ns_co["EventBus"]["ownerRecords"], f"{mod_name} must register 0 event hooks"

    assert mm_co["modules"]["Map"]["state"] == "ENABLED"
    assert mm_co["modules"]["Inventory"]["state"] == "ENABLED"
    assert rt_co.vm._invoke_callable(ns_co["IsFeatureYielded"], ("way",))[0] is True
    assert rt_co.vm._invoke_callable(ns_co["IsFeatureYielded"], ("bagHud",))[0] is True
    assert ns_co["ModuleManager"]["modules"]["Map"]["definition"]["wayOwned"] is not True
    assert rt_co.vm.G["ForeverSuiteBagHUD"]["_shown"] is False

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


# ---------------------------------------------------------------------------
# 11. v0.3.0 Full-Upgrade ATDD/DDT Suite (AC-1, AC-4, AC-5, AC-6, AC-8)
# ---------------------------------------------------------------------------


def _lua_table_string_keys(tbl: LuaTable) -> set[str]:
    return {str(k) for k, v in tbl.items() if v is True}


def _count_special_frame_occurrences(rt: WoWForeverMockRuntime, frame_name: str) -> int:
    specials = rt.vm.G["UISpecialFrames"]
    count = 0
    idx = 1
    while specials.get(idx) is not None:
        if specials.get(idx) == frame_name:
            count += 1
        idx += 1
    return count


def _assert_v030_ac1_readonly_ui_rollback() -> None:
    rt_ro = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ro.vm.G["ForeverSuiteDB"] = LuaTable({"schemaVersion": 999})
    ns_ro = rt_ro.boot_session()
    sp_ro = ns_ro["SettingsPanel"]
    rt_ro.run_slash("FOREVERSUITE", "ui")

    for cmd in ("enable Quest", "disable Quest", "protect 9001", "move"):
        rt_ro.chat_messages.clear()
        rt_ro.run_slash("FOREVERSUITE", cmd)
        assert len(rt_ro.chat_messages) == 1
        assert "읽기 전용 프로필" in rt_ro.chat_messages[0]

    q_row = _find_settings_row_for_module(sp_ro, "Quest")
    assert q_row is not None
    mod_chk = q_row["checkbox"]
    assert rt_ro.vm._invoke_callable(mod_chk["GetChecked"], (mod_chk,))[0] is True
    rt_ro._fire_widget_script(mod_chk, "OnClick", "LeftButton")
    assert rt_ro.vm._invoke_callable(mod_chk["GetChecked"], (mod_chk,))[0] is True

    opt_chk = sp_ro["drawerCheckboxes"][1]
    before_opt = rt_ro.vm._invoke_callable(opt_chk["GetChecked"], (opt_chk,))[0]
    rt_ro._fire_widget_script(opt_chk, "OnClick", "LeftButton")
    assert rt_ro.vm._invoke_callable(opt_chk["GetChecked"], (opt_chk,))[0] is before_opt


def test_v030_ac1_settings_panel_esc_idempotency_tabs_drawer_and_readonly_rollback() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    sp = ns["SettingsPanel"]
    pm = ns["ProfileManager"]

    for _ in range(5):
        rt.run_slash("FOREVERSUITE", "ui")
    assert _count_special_frame_occurrences(rt, "ForeverSuiteSettingsFrame") == 1
    assert "v0.3.6 · 1.60.1 (16001)" in sp["titleLabel"]["_text"]

    drawer_keys = _lua_table_string_keys(rt.vm._invoke_callable(sp["GetDrawerBooleanKeySet"], (sp,))[0])
    profile_keys = _lua_table_string_keys(rt.vm._invoke_callable(pm["GetConfigurableBooleanKeys"], (pm,))[0])
    assert drawer_keys == profile_keys

    for active_key in ("modules", "bridge", "ledger"):
        rt.vm._invoke_callable(sp["SelectTab"], (sp, active_key))
        shown_tabs = [k for k in ("modules", "bridge", "ledger") if sp["tabPanels"][k]["_shown"]]
        assert shown_tabs == [active_key]

    rt.vm._invoke_callable(sp["SelectTab"], (sp, "modules"))
    rt.vm._invoke_callable(sp["SelectDetailModule"], (sp, "Utility"))
    first_opt = sp["drawerCheckboxes"][1]
    assert first_opt["_fsSpec"]["key"] == "autoRepair"
    rt._fire_widget_script(first_opt, "OnClick", "LeftButton")
    assert rt.vm._invoke_callable(pm["Get"], (pm, "utility", "autoRepair"))[0] is False

    ns2 = rt.simulate_reload()
    rt.run_slash("FOREVERSUITE", "ui")
    assert _count_special_frame_occurrences(rt, "ForeverSuiteSettingsFrame") == 1
    assert rt.vm._invoke_callable(ns2["ProfileManager"]["Get"], (ns2["ProfileManager"], "utility", "autoRepair"))[0] is False
    _assert_v030_ac1_readonly_ui_rollback()


def test_v030_ac4_module_contract_headers_and_ui_line_budget() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _, toc_files = rt.parse_toc_files()
    assert len(toc_files) == 18

    required_headers = ("-- Responsibility:", "-- Dependencies:", "-- Public API:", "-- Combat/Secret Safety:")
    for lua_path in toc_files:
        head = "\n".join(lua_path.read_text(encoding="utf-8").splitlines()[:10])
        for marker in required_headers:
            assert marker in head, f"{lua_path.name} missing contract header marker {marker}"

    for ui_file in sorted((ADDON_ROOT / "UI").glob("*.lua")):
        line_count = len(ui_file.read_text(encoding="utf-8").splitlines())
        assert line_count < 700, f"{ui_file.name} exceeds 700-line UI budget ({line_count} lines)"


@pytest.mark.parametrize(
    ("cls", "primary_sid", "variant_sid", "uses_enchant"),
    [
        ("MAGE", 1459, 23028, False),
        ("PRIEST", 1243, 21562, False),
        ("WARRIOR", 6673, 6673, False),
        ("DRUID", 1126, 21849, False),
        ("PALADIN", 19740, 25782, False),
        ("SHAMAN", 324, 8017, True),
        ("WARLOCK", 687, 706, False),
        ("HUNTER", 13165, 5118, False),
        ("ROGUE", 2842, 8679, True),
    ],
)
def test_v030_ac5_nine_class_buff_families_weapon_enchant_and_suppressions_ddt(
    cls: str, primary_sid: int, variant_sid: int, uses_enchant: bool
) -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_class = cls
    rt.known_spells = {primary_sid, variant_sid}
    ns = rt.boot_session()
    combat = ns["ModuleManager"]["modules"]["Combat"]["definition"]

    assert any("비전투 버프 누락 알림" in m for m in rt.chat_messages)
    rt.chat_messages.clear()
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is False
    assert rt.chat_messages == []

    rt.player_auras = {variant_sid: LuaTable({"spellId": variant_sid})}
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is True
    rt.player_auras.clear()
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is False
    assert any("비전투 버프 누락 알림" in m for m in rt.chat_messages)

    if uses_enchant:
        rt.player_auras.clear()
        rt.weapon_enchant = (False, True)
        assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is True
        rt.weapon_enchant = (SecretValue("mhEnchant"), False)
        assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None
        rt.weapon_enchant = (False, False)

    rt.player_auras.clear()
    rt.player_dead = True
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None
    rt.player_dead = False
    rt.resting = True
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None
    rt.resting = False
    rt.mounted = True
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None
    rt.mounted = False
    rt.on_taxi = True
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None
    rt.on_taxi = False
    rt.known_spells = set()
    assert rt.vm._invoke_callable(combat["CheckOutOfCombatBuffs"], (combat,))[0] is None


@pytest.mark.parametrize(
    ("p_pos", "c_pos", "expected_coord"),
    [
        ((0.425, 0.652), (0.312, 0.804), "플레이어: 42.5, 65.2  |  커서: 31.2, 80.4"),
        ((0.425, 0.652), (1.05, -0.1), "플레이어: 42.5, 65.2"),
        ((-0.1, 0.5), (0.0, 1.0), "플레이어: —  |  커서: 0.0, 100.0"),
        ((1.2, 0.5), (1.0, 0.0), "플레이어: —  |  커서: 100.0, 0.0"),
        (None, (0.500, 0.250), "플레이어: —  |  커서: 50.0, 25.0"),
        (None, None, "플레이어: —"),
    ],
)
def test_v030_ac5_worldmap_player_and_cursor_coordinates_ddt(
    p_pos: tuple[float, float] | None,
    c_pos: tuple[float, float] | None,
    expected_coord: str,
) -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_pos = p_pos
    rt.cursor_pos = c_pos
    ns = rt.boot_session()
    map_mod = ns["ModuleManager"]["modules"]["Map"]["definition"]
    actual = rt.vm._invoke_callable(map_mod["FormatPlayerCoordinateText"], (map_mod,))[0]
    assert actual == expected_coord


def _assert_v030_ac6_profession_gather_reconciliation(rt: WoWForeverMockRuntime, ns: LuaTable) -> None:
    prof = ns["ModuleManager"]["modules"]["Profession"]["definition"]
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:2770|h[구리 광석]|hx3.")
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:2001|h[수습생의 지팡이]|h.")
    rt.fire_event("CHAT_MSG_LOOT", "제이나님이 아이템을 획득했습니다: |Hitem:2770|h[구리 광석]|hx9.")
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:8899|h[심해 무지개송어]|hx4.")

    assert prof["sessionTotalItems"] == 8
    assert prof["sessionGatherItems"] == 3
    assert prof["sessionGeneralItems"] == 1
    assert prof["sessionPendingItems"] == 4

    rt.item_db[8899] = ("심해 무지개송어", "|Hitem:8899|h[심해 무지개송어]|h", 1, 15, 1, "직업용품", "요리", 20, "", 134005, 50, 7, 8)
    rt.fire_event("GET_ITEM_INFO_RECEIVED", 8899, True)
    assert prof["sessionPendingItems"] == 0
    assert prof["sessionGatherItems"] == 7
    assert prof["sessionGeneralItems"] == 1


def test_v030_ac6_stack_vendor_tooltip_protect_sell_commands_and_profession_gather_yield() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    inv = ns["ModuleManager"]["modules"]["Inventory"]["definition"]
    gt = rt.vm.G["GameTooltip"]

    rt.run_slash("FOREVERSUITE", "protect |Hitem:9001|h[깨진 늑대 송곳니]|h")
    assert rt.vm._invoke_callable(ns["ProfileManager"]["IsProtectedItem"], (ns["ProfileManager"], 9001))[0] is True
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "protect list")
    assert any("9001" in m for m in rt.chat_messages)

    gt["ClearLines"](gt)
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9001, "|Hitem:9001|h[깨진 늑대 송곳니]|h", 5))
    line_count_once = gt["NumLines"](gt)
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9001, "|Hitem:9001|h[깨진 늑대 송곳니]|h", 5))
    assert gt["NumLines"](gt) == line_count_once
    joined_tip = "\n".join(gt["_lines"])
    assert "[판매 보호됨]" in joined_tip
    assert "묶음 판매가(x5)" in joined_tip

    gt["ClearLines"](gt)
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9002, "|Hitem:9002|h[낡은 가죽 조각]|h", 1))
    assert not any("묶음 판매가" in line for line in gt["_lines"])

    rt.run_slash("FOREVERSUITE", "protect 9001")
    for idx in range(1, 16):
        rt.bags[0]["items"][idx] = {"itemID": 9001, "quality": 0, "stackCount": 1, "isLocked": False}
    rt.chat_messages.clear()
    rt.fire_event("MERCHANT_SHOW")
    assert len(rt.sold_bag_slots) == 12
    assert any("잔여 3칸" in m and "/fs sell" in m for m in rt.chat_messages)

    rt.run_slash("FOREVERSUITE", "sell")
    assert len(rt.sold_bag_slots) == 15
    rt.fire_event("MERCHANT_CLOSED")
    _assert_v030_ac6_profession_gather_reconciliation(rt, ns)


def test_v030_ac8_hud_move_lock_persistence_and_live_bag_gold_tooltip() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    bag_hud = rt.vm.G["ForeverSuiteBagHUD"]
    alert_hud = rt.vm.G["ForeverSuiteHealthAlertFrame"]
    gt = rt.vm.G["GameTooltip"]

    assert alert_hud["IsMouseEnabled"](alert_hud) is False
    assert alert_hud["_shown"] is False

    rt.run_slash("FOREVERSUITE", "move")
    assert alert_hud["IsMouseEnabled"](alert_hud) is True
    assert alert_hud["_shown"] is True
    assert "드래그 이동" in alert_hud["_fsAlertLabel"]["_text"]

    rt._fire_widget_script(bag_hud, "OnDragStart")
    bag_hud["SetPoint"](bag_hud, "TOPLEFT", rt.vm.G["UIParent"], "TOPLEFT", 88, -64)
    rt._fire_widget_script(bag_hud, "OnDragStop")

    rt._fire_widget_script(alert_hud, "OnDragStart")
    alert_hud["SetPoint"](alert_hud, "TOP", rt.vm.G["UIParent"], "TOP", 12, -110)
    rt._fire_widget_script(alert_hud, "OnDragStop")

    ns_reloaded = rt.simulate_reload()
    pm_rel = ns_reloaded["ProfileManager"]
    assert rt.vm._invoke_callable(pm_rel["Get"], (pm_rel, "ui", "bagHudX"))[0] == 88
    assert rt.vm._invoke_callable(pm_rel["Get"], (pm_rel, "ui", "healthAlertY"))[0] == -110

    rt.run_slash("FOREVERSUITE", "move reset")
    alert_rel = rt.vm.G["ForeverSuiteHealthAlertFrame"]
    assert alert_rel["IsMouseEnabled"](alert_rel) is False
    assert rt.vm._invoke_callable(pm_rel["Get"], (pm_rel, "ui", "bagHudX"))[0] == -16

    bag_rel = rt.vm.G["ForeverSuiteBagHUD"]
    gt_rel = rt.vm.G["GameTooltip"]
    rt._fire_widget_script(bag_rel, "OnEnter")
    assert any("세션 순증감" in line for line in gt_rel["_lines"])

    rt.vm._invoke_callable(ns_reloaded["SetPendingMoneyReason"], ("QUEST", 1.5, 1, 2500))
    rt.player_money += 2500
    rt.fire_event("PLAYER_MONEY")
    assert any("퀘스트 보상" in line and "25|cffc7c7cfs|r" in line for line in gt_rel["_lines"])

    mm_rel = ns_reloaded["ModuleManager"]
    rt.vm._invoke_callable(mm_rel["DisableModule"], (mm_rel, "Economy"))
    rt._fire_widget_script(bag_rel, "OnEnter")
    assert any("세션 순증감" in line and "—" in line for line in gt_rel["_lines"])


def test_v030_codex_review_regressions_secret_throw_profession_classid_and_tooltip_clear() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()

    # 1. Throwing _G.issecretvalue must fail closed (return True)
    orig_secret_fn = rt.vm.G["issecretvalue"]

    def throwing_secret(_v: object) -> bool:
        raise RuntimeError("C_Secrets engine fault")

    rt.vm.G["issecretvalue"] = throwing_secret
    assert rt.vm._invoke_callable(ns["IsSecret"], (42,))[0] is True
    rt.vm.G["issecretvalue"] = orig_secret_fn
    assert rt.vm._invoke_callable(ns["IsSecret"], (42,))[0] is False

    # 2. Authoritative numeric classID ~= 7 must NOT be overridden by 'Fish' / '물고기' subtype
    prof = ns["ModuleManager"]["modules"]["Profession"]["definition"]
    rt.item_db[7701] = ("구운 연어", "|Hitem:7701|h[구운 연어]|h", 1, 20, 1, "소비용품", "Fish", 20, "", 134005, 30, 0, 5)
    rt.item_db[7702] = ("수수께끼 물고기", "|Hitem:7702|h[수수께끼 물고기]|h", 1, 20, 1, "기타", "물고기", 20, "", 134005, 30, None, 0)
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:7701|h[구운 연어]|hx2.")
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:7702|h[수수께끼 물고기]|hx3.")
    assert prof["sessionGeneralItems"] == 2
    assert prof["sessionGatherItems"] == 3

    # 3. Tooltip ClearLines() + repopulating identical base line count must re-enrich (not skip)
    inv = ns["ModuleManager"]["modules"]["Inventory"]["definition"]
    gt = rt.vm.G["GameTooltip"]
    gt["ClearLines"](gt)
    gt["AddLine"](gt, "깨진 늑대 송곳니")
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9001, "|Hitem:9001|h[깨진 늑대 송곳니]|h", 5))
    enriched_total = gt["NumLines"](gt)
    assert enriched_total >= 4

    gt["ClearLines"](gt)
    for idx in range(enriched_total):
        gt["AddLine"](gt, f"BaseLine {idx}")
    assert gt["NumLines"](gt) == enriched_total
    rt.vm._invoke_callable(inv["EnrichItemTooltip"], (inv, gt, 9001, "|Hitem:9001|h[깨진 늑대 송곳니]|h", 5))
    assert gt["NumLines"](gt) > enriched_total
    assert any("묶음 판매가(x5)" in line for line in gt["_lines"])

    # 4. SettingsPanel Map drawer toggles must immediately stop/start coord ticker & unregister/re-register /way
    wmf = rt.vm.G["WorldMapFrame"]
    wmf["Show"](wmf)
    map_mod = ns["ModuleManager"]["modules"]["Map"]["definition"]
    assert map_mod["coordTicker"] is not None
    assert rt.vm.G["SlashCmdList"].get("FOREVERSUITEWAY") is not None

    rt.run_slash("FOREVERSUITE", "ui")
    sp = ns["SettingsPanel"]
    rt.vm._invoke_callable(sp["SelectTab"], (sp, "modules"))
    rt.vm._invoke_callable(sp["SelectDetailModule"], (sp, "Map"))
    coord_cb = sp["drawerCheckboxes"][1]
    way_cb = sp["drawerCheckboxes"][2]
    assert coord_cb["_fsSpec"]["key"] == "showCoordsOnWorldMap"
    assert way_cb["_fsSpec"]["key"] == "enableWaySlash"

    rt._fire_widget_script(coord_cb, "OnClick", "LeftButton")
    assert map_mod["coordTicker"] is None
    assert map_mod["coordHolder"]["_shown"] is False

    rt._fire_widget_script(way_cb, "OnClick", "LeftButton")
    assert rt.vm.G["SlashCmdList"].get("FOREVERSUITEWAY") is None
    assert rt.vm._invoke_callable(map_mod["SetWaypointFromSlash"], (map_mod, "20 30"))[0] is False

    rt._fire_widget_script(coord_cb, "OnClick", "LeftButton")
    assert map_mod["coordTicker"] is not None
    assert map_mod["coordHolder"]["_shown"] is True

    rt._fire_widget_script(way_cb, "OnClick", "LeftButton")
    assert rt.vm.G["SlashCmdList"].get("FOREVERSUITEWAY") is not None
    assert rt.vm._invoke_callable(map_mod["SetWaypointFromSlash"], (map_mod, "20 30"))[0] is True


# ---------------------------------------------------------------------------
# 16. v0.3.1: C_AddOns Metadata Resolution & Bridge-Aware Economy Attribution
# ---------------------------------------------------------------------------


def test_v031_c_addons_metadata_fallback_when_global_missing() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.vm.G["GetAddOnMetadata"] = None
    ns = rt.boot_session()
    assert ns["VERSION"] == "0.3.6"
    assert ns["TARGET_TOC"] == 16001


def test_v031_economy_external_repair_and_negative_purchase_isolation() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_money = 100_000
    rt.can_merchant_repair = True
    rt.repair_cost = 4_200
    ns = rt.boot_session()
    rt.vm._invoke_callable(ns["SetFeatureYield"], ("repair", True, "GodJohnsonGoldBorder"))
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    rt.fire_event("MERCHANT_SHOW")
    assert rt.repair_calls == []

    # Vendor item purchase while repair_cost > 0 must NOT be misclassified as REPAIR
    rt.player_money -= 999
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["other"] == -999
    assert econ["ledger"]["repair"] == 0

    # External GJ guild repair does not deduct personal gold
    rt.vm.G["RepairAllItems"](True)
    assert econ["ledger"]["repair"] == 0

    # External GJ personal repair via RepairAllItems(false) attributes exact cost to REPAIR
    # (even if a stale >3.0s _fsRepairArmedAt flag was left behind by an earlier aborted call)
    ns["_fsRepairArmedAt"] = -10.0
    rt.repair_cost = 4_200
    rt.fire_event("UPDATE_INVENTORY_DURABILITY")
    rt.vm.G["RepairAllItems"](False)
    assert econ["ledger"]["repair"] == -4_200
    assert econ["ledger"]["other"] == -999

    # Failed repair inside 2.0s window followed by -750 vendor purchase must stay in 'other' (-750 != -4200)
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("REPAIR", 2.0, -1, -4_200))
    rt.player_money -= 750
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["repair"] == -4_200
    assert econ["ledger"]["other"] == -1_749


def test_v031_economy_external_vendor_sell_and_party_loot_isolation() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_money = 50_000
    rt.item_db[7001] = ("Broken Fang", "|cff9d9d9d|Hitem:7001|h[Broken Fang]|h|r", 0, 1, 1, "Misc", "Junk", 20, "", 134400, 1_250)
    rt.bags[0]["items"][1] = {"itemID": 7001, "quality": 0, "stackCount": 2, "isLocked": False, "hasNoValue": False}
    ns = rt.boot_session()
    rt.vm._invoke_callable(ns["SetFeatureYield"], ("sell", True, "GodJohnsonGoldBorder"))
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    rt.fire_event("MERCHANT_SHOW")
    assert rt.sold_bag_slots == []

    # External GJ or manual right-click bag sale via C_Container.UseContainerItem
    rt.vm.G["C_Container"]["UseContainerItem"](0, 1)
    assert econ["ledger"]["vendorSell"] == 2_500
    assert econ["ledger"]["other"] == 0

    # Party gold loot or mail gold arriving while MerchantFrame is still open stays in 'other'
    rt.player_money += 888
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["vendorSell"] == 2_500
    assert econ["ledger"]["other"] == 888


def test_v031_economy_external_quest_reward_ttl_and_exact_delta_priority() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_money = 20_000
    rt.quest_reward_money = 12_345
    ns = rt.boot_session()
    rt.vm._invoke_callable(ns["SetFeatureYield"], ("questAutoAccept", True, "GodJohnsonGoldBorder"))
    rt.vm._invoke_callable(ns["SetFeatureYield"], ("questAutoTurnIn", True, "GodJohnsonGoldBorder"))
    econ = ns["ModuleManager"]["modules"]["Economy"]["definition"]

    # Leave an unconsumed wildcard VENDOR_SELL entry in queue, then complete quest via external GJ call
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("VENDOR_SELL", 2.0, 1, None))
    rt.fire_event("QUEST_COMPLETE")
    rt.vm.G["GetQuestReward"](1)
    assert econ["ledger"]["quest"] == 12_345
    assert econ["ledger"]["vendorSell"] == 0

    # Verify 3.0s quest TTL window survives >1.5s server latency
    rt.vm._invoke_callable(ns["SetPendingMoneyReason"], ("QUEST", 3.0, 1, 5_000))
    rt.advance_time(2.4)
    rt.player_money += 5_000
    rt.fire_event("PLAYER_MONEY")
    assert econ["ledger"]["quest"] == 17_345


# ---------------------------------------------------------------------------
# 17. v0.3.2: Nameplate CVar Preset, External Yield, and /fs layer Diagnostic
# ---------------------------------------------------------------------------


def test_v032_nameplate_cvar_preset_combat_deferral_and_restore() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.boot_session()

    # M3: Player V/Shift-V nameplateShowEnemies & nameplateShowAll toggles must remain untouched
    assert rt.cvars["nameplateShowEnemies"] == "0"
    assert rt.cvars["nameplateShowAll"] == "0"
    assert rt.cvars["nameplateShowEnemyMinions"] == "1"
    assert rt.cvars["nameplateMotion"] == "1"
    assert rt.cvars["nameplateMaxDistance"] == "41"
    assert rt.cvars["nameplateSelectedScale"] == "1.2"
    pending = rt.vm.G["ForeverSuiteDB"]["pendingCVarRestores"]
    assert pending["nameplateMotion"] == "0"
    assert pending["nameplateMaxDistance"] == "20"

    # Toggle off during combat must defer restore via CombatQueue and report deferred status accurately (M4)
    rt.chat_messages.clear()
    rt.combat_lockdown = True
    rt.run_slash("FOREVERSUITE", "nameplate off")
    assert rt.cvars["nameplateMotion"] == "1"
    assert any("전투 종료 후 복원 예약" in m for m in rt.chat_messages)

    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    assert rt.cvars["nameplateMotion"] == "0"
    assert rt.cvars["nameplateMaxDistance"] == "20"
    assert rt.cvars["nameplateSelectedScale"] == "1.0"


def test_v033_nameplate_readonly_disabled_and_external_yield_safety() -> None:
    # 1. M1/L1: Read-only (future schema) must fail closed without touching client CVars
    rt_ro = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ro.vm.G["ForeverSuiteDB"] = LuaTable(
        {
            "schemaVersion": 99,
            "account": LuaTable({"combat": LuaTable({"enhanceNameplates": True})}),
        }
    )
    ns_ro = rt_ro.boot_session()
    assert ns_ro["ProfileManager"]["readOnly"] is True
    assert rt_ro.cvars["nameplateMotion"] == "0"
    assert rt_ro.cvars["nameplateMaxDistance"] == "20"

    # 2. M2: /fs nameplate on while Combat module is DISABLED must warn and not mutate CVars
    rt_dis = WoWForeverMockRuntime(ADDON_ROOT)
    rt_dis.boot_session()
    rt_dis.run_slash("FOREVERSUITE", "disable Combat")
    assert rt_dis.cvars["nameplateMotion"] == "0"
    rt_dis.chat_messages.clear()
    rt_dis.run_slash("FOREVERSUITE", "nameplate on")
    assert rt_dis.cvars["nameplateMotion"] == "0"
    assert any("비활성화" in m for m in rt_dis.chat_messages)

    # 3. M4/L2: External addon yield prints yield notice and preserves matching-value external CVars
    rt_ext = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ext.boot_session()
    assert rt_ext.cvars["nameplateMaxDistance"] == "41"
    rt_ext.loaded_external_addons.add("Plater")
    rt_ext.fire_event("ADDON_LOADED", "Plater")
    # Even when Plater leaves nameplateMaxDistance="41" matching preset value, must not revert to "20"
    assert rt_ext.cvars["nameplateMaxDistance"] == "41"
    pending_ext = rt_ext.vm.G["ForeverSuiteDB"]["pendingCVarRestores"]
    assert pending_ext.get("nameplateMaxDistance") is None

    rt_ext.chat_messages.clear()
    rt_ext.run_slash("FOREVERSUITE", "nameplate on")
    assert any("양보" in m for m in rt_ext.chat_messages)
    assert not any("활성 (CVar 적용)" in m for m in rt_ext.chat_messages)

    # 4. External yield must also drop legacy v0.3.2 nameplateShowEnemies snapshot without reverting
    rt_leg = WoWForeverMockRuntime(ADDON_ROOT)
    rt_leg.boot_session()
    rt_leg.vm.G["ForeverSuiteDB"]["pendingCVarRestores"]["nameplateShowEnemies"] = "0"
    rt_leg.cvars["nameplateShowEnemies"] = "1"
    rt_leg.loaded_external_addons.add("Plater")
    rt_leg.fire_event("ADDON_LOADED", "Plater")
    assert rt_leg.cvars["nameplateShowEnemies"] == "1"
    assert rt_leg.vm.G["ForeverSuiteDB"]["pendingCVarRestores"].get("nameplateShowEnemies") is None

    # 5. If all preset CVars fail to apply out-of-combat, /fs nameplate on must NOT fabricate "CVar 적용"
    rt_fail = WoWForeverMockRuntime(ADDON_ROOT)
    rt_fail.boot_session()
    for key in ("nameplateShowEnemyMinions", "nameplateMotion", "nameplateMaxDistance", "nameplateSelectedScale"):
        rt_fail.cvars.pop(key, None)
    rt_fail.chat_messages.clear()
    rt_fail.run_slash("FOREVERSUITE", "nameplate on")
    assert not any("활성 (CVar 적용)" in m for m in rt_fail.chat_messages)
    assert any("적용 실패" in m for m in rt_fail.chat_messages)


def test_v032_nameplate_preset_auto_yields_to_external_addon() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.loaded_external_addons.add("Platynator")
    ns = rt.boot_session()
    combat = ns["ModuleManager"]["modules"]["Combat"]["definition"]

    assert combat["nameplateOwner"] == "Platynator"
    assert combat["nameplatesApplied"] is False
    assert rt.cvars["nameplateMotion"] == "0"
    assert rt.cvars["nameplateMaxDistance"] == "20"

    # Late-loaded external addon must yield cleanly and preserve all external/current CVars (L2)
    rt2 = WoWForeverMockRuntime(ADDON_ROOT)
    ns2 = rt2.boot_session()
    combat2 = ns2["ModuleManager"]["modules"]["Combat"]["definition"]
    assert rt2.cvars["nameplateMotion"] == "1"
    rt2.loaded_external_addons.add("Plater")
    rt2.cvars["nameplateMotion"] = "2"
    rt2.fire_event("ADDON_LOADED", "Plater")
    assert combat2["nameplateOwner"] == "Plater"
    assert rt2.cvars["nameplateMotion"] == "2"
    assert rt2.cvars["nameplateMaxDistance"] == "41"
    assert rt2.vm.G["ForeverSuiteDB"]["pendingCVarRestores"].get("nameplateMaxDistance") is None


def test_v032_map_layer_guid_extraction_and_secret_safety() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.unit_guids["target"] = "Creature-0-4521-0-1429-68-000012ABCD"
    rt.unit_guids["player"] = "Player-6784-000D24E7"
    rt.instance_info = ("엘윈 숲", "none")
    ns = rt.boot_session()
    map_mod = ns["ModuleManager"]["modules"]["Map"]["definition"]

    z_npc, i_npc, s_npc = rt.vm._invoke_callable(
        map_mod["ExtractZoneLayerFromGUID"], ("Creature-0-4521-0-1429-68-000012ABCD",)
    )
    assert (z_npc, i_npc, s_npc) == ("1429", "0", "4521")
    z_pl = rt.vm._invoke_callable(map_mod["ExtractZoneLayerFromGUID"], ("Player-6784-000D24E7",))[0]
    assert z_pl is None
    z_sec = rt.vm._invoke_callable(map_mod["ExtractZoneLayerFromGUID"], (SecretValue("Creature-0-1-0-2-3"),))[0]
    assert z_sec is None

    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "layer")
    assert any("ZoneUID=1429" in m and "Server=4521" in m for m in rt.chat_messages)


def test_v036_feature_yields_16001_and_settings_search() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.loaded_external_addons = {"Plumber", "DialogueUI", "Leatrix_Maps", "BetterBags", "!KalielsTracker"}
    ns = rt.boot_session()

    for key in ("fastLoot", "questAutoDialog", "mapCoords", "bagHud", "questTrackerHud"):
        assert rt.vm._invoke_callable(ns["IsFeatureYielded"], (key,))[0] is True, f"{key} must yield"

    mm = ns["ModuleManager"]
    assert mm["modules"]["Utility"]["state"] == "ENABLED"
    assert mm["modules"]["Quest"]["state"] == "ENABLED"
    assert mm["modules"]["Map"]["state"] == "ENABLED"
    assert mm["modules"]["Inventory"]["state"] == "ENABLED"
    assert ns["QuestTracker"]["frame"]["_shown"] is False
    assert rt.vm.G["ObjectiveTrackerFrame"]["_shown"] is True

    # Late ADDON_LOADED for TomTom unregisters /way cleanly while keeping Map coords/layer alive
    rt.loaded_external_addons.add("TomTom")
    rt.fire_event("ADDON_LOADED", "TomTom")
    assert rt.vm._invoke_callable(ns["IsFeatureYielded"], ("way",))[0] is True
    assert mm["modules"]["Map"]["definition"]["wayOwned"] is False

    # SettingsPanel SearchBox filters options across modules and resets cleanly
    sp = ns["SettingsPanel"]
    rt.run_slash("FOREVERSUITE", "ui")
    sbox = sp["searchBox"]
    rt.vm._invoke_callable(sbox["SetText"], (sbox, "자동"))
    assert "검색 결과:" in sp["drawerTitle"]["_text"]
    assert sp["drawerCheckboxes"][1]["_shown"] is True
    assert "[" in sp["drawerCheckboxes"][1]["_fsLabel"]["_text"]

    rt.vm._invoke_callable(sp["SelectDetailModule"], (sp, "Combat"))
    assert sp["searchQuery"] == ""
    assert "Combat" in sp["drawerTitle"]["_text"]


def test_v036_static_rule_fixtures_guarded_chat_and_multiline_build() -> None:
    guarded = "if type(SendChatMessage) == \"function\" then\nSendChatMessage('x')\nend\n"
    split = "if type(SendChatMessage)\n== \"function\" then\nSendChatMessage('x')\nend\n"
    bare = "SendChatMessage('x')\n"
    negated = "if not SendChatMessage then\nSendChatMessage('x')\nend\n"
    paren_negated = "if (not SendChatMessage) then\nSendChatMessage('x')\nend\n"
    global_call = "_G.SendChatMessage('x')\n"
    later = "if not SendChatMessage then\nreturn\nend\nSendChatMessage('y')\n"
    multiline = "local build = select(4, GetBuildInfo())\nif build >= 100000 then\nreturn\nend\n"
    global_build = "local build = select(4, _G.GetBuildInfo())\nif build >= 100000 then\nreturn\nend\n"
    unrelated = "local other = 1\nif other >= 100000 then\nreturn\nend\n"
    assert not _has_unguarded_sendchat(guarded)
    assert not _has_unguarded_sendchat(split)
    assert _has_unguarded_sendchat(bare)
    assert _has_unguarded_sendchat(negated)
    assert _has_unguarded_sendchat(paren_negated)
    assert _has_unguarded_sendchat(global_call)
    assert _has_unguarded_sendchat(later)
    assert _has_build_version_trap(multiline)
    assert _has_build_version_trap(global_build)
    assert not _has_build_version_trap(unrelated)


def test_v036_review_handoff_profile_and_search_page() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.loaded_external_addons = {"Leatrix_Maps", "Plumber", "DialogueUI"}
    rt.loot_slots = [1, 2]
    ns = rt.boot_session()
    holder = ns["Map"]["coordHolder"]
    wmf = rt.vm.G["WorldMapFrame"]
    wmf["_shown"] = True
    rt._fire_widget_script(wmf, "OnShow")
    assert holder["_shown"] is False
    assert ns["Map"]["coordTicker"] is None

    rt.fire_event("LOOT_READY")
    assert rt.looted_slots == []
    accepted: list[str] = []
    rt.vm.G["AcceptQuest"] = lambda: accepted.append("accept")
    rt.fire_event("QUEST_DETAIL")
    assert accepted == []

    way_fn = rt.vm.G["SlashCmdList"].get("FOREVERSUITEWAY")
    rt.loaded_external_addons.add("TomTom")
    rt.fire_event("ADDON_LOADED", "TomTom")
    if callable(way_fn):
        rt.vm._invoke_callable(way_fn, ("50 50",))
    assert ns["Map"]["userWaypointActive"] is False

    item_btn = rt._make_frame("Button", None)
    item_btn["_shown"] = True
    ns["QuestTracker"]["itemButtons"][1] = item_btn
    rt.loaded_external_addons.add("!KalielsTracker")
    rt.vm._invoke_callable(ns["SyncExternalFeatureYields"], ())
    rt.vm._invoke_callable(ns["QuestTracker"]["SyncQuestItemButtons"], (ns["QuestTracker"],))
    assert item_btn["_shown"] is False

    calls = {"quest": 0}

    def boom_map(*_args):
        raise RuntimeError("map handoff failed")

    def count_quest(*_args):
        calls["quest"] += 1
        return None

    ns["Map"]["SyncSettings"] = boom_map
    ns["QuestTracker"]["Refresh"] = count_quest
    rt.fire_event("ADDON_LOADED", "Plumber")
    assert ns["ModuleManager"]["modules"]["Map"]["errorCount"] >= 1
    assert calls["quest"] >= 1

    pm = ns["ProfileManager"]
    pm["runtimeAccount"]["quest"]["collapsedQuests"][202] = True
    rt.vm._invoke_callable(pm["SetQuestCollapsed"], (pm, 101, True))
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 101))[0] is True
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 202))[0] is True
    rt.vm._invoke_callable(pm["SetQuestCollapsed"], (pm, 202, False))
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 202))[0] is False
    rt.vm._invoke_callable(pm["SetQuestCollapsed"], (pm, 202, True))
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 202))[0] is True
    secret = SecretValue("quest-id")
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, secret))[0] is False
    rt.fire_event("QUEST_REMOVED", 101)
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 101))[0] is False
    assert rt.vm._invoke_callable(pm["IsQuestCollapsed"], (pm, 202))[0] is True

    catalog = rt.vm._invoke_callable(ns["SettingsPanel"]["BuildOptionCatalog"], ())[0]
    matches = rt.vm._invoke_callable(ns["SettingsPanel"]["CollectOptionMatches"], (catalog, "a"))
    spec_list = matches[0]
    match_count = 0
    while spec_list[match_count + 1] is not None:
        match_count += 1
    assert match_count >= 10
    sp = ns["SettingsPanel"]
    rt.run_slash("FOREVERSUITE", "ui")
    rt.vm._invoke_callable(sp["searchBox"]["SetText"], (sp["searchBox"], "a"))
    assert f"{match_count}건" in sp["drawerTitle"]["_text"]
    first = sp["drawerCheckboxes"][1]["_fsLabel"]["_text"]
    rt._fire_widget_script(sp["searchPageBtn"], "OnClick")
    assert sp["searchPage"] == 2
    assert sp["drawerCheckboxes"][1]["_fsLabel"]["_text"] != first

    key_matches = rt.vm._invoke_callable(ns["SettingsPanel"]["CollectOptionMatches"], (catalog, "useGuildRepair"))
    key_labels = key_matches[1]
    joined = str(key_labels[1])
    assert "길드 수리" in joined


def test_v036_quest_watch_only_and_failed_alpha_restore() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.quest_watch_only = True
    rt.vm = type(rt.vm)()
    rt.frames.clear()
    rt._install_wow_globals()
    rt.baseline_global_keys = set(rt.vm.G.keys())
    ns = rt.boot_session()
    watch = rt.vm.G["QuestWatchFrame"]
    assert watch["_alpha"] == 0.0
    assert watch["_shown"] is False

    rt2 = WoWForeverMockRuntime(ADDON_ROOT)
    ns2 = rt2.boot_session()
    obj = rt2.vm.G["ObjectiveTrackerFrame"]
    assert obj["_shown"] is False
    original = obj["SetAlpha"]

    def fail_alpha(*_args):
        raise RuntimeError("SetAlpha failed")

    obj["SetAlpha"] = fail_alpha
    rt2.run_slash("FOREVERSUITE", "quest default")
    assert obj["_shown"] is False
    obj["SetAlpha"] = original
    rt2.vm._invoke_callable(ns2["QuestTracker"]["SyncDefaultTrackerVisibility"], (ns2["QuestTracker"],))
    assert obj["_shown"] is True
    assert obj["_alpha"] == 1.0







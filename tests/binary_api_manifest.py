"""Ground-truth WoW Forever 1.60.1.70707 (TOC 11701) binary API symbol verifier."""

from __future__ import annotations

import pathlib
import re

DEFAULT_MAC_BINARY = pathlib.Path(
    "/Applications/World of Warcraft/_forever_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
)

# Verified baseline extracted directly from WoW Forever 1.60.1.70707 (wowf) binary
VERIFIED_WOWF_16001_C_APIS: frozenset[str] = frozenset(
    {
        "C_AddOns.DoesAddOnExist",
        "C_AddOns.IsAddOnLoaded",
        "C_AddOns.LoadAddOn",
        "C_AddOnProfiler.GetAddOnMetric",
        "C_AddOnProfiler.IsEnabled",
        "C_Container.GetContainerItemID",
        "C_Container.GetContainerItemInfo",
        "C_Container.GetContainerNumFreeSlots",
        "C_Container.GetContainerNumSlots",
        "C_Container.SortBags",
        "C_Container.UseContainerItem",
        "C_CVar.GetCVar",
        "C_CVar.SetCVar",
        "C_Item.GetDetailedItemLevelInfo",
        "C_Item.GetItemInfo",
        "C_Map.CanSetUserWaypointOnMap",
        "C_Map.ClearUserWaypoint",
        "C_Map.GetBestMapForUnit",
        "C_Map.GetMapInfo",
        "C_Map.GetPlayerMapPosition",
        "C_Map.SetUserWaypoint",
        "C_Minimap.GetNumTrackingTypes",
        "C_Minimap.GetTrackingInfo",
        "C_QuestLog.AddQuestWatch",
        "C_QuestLog.GetDistanceSqToQuest",
        "C_QuestLog.GetHeaderIndexForQuest",
        "C_QuestLog.GetInfo",
        "C_QuestLog.GetLogIndexForQuestID",
        "C_QuestLog.GetNumQuestLogEntries",
        "C_QuestLog.GetNumQuestWatches",
        "C_QuestLog.GetQuestDifficultyLevel",
        "C_QuestLog.GetQuestIDForQuestWatchIndex",
        "C_QuestLog.GetQuestObjectives",
        "C_QuestLog.GetQuestTagInfo",
        "C_QuestLog.GetQuestWatchType",
        "C_QuestLog.IsComplete",
        "C_QuestLog.IsOnMap",
        "C_QuestLog.ReadyForTurnIn",
        "C_QuestLog.RemoveQuestWatch",
        "C_QuestLog.SetSelectedQuest",
        "C_Spell.GetSpellInfo",
        "C_Spell.IsSpellKnown",
        "C_SuperTrack.GetSuperTrackedQuestID",
        "C_SuperTrack.SetSuperTrackedQuestID",
        "C_SuperTrack.SetSuperTrackedUserWaypoint",
        "C_Timer.After",
        "C_Timer.NewTicker",
        "C_UnitAuras.GetAuraDataByIndex",
        "C_UnitAuras.GetPlayerAuraBySpellID",
    }
)

FORBIDDEN_LEGACY_APIS: frozenset[str] = frozenset(
    {
        "GetContainerNumSlots",
        "GetContainerNumFreeSlots",
        "GetContainerItemInfo",
        "UseContainerItem",
        "GetSpellInfo",
        "UnitBuff",
        "UnitDebuff",
        "UnitAura",
        "IsAddOnLoaded",
        "GetAddOnInfo",
        "InterfaceOptions_AddCategory",
        "UIDropDownMenu_Initialize",
        "UIDropDownMenu_CreateInfo",
    }
)

FORBIDDEN_COMBAT_AUTOMATION_APIS: frozenset[str] = frozenset(
    {
        "CastSpellByName",
        "CastSpellByID",
        "CastSpell",
        "TargetUnit",
        "TargetNearestEnemy",
        "UseAction",
        "RunMacroText",
        "RunMacro",
        "AttackTarget",
    }
)


def extract_c_api_calls_from_lua(lua_source: str) -> set[str]:
    """Extract all C_<Namespace>.<Method> references from non-comment Lua code."""
    cleaned_lines = []
    for line in lua_source.splitlines():
        stripped = line.split("--", 1)[0]
        cleaned_lines.append(stripped)
    joined = "\n".join(cleaned_lines)
    return set(re.findall(r"\b(C_[A-Za-z0-9_]+\.[A-Za-z0-9_]+)\b", joined))


def verify_symbols_in_local_binary(
    c_calls: set[str], binary_path: pathlib.Path = DEFAULT_MAC_BINARY
) -> tuple[bool, list[str]]:
    """Verify every C_Namespace.Method exists in the installed WoW Forever binary (or snapshot)."""
    missing: list[str] = []
    if binary_path.is_file():
        blob = binary_path.read_bytes()
        for call in sorted(c_calls):
            ns_name, fn_name = call.split(".", 1)
            if (ns_name.encode("ascii") not in blob) or (fn_name.encode("ascii") not in blob):
                missing.append(call)
        return (len(missing) == 0, missing)

    for call in sorted(c_calls):
        if call not in VERIFIED_WOWF_16001_C_APIS:
            missing.append(call)
    return (len(missing) == 0, missing)

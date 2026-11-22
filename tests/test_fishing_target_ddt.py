"""BDD/DDT Tests for Current-Zone Fishing Target Model, HUD, GJ DB Integration, and /fs fish Slash Commands."""

from __future__ import annotations

import pathlib
import sys

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"
TESTS_DIR = REPO_ROOT / "tests"
if str(TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(TESTS_DIR))

from lua51_engine import LuaTable  # noqa: E402
from wow_forever_mock import SecretValue, WoWForeverMockRuntime  # noqa: E402


def _make_gj_fishing_companion() -> LuaTable:
    return LuaTable(
        {
            "ProfessionData472": LuaTable(
                {
                    "byID": LuaTable(
                        {
                            356: LuaTable(
                                {
                                    "gatherings": LuaTable(
                                        {
                                            1: LuaTable(
                                                {
                                                    "itemID": 6291,
                                                    "name": "비단잉어",
                                                    "icon": "Interface\\Icons\\inv_misc_fish_09",
                                                    "fishingWater": "엘윈 숲 호수",
                                                    "zones": LuaTable({1: LuaTable({"mapID": 1429, "name": "엘윈 숲", "points": LuaTable()})}),
                                                }
                                            ),
                                            2: LuaTable(
                                                {
                                                    "itemID": 6358,
                                                    "name": "기름기 많은 아귀",
                                                    "icon": "Interface\\Icons\\inv_misc_fish_04",
                                                    "fishingWater": "불모의 땅 해안 어군",
                                                    "zones": LuaTable(
                                                        {
                                                            1: LuaTable(
                                                                {
                                                                    "mapID": 1413,
                                                                    "name": "불모의 땅",
                                                                    "points": LuaTable(
                                                                        {
                                                                            1: LuaTable({"x": 62.9, "y": 52.7, "schoolPoint": True}),
                                                                            2: LuaTable({"x": 63.3, "y": 59.3, "schoolPoint": True}),
                                                                        }
                                                                    ),
                                                                }
                                                            )
                                                        }
                                                    ),
                                                }
                                            ),
                                            3: LuaTable(
                                                {
                                                    "itemID": 16967,
                                                    "name": "페랄라스 아히",
                                                    "icon": "Interface\\Icons\\inv_misc_fish_06",
                                                    "fishingWater": "베르단티스 강",
                                                    "zones": LuaTable({1: LuaTable({"mapID": 1444, "name": "페랄라스", "points": LuaTable()})}),
                                                }
                                            ),
                                            4: LuaTable(
                                                {
                                                    "itemID": 13759,
                                                    "name": "밤비늘퉁돔",
                                                    "icon": "Interface\\Icons\\inv_misc_fish_07",
                                                    "fishingWater": "페랄라스 내륙",
                                                    "zones": LuaTable({1: LuaTable({"mapID": 1444, "name": "페랄라스", "points": LuaTable()})}),
                                                }
                                            ),
                                        }
                                    )
                                }
                            )
                        }
                    )
                }
            ),
            "ProfessionPracticalData5165": LuaTable(
                {
                    356: LuaTable(
                        {
                            "items": LuaTable(
                                {
                                    6358: LuaTable({"use": "연금술 자유 행동의 물약", "level": "낮은~중간 해안", "source": "불모의 땅 해안"}),
                                }
                            )
                        }
                    )
                }
            ),
        }
    )


def test_fishing_model_uses_gj_db_and_sorts_quest_target_and_school_first() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    model = ns["FishingTargetModel"]
    gj = _make_gj_fishing_companion()

    opts = LuaTable(
        {
            "mapID": 1444,
            "zoneName": "페랄라스",
            "skillRank": 225,
            "skillMax": 300,
            "useLiveSkill": False,
            "gjCompanion": gj,
            "activeQuestIDs": LuaTable({6607: True}),
            "activeObjectiveTexts": LuaTable(),
            "sessionByItemID": LuaTable({13759: 3}),
        }
    )
    vm = rt.vm._invoke_callable(model["BuildViewModel"], (model, opts))[0]
    assert vm["sourceKind"] == "GJ_DB"
    assert vm["recommendedSkill"] == 300
    assert vm["skillStatus"] == "LOW"
    assert vm["skillDelta"] == -75
    assert vm["questTargetCount"] == 1
    assert vm["totalCount"] == 2
    # Quest target (페랄라스 아히) must be sorted before non-quest caught fish (밤비늘퉁돔)
    assert vm["rows"][1]["itemID"] == 16967
    assert vm["rows"][1]["isQuestTarget"] is True
    assert vm["rows"][2]["itemID"] == 13759
    assert vm["rows"][2]["caughtCount"] == 3


def test_fishing_model_reads_school_points_and_practical_metadata_from_gj() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    model = ns["FishingTargetModel"]
    gj = _make_gj_fishing_companion()

    opts = LuaTable(
        {
            "mapID": 1413,
            "zoneName": "불모의 땅",
            "skillRank": 100,
            "useLiveSkill": False,
            "gjCompanion": gj,
            "activeQuestIDs": LuaTable(),
            "activeObjectiveTexts": LuaTable(),
        }
    )
    vm = rt.vm._invoke_callable(model["BuildViewModel"], (model, opts))[0]
    assert vm["sourceKind"] == "GJ_DB"
    assert vm["skillStatus"] == "OK"
    assert vm["rows"][1]["itemID"] == 6358
    assert vm["rows"][1]["hasSchool"] is True
    assert vm["rows"][1]["schoolPointCount"] == 2
    assert "자유 행동" in vm["rows"][1]["use"]


def test_fishing_model_standalone_fallback_and_dynamic_quest_objective_match() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    model = ns["FishingTargetModel"]

    opts = LuaTable(
        {
            "mapID": 1413,
            "zoneName": "불모의 땅",
            "skillRank": 80,
            "useLiveSkill": False,
            "gjCompanion": False,
            "activeQuestIDs": LuaTable(),
            "activeObjectiveTexts": LuaTable({1: "돌연변이 물고기 낚기: 1/5"}),
        }
    )
    vm = rt.vm._invoke_callable(model["BuildViewModel"], (model, opts))[0]
    assert vm["sourceKind"] == "BUILTIN"
    assert vm["rows"][1]["itemID"] == 6522
    assert vm["rows"][1]["isQuestTarget"] is True


def test_fishing_model_resilient_against_secret_values() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.boot_session()
    model = ns["FishingTargetModel"]

    opts = LuaTable(
        {
            "mapID": SecretValue("secret_map"),
            "zoneName": SecretValue("secret_zone", lua_type="string"),
            "skillRank": SecretValue("secret_skill"),
            "useLiveSkill": False,
            "gjCompanion": False,
            "activeQuestIDs": LuaTable(),
            "activeObjectiveTexts": LuaTable({1: SecretValue("secret_obj", lua_type="string")}),
        }
    )
    vm = rt.vm._invoke_callable(model["BuildViewModel"], (model, opts))[0]
    # Falls back safely to live mock zone (1429 엘윈 숲) without raising SecretValueViolationError
    assert vm["mapID"] == 1429
    assert vm["skillStatus"] == "UNKNOWN"


def test_fishing_hud_auto_visibility_on_pole_equip_and_gj_yield_coexistence() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.current_map_id = 1429
    rt.real_zone_text = "엘윈 숲"
    ns = rt.boot_session()
    hud = ns["FishingTargetHud"]

    # Even when double-click fishing is yielded to GodJohnson, target fish HUD still works!
    rt.vm._invoke_callable(ns["SetFeatureYield"], ("fishing", True, "GodJohnsonGoldBorder"))
    assert hud["frame"] is None or not hud["frame"]["_shown"]

    # Equip fishing pole (slot 16 = 6256) -> HUD automatically appears
    rt.equipped_items[16] = 6256
    rt.fire_event("PLAYER_EQUIPMENT_CHANGED", 16)
    assert hud["frame"] is not None
    assert hud["frame"]["_shown"] is True
    assert "엘윈 숲" in hud["titleLabel"]["_text"]
    assert hud["rowButtons"][1]["_shown"] is True

    # Hover first fish row -> tooltip populates without error
    rt._fire_widget_script(hud["rowButtons"][1], "OnEnter")
    gt = rt.vm.G["GameTooltip"]
    assert gt["_shown"] is True
    rt._fire_widget_script(hud["rowButtons"][1], "OnLeave")
    assert gt["_shown"] is False

    # Unequip pole -> auto mode hides HUD
    rt.equipped_items.pop(16, None)
    rt.fire_event("PLAYER_EQUIPMENT_CHANGED", 16)
    assert hud["frame"]["_shown"] is False


def test_fs_fish_slash_commands_pin_list_off_on_reset_and_readonly() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.current_map_id = 1446
    rt.real_zone_text = "타나리스"
    ns = rt.boot_session()
    hud = ns["FishingTargetHud"]

    # /fs fish pins HUD even without pole
    rt.run_slash("FOREVERSUITE", "fish")
    assert hud["pinned"] is True
    assert hud["frame"]["_shown"] is True
    assert any("타나리스" in m and "돌비늘뱀장어" in m for m in rt.chat_messages)

    # Loot a fish while HUD is shown -> live session catch badge updates
    rt.item_db[13422] = ("돌비늘뱀장어", "|Hitem:13422|h[돌비늘뱀장어]|h", 1, 1, 1, "직업용품", "물고기", 20, "", 134300, 50, 7, 0)
    rt.fire_event("CHAT_MSG_LOOT", "아이템을 획득했습니다: |Hitem:13422|h[돌비늘뱀장어]|h")
    assert any(
        hud["rowButtons"][i]["_shown"] and "x1" in hud["rowButtons"][i]["_fsBadge"]["_text"]
        for i in range(1, 5)
    )

    # /fs fish off disables HUD; /fs fish on re-enables
    rt.run_slash("FOREVERSUITE", "fish off")
    assert hud["frame"]["_shown"] is False
    rt.run_slash("FOREVERSUITE", "fish on")
    assert hud["frame"]["_shown"] is True

    # /fs fish auto unpins -> hides when no pole equipped
    rt.run_slash("FOREVERSUITE", "fish auto")
    assert hud["pinned"] is False
    assert hud["frame"]["_shown"] is False

    # /fs fish list prints summary to chat
    rt.chat_messages.clear()
    rt.run_slash("FOREVERSUITE", "fish list")
    assert any("권장 숙련 300" in m for m in rt.chat_messages)

    # Read-only future schema blocks /fs fish off and /fs fish reset
    rt_ro = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ro.vm.G["ForeverSuiteDB"] = LuaTable({"schemaVersion": 99, "account": LuaTable()})
    ns_ro = rt_ro.boot_session()
    rt_ro.run_slash("FOREVERSUITE", "fish off")
    assert rt_ro.vm._invoke_callable(ns_ro["ProfileManager"]["Get"], (ns_ro["ProfileManager"], "profession", "showFishingTargetHUD"))[0] is True
    assert any("읽기 전용" in m for m in rt_ro.chat_messages)

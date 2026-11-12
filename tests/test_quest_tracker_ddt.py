"""ATDD & BDD/DDT Verification Suite for ForeverSuite Regional/Level Quest Tracker HUD (FS-QUEST-TRACKER)."""

from __future__ import annotations

import pathlib
from typing import Any

import pytest

from lua51_engine import LuaTable
from wow_forever_mock import SecretValue, WoWForeverMockRuntime

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "ForeverSuite"


def _seed_sample_quest_log(rt: WoWForeverMockRuntime) -> None:
    """Seed multi-zone, multi-level quests for a Lv.24 player currently in '서부 몰락지대'."""
    rt.player_level = 24
    rt.real_zone_text = "서부 몰락지대"
    rt.zone_text = "서부 몰락지대"
    rt.quest_log_entries = [
        {"title": "붉은마루 산맥", "isHeader": True},
        {"questID": 201, "title": "검은바위 오크 소탕", "level": 25, "isComplete": False, "isOnMap": False},
        {"questID": 202, "title": "모건스 타워 정찰", "difficultyLevel": 29, "isComplete": False, "isOnMap": False},
        {"title": "서부 몰락지대", "isHeader": True},
        {"questID": 101, "title": "데피아즈단 두목 처치", "level": 23, "isComplete": False, "isOnMap": True},
        {"questID": 102, "title": "감시탑 보급품 전달", "level": 18, "readyForTurnIn": True, "isOnMap": True},
        {"title": "엘윈 숲", "isHeader": True},
        {"questID": 301, "title": "코볼트 양초 수집", "level": 9, "isComplete": False, "isOnMap": False},
        {"questID": 302, "title": "스톰윈드 보고서 제출", "level": 12, "isComplete": True, "isOnMap": False},
    ]
    rt.quest_objectives = {
        201: [{"text": "검은바위 투사: 4/10", "finished": False}],
        202: [{"text": "정찰병 탈론 처치: 0/1", "finished": False}],
        101: [
            {"text": "데피아즈단 밀사: 1/1", "finished": True},
            {"text": "에드윈 밴클리프 처치: 0/1", "finished": False},
        ],
        102: [{"text": "그라이언 스타우트맨틀에게 보고", "finished": True}],
        301: [{"text": "코볼트 양초: 3/8", "finished": False}],
        302: [{"text": "마커스 조나단 장군과 대화", "finished": True}],
    }
    rt.quest_tags = {
        101: {"tagName": "던전", "isElite": True},
        202: {"tagName": "정예", "isElite": True},
    }


def _lua_list_len(tbl: LuaTable) -> int:
    idx = 1
    while tbl.get(idx) is not None:
        idx += 1
    return idx - 1


def _lua_list_items(tbl: LuaTable) -> list[Any]:
    return [tbl.get(i) for i in range(1, _lua_list_len(tbl) + 1)]


def _extract_field(items: list[Any], key: str) -> list[Any]:
    return [item[key] for item in items]


def _visible_row_texts(tracker: LuaTable) -> list[str]:
    texts: list[str] = []
    widgets = tracker["rowWidgets"]
    for i in range(1, _lua_list_len(widgets) + 1):
        w = widgets.get(i)
        if w and w.get("_shown"):
            texts.append(str(w["_leftText"]["_text"]))
    return texts


# ---------------------------------------------------------------------------
# 1. AC-QT-1 & AC-QT-2: Pure ViewModel DDT (Difficulty Tiers, Zone Grouping & Level Grouping)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("quest_level", "player_level", "expected_tier", "expected_band", "expected_hex"),
    [
        (9, 24, "trivial", "low", "|cff94a3b8"),
        (18, 24, "easy", "low", "|cff4ade80"),
        (23, 24, "standard", "mid", "|cffffd23f"),
        (27, 24, "hard", "high", "|cffff8c38"),
        (30, 24, "impossible", "high", "|cffff4d4d"),
        (None, 24, "unknown", "unknown", "|cffcbd5e1"),
        (20, None, "unknown", "unknown", "|cffcbd5e1"),
    ],
)
def test_viewmodel_difficulty_tiers_ddt(
    quest_level: int | None,
    player_level: int,
    expected_tier: str,
    expected_band: str,
    expected_hex: str,
) -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    ns = rt.load_addon("ForeverSuite")
    model = ns["QuestTrackerModel"]

    style = rt.vm._invoke_callable(model["ComputeDifficulty"], (quest_level, player_level))[0]
    assert style["tier"] == expected_tier
    assert style["band"] == expected_band
    assert style["hex"] == expected_hex


def test_ac_qt1_zone_grouping_pins_current_zone_and_completed_quests_first() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    ns = rt.boot_session()
    tracker = ns["QuestTracker"]

    snap = tracker["lastSnapshot"]
    assert snap["mode"] == "zone"
    assert snap["totalQuests"] == 6
    assert snap["totalCompleted"] == 2

    groups = _lua_list_items(snap["groups"])
    assert _extract_field(groups, "title") == ["서부 몰락지대", "엘윈 숲", "붉은마루 산맥"]
    assert groups[0]["isCurrentZone"] is True

    # Inside current zone ('서부 몰락지대'), completed quest 102 must sort above incomplete quest 101
    westfall_quests = _lua_list_items(groups[0]["quests"])
    assert _extract_field(westfall_quests, "questID") == [102, 101]

    rendered_joined = "\n".join(_visible_row_texts(tracker))
    assert "[현재 지역]" in rendered_joined
    assert "감시탑 보급품 전달" in rendered_joined and "[완료]" in rendered_joined
    assert "[던전]" in rendered_joined


def test_ac_qt2_level_grouping_sorts_by_difficulty_bands_and_appends_zone_context() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    ns = rt.boot_session()
    tracker = ns["QuestTracker"]

    # Click header '[레벨별]' button directly on HUD
    level_btn = tracker["levelBtn"]
    rt._fire_widget_script(level_btn, "OnClick", "LeftButton")

    snap = tracker["lastSnapshot"]
    assert snap["mode"] == "level"
    groups = _lua_list_items(snap["groups"])
    assert _extract_field(groups, "title") == ["수월 · 저레벨", "적정 레벨", "도전 · 고레벨"]

    low_quests = _lua_list_items(groups[0]["quests"])
    mid_quests = _lua_list_items(groups[1]["quests"])
    high_quests = _lua_list_items(groups[2]["quests"])

    # Strictly ascending quest levels inside each difficulty band
    assert _extract_field(low_quests, "level") == [9, 12, 18]
    assert _extract_field(mid_quests, "level") == [23, 25]
    assert _extract_field(high_quests, "level") == [29]

    rendered = "\n".join(_visible_row_texts(tracker))
    assert "(Lv.9~18)" in rendered
    assert "· 엘윈 숲" in rendered
    assert "· 붉은마루 산맥" in rendered
    assert "[정예]" in rendered


# ---------------------------------------------------------------------------
# 2. AC-QT-3: Current-Zone Quick Filter, Group Collapse Persistence & Collapsed Blizzard Header Recovery
# ---------------------------------------------------------------------------


def test_ac_qt3_current_zone_filter_and_collapsed_group_persistence_across_reload() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    ns = rt.boot_session()
    tracker = ns["QuestTracker"]

    # Toggle '[현지역]' filter button -> hides unfinished remote quests (201, 202, 301)
    # while keeping current-zone quests (101, 102) AND completed remote quest (302)!
    rt._fire_widget_script(tracker["hereBtn"], "OnClick", "LeftButton")
    snap = tracker["lastSnapshot"]
    assert snap["visibleQuests"] == 3
    assert snap["hiddenByFilter"] == 3
    assert "타 지역 미완료 3개 숨김" in tracker["scrollHint"]["_text"]

    visible_titles = "\n".join(_visible_row_texts(tracker))
    assert "데피아즈단 두목 처치" in visible_titles
    assert "스톰윈드 보고서 제출" in visible_titles
    assert "검은바위 오크 소탕" not in visible_titles

    # Disable '[현지역]' filter, then collapse '붉은마루 산맥' group header and verify /reload persistence
    rt._fire_widget_script(tracker["hereBtn"], "OnClick", "LeftButton")
    for w in _lua_list_items(tracker["rowWidgets"]):
        d = w.get("_rowData")
        if d and d.get("groupKey") == "zone:붉은마루 산맥":
            rt._fire_widget_script(w, "OnClick", "LeftButton")
            break

    assert rt.vm._invoke_callable(
        ns["ProfileManager"]["IsQuestGroupCollapsed"], (ns["ProfileManager"], "zone:붉은마루 산맥")
    )[0] is True

    ns_reloaded = rt.simulate_reload()
    pm_reloaded = ns_reloaded["ProfileManager"]
    assert rt.vm._invoke_callable(
        pm_reloaded["IsQuestGroupCollapsed"], (pm_reloaded, "zone:붉은마루 산맥")
    )[0] is True
    rendered_after = "\n".join(_visible_row_texts(ns_reloaded["QuestTracker"]))
    assert "검은바위 오크 소탕" not in rendered_after


def test_collapsed_blizzard_quest_log_header_recovers_watched_quest_and_zone_name() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    # Simulate player collapsing '엘윈 숲' inside Blizzard's L Quest Log (only first 6 entries shown)
    rt.quest_num_shown_entries = 6
    rt.watched_quest_ids = [101, 301]

    ns = rt.boot_session()
    snap = ns["QuestTracker"]["lastSnapshot"]
    groups = _lua_list_items(snap["groups"])
    group_titles = [g["title"] for g in groups]

    # Both watched quest 301 AND unwatched quest 302 under collapsed '엘윈 숲' must be recovered!
    assert "엘윈 숲" in group_titles
    assert snap["totalQuests"] == 6
    assert snap["visibleQuests"] == 6


# ---------------------------------------------------------------------------
# 3. AC-QT-4: Interactive Controls (SuperTrack, Fold, Shift-Watch, Minimize, Scroll, Drag, Slash & Settings)
# ---------------------------------------------------------------------------


def _is_matching_quest_row(data: Any, quest_id: int) -> bool:
    if not data:
        return False
    return data.get("kind") == "quest" and data.get("questID") == quest_id


def _find_quest_row_widget(tracker: LuaTable, quest_id: int) -> LuaTable:
    for w in _lua_list_items(tracker["rowWidgets"]):
        if _is_matching_quest_row(w.get("_rowData"), quest_id):
            return w
    raise AssertionError(f"Quest row widget for questID={quest_id} not found")


def test_ac_qt4_supertrack_fold_watch_minimize_drag_and_slash_commands() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    rt.watched_quest_ids = [101, 102, 201, 202, 301, 302]
    ns = rt.boot_session()
    tracker = ns["QuestTracker"]

    # 1. Left-click quest 101 -> sets SuperTrackedQuestID = 101; second click clears to 0
    row_101 = _find_quest_row_widget(tracker, 101)
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.super_tracked_quest_id == 101
    assert rt.selected_quest_id == 101

    row_101 = _find_quest_row_widget(tracker, 101)
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.super_tracked_quest_id == 0

    # 2. Right-click quest 101 -> folds its objective lines locally (shows [+])
    row_101 = _find_quest_row_widget(tracker, 101)
    rt._fire_widget_script(row_101, "OnClick", "RightButton")
    row_101 = _find_quest_row_widget(tracker, 101)
    assert "[+]" in row_101["_rightText"]["_text"]
    assert not any("에드윈 밴클리프" in t for t in _visible_row_texts(tracker))

    # 3. Shift + Left-click quest 101 -> untracks in Blizzard watch list; /fs quest watched hides untracked; /fs quest all reveals all
    rt.shift_down = True
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert 101 not in rt.watched_quest_ids
    assert any("데피아즈단 두목 처치" in t for t in _visible_row_texts(tracker))
    rt.run_slash("FOREVERSUITE", "quest watched")
    assert not any("데피아즈단 두목 처치" in t for t in _visible_row_texts(tracker))
    assert "미추적" in tracker["scrollHint"]["_text"]
    rt.run_slash("FOREVERSUITE", "quest all")
    rt.run_slash("FOREVERSUITE", "quest all")  # idempotent!
    assert any("데피아즈단 두목 처치" in t for t in _visible_row_texts(tracker))
    rt._fire_widget_script(_find_quest_row_widget(tracker, 101), "OnClick", "LeftButton")
    assert 101 in rt.watched_quest_ids
    rt.shift_down = False

    # 4. Minimize button collapses frame height to 30px header bar
    rt._fire_widget_script(tracker["minBtn"], "OnClick", "LeftButton")
    assert tracker["frame"]["_size"] == (308, 30)
    rt._fire_widget_script(tracker["minBtn"], "OnClick", "LeftButton")
    assert tracker["frame"]["_size"][1] > 30

    # 5. Dragging tracker saves anchor coordinates to ProfileManager
    f = tracker["frame"]
    f["SetPoint"](f, "TOPLEFT", rt.vm.G["UIParent"], "TOPLEFT", 140, -90)
    rt._fire_widget_script(f, "OnDragStop")
    assert rt.vm._invoke_callable(ns["ProfileManager"]["Get"], (ns["ProfileManager"], "quest", "trackerX"))[0] == 140
    assert rt.vm._invoke_callable(ns["ProfileManager"]["Get"], (ns["ProfileManager"], "quest", "trackerY"))[0] == -90

    # 6. Slash commands & SettingsPanel quick mode toggle
    rt.run_slash("FOREVERSUITE", "quest level")
    assert tracker["lastSnapshot"]["mode"] == "level"
    rt.run_slash("FOREVERSUITE", "ui")
    q_btn = ns["SettingsPanel"]["questModeBtn"]
    assert "레벨별" in q_btn["_fsLabel"]["_text"]
    rt._fire_widget_script(q_btn, "OnClick", "LeftButton")
    assert tracker["lastSnapshot"]["mode"] == "zone"
    assert "지역별" in q_btn["_fsLabel"]["_text"]

    rt.run_slash("FOREVERSUITE", "quest reset")
    assert rt.vm._invoke_callable(ns["ProfileManager"]["Get"], (ns["ProfileManager"], "quest", "trackerX"))[0] == -22


def test_mouse_wheel_scrolling_on_dense_quest_log() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.quest_log_entries = [{"title": "가시덤불 골짜기", "isHeader": True}]
    for idx in range(1, 16):
        qid = 500 + idx
        rt.quest_log_entries.append({"questID": qid, "title": f"밀림 수색 작전 #{idx}", "level": 35})
        rt.quest_objectives[qid] = [{"text": f"정찰 지점 {idx}: 0/1", "finished": False}]

    ns = rt.boot_session()
    tracker = ns["QuestTracker"]
    assert _lua_list_len(tracker["lastSnapshot"]["rows"]) > 18
    assert "휠 스크롤" in tracker["scrollHint"]["_text"]
    assert tracker["scrollOffset"] == 0

    rt._fire_widget_script(tracker["frame"], "OnMouseWheel", -1)
    assert tracker["scrollOffset"] == 2
    rt._fire_widget_script(tracker["frame"], "OnMouseWheel", 1)
    assert tracker["scrollOffset"] == 0


# ---------------------------------------------------------------------------
# 4. AC-QT-5: Zero-Taint Combat Lockdown, EditMode Respect, SecretValue Guard & Questie Yield
# ---------------------------------------------------------------------------


def test_ac_qt5_combat_lockdown_defers_default_tracker_and_zero_action_blocked() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    ns = rt.boot_session()
    otf = rt.vm.G["ObjectiveTrackerFrame"]

    # Out of combat on boot: ObjectiveTrackerFrame was cleanly hidden without taint
    assert otf["_shown"] is False
    assert rt.addon_action_blocked_count == 0

    # Enter Combat Lockdown and fire quest progress + /fs quest default (restore Blizzard tracker)
    rt.combat_lockdown = True
    rt.fire_event("PLAYER_REGEN_DISABLED")
    rt.fire_event("QUEST_LOG_UPDATE")
    rt.advance_time(0.20)
    assert rt.addon_action_blocked_count == 0

    # Request restoring default ObjectiveTrackerFrame WHILE in combat -> MUST defer to CombatQueue!
    rt.run_slash("FOREVERSUITE", "quest default")
    assert rt.addon_action_blocked_count == 0
    assert otf["_shown"] is False
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] >= 1

    # Leaving combat flushes CombatQueue and restores ObjectiveTrackerFrame with 0 blocked actions
    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    assert rt.addon_action_blocked_count == 0
    assert otf["_shown"] is True


def test_edit_mode_active_and_secret_values_and_questie_yield_and_zero_tickers() -> None:
    # 1. EditMode active -> ObjectiveTrackerFrame must NOT be force-hidden during EditMode!
    rt_em = WoWForeverMockRuntime(ADDON_ROOT)
    rt_em.vm.G["EditModeManagerFrame"] = LuaTable({"editModeActive": True})
    ns_em = rt_em.boot_session()
    assert rt_em.vm.G["ObjectiveTrackerFrame"]["_shown"] is True
    assert rt_em.vm._invoke_callable(ns_em["ModuleManager"]["TotalActiveTickers"], (ns_em["ModuleManager"],))[0] == 0

    # 2. SecretValue injection across player level, zone, quest info & objectives -> zero violation
    rt_sec = WoWForeverMockRuntime(ADDON_ROOT)
    rt_sec.player_level = SecretValue("UnitLevel:player")
    rt_sec.real_zone_text = SecretValue("GetRealZoneText", lua_type="string")
    rt_sec.quest_log_entries = [
        {"title": SecretValue("hdr", lua_type="string"), "isHeader": True},
        {"questID": SecretValue("secret_qid"), "title": "비밀 퀘스트", "level": 20},
        {"questID": 777, "title": "정상 퀘스트", "level": SecretValue("secret_lvl"), "isComplete": False},
    ]
    rt_sec.quest_objectives = {
        777: [
            {"text": SecretValue("secret_obj", lua_type="string"), "finished": False},
            {"text": "안전한 목표: 1/1", "finished": SecretValue("secret_fin")},
        ]
    }
    ns_sec = rt_sec.boot_session()
    snap_sec = ns_sec["QuestTracker"]["lastSnapshot"]
    assert snap_sec["totalQuests"] == 1
    rendered_sec = "\n".join(_visible_row_texts(ns_sec["QuestTracker"]))
    assert "정상 퀘스트" in rendered_sec
    assert "안전한 목표: 1/1" in rendered_sec

    # 3. Questie pre-loaded -> Quest module YIELDED, ForeverSuiteQuestTracker NOT created, ObjectiveTrackerFrame untouched
    rt_q = WoWForeverMockRuntime(ADDON_ROOT)
    rt_q.loaded_external_addons = {"Questie"}
    ns_q = rt_q.boot_session()
    assert ns_q["ModuleManager"]["modules"]["Quest"]["state"] == "YIELDED"
    assert rt_q.vm.G.get("ForeverSuiteQuestTracker") is None
    assert rt_q.vm.G["ObjectiveTrackerFrame"]["_shown"] is True


def test_readonly_profile_quest_slash_rejects_false_success_and_char_override_expands_account_collapse() -> None:
    # 1. Future schema READ_ONLY profile: mutating /fs quest subcommands must return False and never print success
    rt_ro = WoWForeverMockRuntime(ADDON_ROOT)
    rt_ro.vm.G["ForeverSuiteDB"] = LuaTable({"schemaVersion": 999, "account": LuaTable({"quest": LuaTable({"groupMode": "zone"})})})
    ns_ro = rt_ro.boot_session()
    quest_def = ns_ro["ModuleManager"]["modules"]["Quest"]["definition"]
    rt_ro.chat_messages.clear()

    for sub in ("mode", "zone", "level", "here", "lock", "min", "reset"):
        ok = rt_ro.vm._invoke_callable(quest_def["HandleSlash"], (quest_def, sub))[0]
        assert ok is False

    joined_msgs = "\n".join(rt_ro.chat_messages)
    assert "분류 모드:" not in joined_msgs
    assert "현재 지역 퀘스트 필터:" not in joined_msgs
    assert "초기화했습니다" not in joined_msgs

    # 2. Per-character SetQuestGroupCollapsed(key, False) must override account-level collapsedGroups[key] == True
    rt_ov = WoWForeverMockRuntime(ADDON_ROOT)
    ns_ov = rt_ov.boot_session()
    pm = ns_ov["ProfileManager"]
    pm["runtimeAccount"]["quest"]["collapsedGroups"]["zone:엘윈 숲"] = True
    assert rt_ov.vm._invoke_callable(pm["IsQuestGroupCollapsed"], (pm, "zone:엘윈 숲"))[0] is True

    assert rt_ov.vm._invoke_callable(pm["SetQuestGroupCollapsed"], (pm, "zone:엘윈 숲", False))[0] is True
    assert rt_ov.vm._invoke_callable(pm["IsQuestGroupCollapsed"], (pm, "zone:엘윈 숲"))[0] is False

    ns_ov2 = rt_ov.simulate_reload()
    pm2 = ns_ov2["ProfileManager"]
    assert rt_ov.vm._invoke_callable(pm2["IsQuestGroupCollapsed"], (pm2, "zone:엘윈 숲"))[0] is False


def test_edit_mode_disable_retains_restore_ownership_and_query_failures_avoid_fabricated_status() -> None:
    # 1. Hide default tracker -> enter Edit Mode -> disable Quest module -> exit Edit Mode -> restores default tracker!
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    em_frame = rt._make_frame("Frame", "EditModeManagerFrame", rt.vm.G["UIParent"])
    em_frame["editModeActive"] = False
    rt.vm.G["EditModeManagerFrame"] = em_frame

    ns = rt.boot_session()
    otf = rt.vm.G["ObjectiveTrackerFrame"]
    assert otf["_shown"] is False

    em_frame["editModeActive"] = True
    mm = ns["ModuleManager"]
    rt.vm._invoke_callable(mm["DisableModule"], (mm, "Quest"))
    assert otf["_shown"] is False

    em_frame["editModeActive"] = False
    rt._fire_widget_script(em_frame, "OnHide")
    assert otf["_shown"] is True

    # 2. Secret watched/questAccepted args + unavailable QuestLog / secret SuperTrack -> 0 violations, no fake '0'
    rt2 = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt2)
    ns2 = rt2.boot_session()
    model2 = ns2["QuestTrackerModel"]
    raw_secret_watch = LuaTable(
        [LuaTable({"questID": 801, "title": "비밀 감시 퀘스트", "isWatched": SecretValue("watch_sec")})]
    )
    snap_sw = rt2.vm._invoke_callable(
        model2["BuildSnapshot"], (raw_secret_watch, LuaTable({"watchedOnly": True}))
    )[0]
    assert snap_sw["visibleQuests"] == 0

    rt2.fire_event("QUEST_ACCEPTED", SecretValue("acc_idx"), SecretValue("acc_qid"))
    rt2.super_tracked_quest_id = 101
    rt2.vm._invoke_callable(ns2["QuestTracker"]["Refresh"], (ns2["QuestTracker"],))
    assert ns2["QuestTracker"]["lastSnapshot"]["groups"][1]["hasSuperTracked"] is True

    rt2.vm.G["C_SuperTrack"] = LuaTable({"GetSuperTrackedQuestID": lambda: SecretValue("st_sec")})
    rt2.quest_num_shown_entries = SecretValue("num_entries_sec")  # type: ignore[assignment]
    snap_unavail = rt2.vm._invoke_callable(ns2["QuestTracker"]["Refresh"], (ns2["QuestTracker"],))[0]
    assert snap_unavail["questLogUnavailable"] is True
    assert "—" in ns2["QuestTracker"]["headerTitle"]["_text"]
    assert "읽을 수 없습니다" in _visible_row_texts(ns2["QuestTracker"])[0]
    assert rt2.addon_action_blocked_count == 0


# ---------------------------------------------------------------------------
# 5. v0.3.0 QuestTracker ATDD/DDT (AC-2 Modifier Clicks/Lock & AC-7 Item Pool)
# ---------------------------------------------------------------------------


def _find_objective_row_widget(tracker: LuaTable, quest_id: int) -> LuaTable:
    for w in _lua_list_items(tracker["rowWidgets"]):
        d = w.get("_rowData")
        if d and d.get("kind") == "objective" and d.get("questID") == quest_id:
            return w
    raise AssertionError(f"Objective row widget for questID={quest_id} not found")


def _assert_ctrl_click_fallback_chain(rt: WoWForeverMockRuntime, row_101: LuaTable) -> None:
    rt.ctrl_down = True
    rt.opened_quest_details.clear()
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.opened_quest_details == [("OpenToQuestDetails", 101)]

    rt.vm.G["QuestMapFrame_OpenToQuestDetails"] = None
    rt.opened_quest_details.clear()
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.opened_quest_details == [("ShowQuestDetails", 101)]

    rt.vm.G["QuestMapFrame_ShowQuestDetails"] = None
    rt.opened_quest_details.clear()
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.opened_quest_details == [("ToggleQuestLog", 101)]

    rt.combat_lockdown = True
    rt.opened_quest_details.clear()
    rt.chat_messages.clear()
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert rt.opened_quest_details == []
    assert any("전투 중에는 퀘스트 상세 창을 열 수 없습니다" in m for m in rt.chat_messages)
    rt.combat_lockdown = False
    rt.ctrl_down = False


def test_v030_ac2_modifier_clicks_fallback_chain_objective_tooltip_and_tracker_lock() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    long_obj = "붉은마루 산맥 깊은 협곡 동굴 안쪽의 검은바위 지휘관 가르톡을 처치하고 작전 지령서 회수: 0/1"
    rt.quest_objectives[101] = [{"text": long_obj, "finished": False}]
    rt.watched_quest_ids = [101, 102, 201, 202, 301, 302]
    ns = rt.boot_session()
    tracker = ns["QuestTracker"]

    row_101 = _find_quest_row_widget(tracker, 101)
    _assert_ctrl_click_fallback_chain(rt, row_101)

    rt.active_chat_edit = LuaTable()
    rt.alt_down = True
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert len(rt.inserted_chat_links) == 1 and "Hquest:101" in rt.inserted_chat_links[0]
    rt.alt_down = False

    rt.shift_down = True
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert len(rt.inserted_chat_links) == 2
    assert 101 in rt.watched_quest_ids

    rt.active_chat_edit = None
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert 101 not in rt.watched_quest_ids
    rt._fire_widget_script(_find_quest_row_widget(tracker, 101), "OnClick", "LeftButton")
    assert 101 in rt.watched_quest_ids
    rt.shift_down = False

    obj_row = _find_objective_row_widget(tracker, 101)
    gt = rt.vm.G["GameTooltip"]
    rt._fire_widget_script(obj_row, "OnEnter")
    assert gt["IsShown"](gt) is True
    assert any(long_obj in line for line in gt["_lines"])
    assert any("데피아즈단 두목 처치" in line for line in gt["_lines"])
    rt._fire_widget_script(obj_row, "OnLeave")
    assert gt["IsShown"](gt) is False

    rt._fire_widget_script(tracker["lockBtn"], "OnClick", "LeftButton")
    assert rt.vm._invoke_callable(ns["ProfileManager"]["Get"], (ns["ProfileManager"], "quest", "trackerLocked"))[0] is True
    f = tracker["frame"]
    rt._fire_widget_script(f, "OnDragStart")
    assert f.get("_moving") is not True
    rt._fire_widget_script(_find_quest_row_widget(tracker, 102), "OnClick", "LeftButton")
    assert rt.super_tracked_quest_id == 102
    rt.run_slash("FOREVERSUITE", "quest lock")
    assert rt.vm._invoke_callable(ns["ProfileManager"]["Get"], (ns["ProfileManager"], "quest", "trackerLocked"))[0] is False


def test_v030_ac7_secure_quest_item_buttons_uiparent_isolation_and_combat_deferral() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    rt.quest_special_items = {
        101: ("|Hitem:5501|h[데피아즈단 신호탄]|h", 133710),
        201: ("|Hitem:5502|h[검은바위 폭탄]|h", 133711),
    }
    ns = rt.boot_session()
    ui_parent = rt.vm.G["UIParent"]
    tracker_frame = rt.vm.G["ForeverSuiteQuestTracker"]

    btn1 = rt.vm.G["ForeverSuiteQuestItemBtn1"]
    btn2 = rt.vm.G["ForeverSuiteQuestItemBtn2"]
    btn3 = rt.vm.G["ForeverSuiteQuestItemBtn3"]
    for idx in range(1, 7):
        btn = rt.vm.G[f"ForeverSuiteQuestItemBtn{idx}"]
        assert btn["_parent"] is ui_parent
        assert btn["_parent"] is not tracker_frame
        assert btn["_registered_clicks"] == ("AnyUp", "AnyDown")

    assert btn1["_shown"] is True and btn2["_shown"] is True and btn3["_shown"] is False
    assert btn1["_point"][1] is ui_parent
    assert btn1["_attrs"]["type"] == "item"
    assert btn1["_attrs"]["item"] == "|Hitem:5501|h[데피아즈단 신호탄]|h"
    assert btn1["_fsIcon"]["_tex"] == 133710

    # Enter combat, abandon Redridge quests so quest 101's logIndex shifts up, and add quest 103 with a new item!
    rt.combat_lockdown = True
    rt.fire_event("PLAYER_REGEN_DISABLED")
    rt.quest_log_entries = [
        {"title": "서부 몰락지대", "isHeader": True},
        {"questID": 103, "title": "오염된 우물 정화", "level": 20, "isComplete": False, "isOnMap": True},
        {"questID": 101, "title": "데피아즈단 두목 처치", "level": 23, "isComplete": False, "isOnMap": True},
    ]
    rt.quest_objectives[103] = [{"text": "정화수 살포: 0/1", "finished": False}]
    rt.quest_special_items[103] = ("|Hitem:5503|h[성스러운 정화수]|h", 134999)

    rt.fire_event("QUEST_LOG_UPDATE")
    rt.advance_time(0.20)
    assert rt.addon_action_blocked_count == 0
    assert rt.vm._invoke_callable(ns["CombatQueue"]["PendingCount"], (ns["CombatQueue"],))[0] >= 1

    # Leaving combat flushes queued item button sync using LIVE shifted questID -> logIndex resolution!
    rt.combat_lockdown = False
    rt.fire_event("PLAYER_REGEN_ENABLED")
    assert rt.addon_action_blocked_count == 0
    shown_links = [
        rt.vm.G[f"ForeverSuiteQuestItemBtn{i}"]["_attrs"]["item"]
        for i in range(1, 7)
        if rt.vm.G[f"ForeverSuiteQuestItemBtn{i}"]["_shown"]
    ]
    assert set(shown_links) == {"|Hitem:5503|h[성스러운 정화수]|h", "|Hitem:5501|h[데피아즈단 신호탄]|h"}


# 6. FS-QUEST-SYNC-FIX: Quest Log Parity, Migration, Noise Filtering & Truthful HUD Counts


def test_fs_quest_sync_default_all_migration_and_accept_watch_sync() -> None:
    rt_fresh = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt_fresh)
    rt_fresh.watched_quest_ids = [101]
    ns_fresh = rt_fresh.boot_session()
    pm_fresh = ns_fresh["ProfileManager"]
    assert rt_fresh.vm._invoke_callable(pm_fresh["Get"], (pm_fresh, "quest", "watchedOnly"))[0] is False
    assert rt_fresh.vm.G["ForeverSuiteDB"]["_migrations"]["watchedOnlyDefaultV2"] == 1
    assert ns_fresh["QuestTracker"]["lastSnapshot"]["visibleQuests"] == 6

    rt_fresh.run_slash("FOREVERSUITE", "quest watched")
    ns_fresh_re = rt_fresh.simulate_reload()
    assert rt_fresh.vm._invoke_callable(
        ns_fresh_re["ProfileManager"]["Get"], (ns_fresh_re["ProfileManager"], "quest", "watchedOnly")
    )[0] is True

    rt_mig = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt_mig)
    rt_mig.watched_quest_ids = [101]
    rt_mig.vm.G["ForeverSuiteDB"] = LuaTable(
        {"schemaVersion": 2, "account": LuaTable({"quest": LuaTable({"watchedOnly": True})})}
    )
    ns_mig = rt_mig.boot_session()
    assert rt_mig.vm.G["ForeverSuiteDB"]["schemaVersion"] == 2
    assert rt_mig.vm.G["ForeverSuiteDB"]["_migrations"]["watchedOnlyDefaultV2"] == 1
    assert rt_mig.vm._invoke_callable(
        ns_mig["ProfileManager"]["Get"], (ns_mig["ProfileManager"], "quest", "watchedOnly")
    )[0] is False
    assert ns_mig["QuestTracker"]["lastSnapshot"]["visibleQuests"] == 6
    assert any("/fs quest watched" in m for m in rt_mig.chat_messages)

    rt_mig.run_slash("FOREVERSUITE", "quest watched")
    ns_mig_re = rt_mig.simulate_reload()
    assert rt_mig.vm._invoke_callable(
        ns_mig_re["ProfileManager"]["Get"], (ns_mig_re["ProfileManager"], "quest", "watchedOnly")
    )[0] is True

    rt_mig.quest_log_entries.append({"questID": 401, "title": "신규 수락 퀘스트 A", "level": 24})
    rt_mig.fire_event("QUEST_ACCEPTED", 10, 401)
    assert 401 in rt_mig.watched_quest_ids and rt_mig.super_tracked_quest_id == 401

    rt_mig.quest_log_entries.append({"questID": 402, "title": "신규 수락 퀘스트 B", "level": 24})
    rt_mig.fire_event("QUEST_ACCEPTED", 402)
    assert 402 in rt_mig.watched_quest_ids

    rt_mig.quest_log_entries.append({"questID": 403, "title": "비밀 인자 복구 퀘스트", "level": 24})
    rt_mig.fire_event("QUEST_ACCEPTED", len(rt_mig.quest_log_entries), SecretValue("sec_qid"))
    assert 403 in rt_mig.watched_quest_ids

    rt_mig.cvars["autoQuestWatch"] = "0"
    rt_mig.quest_log_entries.append({"questID": 404, "title": "자동추적 꺼짐 퀘스트", "level": 24})
    rt_mig.fire_event("QUEST_ACCEPTED", 404)
    assert 404 not in rt_mig.watched_quest_ids
    rt_mig.cvars.pop("autoQuestWatch", None)
    rt_mig.super_tracked_quest_id = 401
    rt_mig.fire_event("QUEST_ACCEPTED", 0.5)
    rt_mig.fire_event("QUEST_ACCEPTED", float("inf"))
    assert 0 not in rt_mig.watched_quest_ids and rt_mig.super_tracked_quest_id == 401


def test_fs_quest_sync_hidden_headers_internal_tasks_and_collapsed_fallback_ddt() -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    rt.player_level = 24
    rt.real_zone_text = "서부 몰락지대"
    rt.zone_text = "서부 몰락지대"
    rt.quest_log_entries = [
        {"title": "서부 몰락지대", "isHeader": True},
        {"title": "숨김 내부 캠페인 헤더", "isHeader": True, "isHidden": True},
        {"questID": 101, "title": "정상 캠페인 퀘스트", "level": 23, "isStory": True},
        {"questID": 901, "title": "내부 플래그 퀘스트", "level": 23, "isInternalOnly": True},
        {"questID": 902, "title": "월드 보너스 태스크", "level": 23, "isTask": True},
        {"questID": 903, "title": "사절 현상금", "level": 23, "isBounty": True},
        {"questID": 904, "title": "숨김 퀘스트", "level": 23, "isHidden": True},
        None,  # Sparse nil hole past numShown
        {"title": "그늘숲", "isHeader": True, "isCollapsed": True},
        {"questID": 501, "title": "까마귀 언덕 수색", "level": 22},
        {"questID": 101, "title": "정상 캠페인 퀘스트 중복", "level": 23},  # Duplicate questID dedup check
    ]
    rt.quest_num_shown_entries = 7
    rt.watched_quest_ids = [101]  # 501 is unwatched AND past numShown AND after a nil hole!

    ns = rt.boot_session()
    tracker = ns["QuestTracker"]
    snap = tracker["lastSnapshot"]
    assert snap["totalQuests"] == 2
    assert snap["visibleQuests"] == 2

    groups = {g["title"]: g for g in _lua_list_items(snap["groups"])}
    assert set(groups.keys()) == {"서부 몰락지대", "그늘숲"}
    assert "숨김 내부 캠페인 헤더" not in groups

    # Also test fallback when C_QuestLog.GetHeaderIndexForQuest returns nil
    rt.vm.G["C_QuestLog"]["GetHeaderIndexForQuest"] = lambda _qid: None
    snap2 = rt.vm._invoke_callable(tracker["Refresh"], (tracker,))[0]
    groups2 = {g["title"]: g for g in _lua_list_items(snap2["groups"])}
    assert set(groups2.keys()) == {"서부 몰락지대", "그늘숲"}


@pytest.mark.parametrize(
    ("watched_only", "current_zone_only", "expected_vis", "expected_hw", "expected_hz", "expected_hint_sub"),
    [
        (False, False, 6, 0, 0, ""),
        (True, False, 2, 4, 0, "미추적 퀘스트 4개 숨김"),
        (False, True, 3, 0, 3, "타 지역 미완료 3개 숨김"),
        (True, True, 1, 4, 1, "미추적 4 · 타 지역 미완료 1개 숨김"),
    ],
)
def test_fs_quest_sync_disjoint_filter_counts_header_badge_and_no_false_current_zone_ddt(
    watched_only: bool,
    current_zone_only: bool,
    expected_vis: int,
    expected_hw: int,
    expected_hz: int,
    expected_hint_sub: str,
) -> None:
    rt = WoWForeverMockRuntime(ADDON_ROOT)
    _seed_sample_quest_log(rt)
    # Watched: 101 (current zone) and 201 (Redridge, incomplete)
    rt.watched_quest_ids = [101, 201]
    ns = rt.boot_session()
    pm = ns["ProfileManager"]
    tracker = ns["QuestTracker"]

    rt.vm._invoke_callable(pm["Set"], (pm, "quest", "watchedOnly", watched_only, "account"))
    rt.vm._invoke_callable(pm["Set"], (pm, "quest", "currentZoneOnly", current_zone_only, "account"))
    snap = tracker["lastSnapshot"]

    assert snap["visibleQuests"] == expected_vis
    assert snap["hiddenByWatch"] == expected_hw
    assert snap["hiddenByZone"] == expected_hz
    assert snap["hiddenByWatch"] + snap["hiddenByZone"] == snap["hiddenByFilter"]
    assert snap["totalQuests"] - snap["visibleQuests"] == snap["hiddenByFilter"]

    if expected_hint_sub:
        assert expected_hint_sub in tracker["scrollHint"]["_text"]
        assert "(6)" in tracker["headerTitle"]["_text"]
    else:
        assert tracker["scrollHint"]["_text"] == ""
        assert "(6)" not in tracker["headerTitle"]["_text"]

    # Standing in Stormwind with no exact zone header match: class/dungeon headers with isOnMap=True must NOT get '[현재 지역]'
    rt_city = WoWForeverMockRuntime(ADDON_ROOT)
    rt_city.player_level = 24
    rt_city.real_zone_text = "스톰윈드"
    rt_city.zone_text = "스톰윈드"
    rt_city.quest_log_entries = [
        {"title": "붉은마루 산맥", "isHeader": True},
        {"questID": 201, "title": "검은바위 오크 소탕", "level": 25, "isOnMap": False},
        {"title": "사제", "isHeader": True},
        {"questID": 601, "title": "빛의 은총 수련", "level": 20, "isOnMap": True},
    ]
    ns_city = rt_city.boot_session()
    city_groups = _lua_list_items(ns_city["QuestTracker"]["lastSnapshot"]["groups"])
    assert [g["title"] for g in city_groups] == ["사제", "붉은마루 산맥"]
    assert all(g["isCurrentZone"] is False for g in city_groups)
    assert "[현재 지역]" not in "\n".join(_visible_row_texts(ns_city["QuestTracker"]))


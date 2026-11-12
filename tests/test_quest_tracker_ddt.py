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

    # Quest 301 at index 8 must still be recovered with its true '엘윈 숲' header!
    assert "엘윈 숲" in group_titles
    assert snap["totalQuests"] == 5


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

    # 3. Shift + Left-click quest 101 -> untracks quest 101 and removes it from HUD; /fs quest all reveals untracked quests
    rt.shift_down = True
    rt._fire_widget_script(row_101, "OnClick", "LeftButton")
    assert 101 not in rt.watched_quest_ids
    assert not any("데피아즈단 두목 처치" in t for t in _visible_row_texts(tracker))
    rt.run_slash("FOREVERSUITE", "quest all")
    assert any("데피아즈단 두목 처치" in t for t in _visible_row_texts(tracker))
    rt._fire_widget_script(_find_quest_row_widget(tracker, 101), "OnClick", "LeftButton")
    assert 101 in rt.watched_quest_ids
    rt.shift_down = False
    rt.run_slash("FOREVERSUITE", "quest all")

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

    for sub in ("mode", "zone", "level", "here", "min", "reset"):
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

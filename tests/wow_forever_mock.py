"""Fail-Closed WoW Forever 1.60.1 (TOC 11701) Mock Runtime for Headless Addon Verification."""

from __future__ import annotations

import pathlib
from typing import Any, Callable

from binary_api_manifest import VERIFIED_WOWF_16001_C_APIS
from lua51_engine import Lua51VM, LuaTable, MultiReturn


class FailClosedUnknownAPIError(Exception):
    """Raised when addon code invokes an unverified C_* API method (Contract Clause 0)."""


class SecretValueViolationError(Exception):
    """Raised when addon code attempts arithmetic, comparison, or concat on a C_Secrets value (AC-4)."""


class SecretValue:
    """Opaque WoW 1.60.1 C_Secrets value (reports type(v)=='number' in Lua, traps math/comparisons)."""

    def __init__(self, label: str = "secret", lua_type: str = "number") -> None:
        self.label = label
        self._lua_type = lua_type

    def _secret_guard(self, op: str) -> None:
        raise SecretValueViolationError(f"Illegal '{op}' operation on WoW SecretValue({self.label})")

    def __lt__(self, other: Any) -> bool:
        self._secret_guard("<")
        return False

    def __le__(self, other: Any) -> bool:
        self._secret_guard("<=")
        return False

    def __gt__(self, other: Any) -> bool:
        self._secret_guard(">")
        return False

    def __ge__(self, other: Any) -> bool:
        self._secret_guard(">=")
        return False

    def __add__(self, other: Any) -> Any:
        self._secret_guard("+")

    def __radd__(self, other: Any) -> Any:
        self._secret_guard("+")

    def __sub__(self, other: Any) -> Any:
        self._secret_guard("-")

    def __mul__(self, other: Any) -> Any:
        self._secret_guard("*")

    def __truediv__(self, other: Any) -> Any:
        self._secret_guard("/")


class StrictCNamespaceTable(LuaTable):
    """Fail-closed C_* namespace table: accessing an unverified method raises FailClosedUnknownAPIError."""

    def __init__(self, namespace_name: str, methods: dict[str, Callable[..., Any]]) -> None:
        super().__init__(methods)
        self._ns_name = namespace_name

    def get(self, key: Any) -> Any:
        full_name = f"{self._ns_name}.{key}"
        if full_name not in VERIFIED_WOWF_16001_C_APIS:
            raise FailClosedUnknownAPIError(
                f"Unverified API access blocked (Fail-Closed): {full_name} is not in WoW Forever 1.60.1 manifest"
            )
        return super().get(key)


class WoWForeverMockRuntime:
    def __init__(self, addon_root: pathlib.Path) -> None:
        self.addon_root = addon_root
        self.vm = Lua51VM()
        self.now: float = 1000.0
        self.combat_lockdown: bool = False
        self.shift_down: bool = False
        self.resting: bool = False
        self.in_guild: bool = True
        self.can_merchant_repair: bool = True
        self.repair_cost: int = 0
        self.can_guild_repair: bool = False
        self.guild_withdraw_limit: int = 0
        self.guild_bank_money: int = 0
        self.player_money: int = 100_000  # 10g
        self.player_name: str = "Arthas"
        self.realm_name: str = "ForeverKR"
        self.player_class: str = "MAGE"
        self.player_hp: Any = 1000
        self.player_max_hp: Any = 1000
        self.player_dead: bool = False
        self.player_auras: dict[int, LuaTable] = {}
        self.known_spells: set[int] = {1459, 1243, 6673, 1126, 7620}
        self.equipped_items: dict[int, int] = {}
        self.loaded_external_addons: set[str] = set()
        self.cvars: dict[str, str] = {
            "autoLootDefault": "1",
            "countdownForCooldowns": "0",
            "Sound_SFXVolume": "0.5",
            "Sound_MusicVolume": "0.6",
        }
        self.profiler_enabled: bool = False
        self.profiler_avg_ms: float = 0.018
        self.addon_mem_kb: float = 640.0
        self.mem_update_calls: int = 0

        # Bags: bagIndex -> {numSlots, slots: {slotIdx: dict}}
        self.bags: dict[int, dict[str, Any]] = {
            b: {"num_slots": 16, "items": {}} for b in range(5)
        }
        # Item DB: itemID -> (name, link, quality, ilvl, reqLvl, itemType, itemSubType, maxStack, equipLoc, tex, sellPrice, classID, subClassID)
        self.item_db: dict[int, tuple[Any, ...]] = {
            9001: ("깨진 늑대 송곳니", "|Hitem:9001|h[깨진 늑대 송곳니]|h", 0, 5, 1, "기타", "잡동사니", 20, "", 134000, 125, 15, 0),
            9002: ("낡은 가죽 조각", "|Hitem:9002|h[낡은 가죽 조각]|h", 0, 5, 1, "기타", "잡동사니", 20, "", 134001, 200, 15, 0),
            9099: ("추억의 회색 반지", "|Hitem:9099|h[추억의 회색 반지]|h", 0, 1, 1, "기타", "잡동사니", 1, "", 134002, 500, 15, 0),
            2001: ("수습생의 지팡이", "|Hitem:2001|h[수습생의 지팡이]|h", 2, 18, 10, "무기", "지팡이", 1, "INVTYPE_2HWEAPON", 135145, 1850, 2, 10),
            6256: ("낚싯대", "|Hitem:6256|h[낚싯대]|h", 1, 5, 1, "무기", "낚싯대", 1, "INVTYPE_2HWEAPON", 132932, 20, 2, 20),
            2770: ("구리 광석", "|Hitem:2770|h[구리 광석]|h", 1, 5, 1, "직업용품", "금속 및 암석", 20, "", 134566, 15, 7, 7),
        }

        # Map & Waypoint state
        self.current_map_id: int | None = 1429  # Elwynn Forest
        self.player_pos: tuple[float, float] | None = (0.425, 0.652)
        self.can_set_waypoint: bool = True
        self.user_waypoint: Any = None
        self.super_tracked_waypoint: bool = False
        self.super_tracked_quest_id: int | None = None

        # Quest & Loot state
        self.quest_completable: bool = True
        self.quest_num_choices: int = 0
        self.accepted_quests: int = 0
        self.completed_quests: int = 0
        self.rewarded_choices: list[Any] = []
        self.loot_slots: list[int] = []
        self.looted_slots: list[int] = []

        # Tracking types
        self.tracking_types: list[dict[str, Any]] = [
            {"name": "광물 찾기", "active": False, "type": "spell"},
        ]

        # Security / Telemetry counters
        self.addon_action_blocked_count: int = 0
        self.repair_calls: list[bool] = []
        self.sold_bag_slots: list[tuple[int, int]] = []
        self.override_bindings: dict[Any, tuple[str, str]] = {}
        self.chat_messages: list[str] = []
        self.frames: list[LuaTable] = []
        self.scheduled_timers: list[tuple[float, Callable[..., Any]]] = []
        self.active_tickers: list[LuaTable] = []
        self.tooltip_post_calls: list[Callable[..., Any]] = []

        self._install_wow_globals()
        self.baseline_global_keys = set(self.vm.G.keys())

    def _make_frame(self, frame_type: str, name: str | None = None, parent: Any = None, template: str | None = None) -> LuaTable:
        f = LuaTable()
        f["_type"] = frame_type
        f["_name"] = name
        f["_parent"] = parent
        f["_template"] = template
        f["_shown"] = frame_type != "Frame" or name in ("UIParent", "WorldFrame")
        if name in ("WorldMapFrame",):
            f["_shown"] = False
        f["_events"] = set()
        f["_scripts"] = {}
        f["_hooks"] = {}
        f["_attrs"] = {}
        f["_text"] = ""

        is_secure = bool(template and "Secure" in str(template))

        def register_event(self_f: LuaTable, ev: str) -> None:
            self_f["_events"].add(ev)

        def register_unit_event(self_f: LuaTable, ev: str, _unit: str) -> None:
            self_f["_events"].add(ev)

        def unregister_event(self_f: LuaTable, ev: str) -> None:
            self_f["_events"].discard(ev)

        def unregister_all(self_f: LuaTable) -> None:
            self_f["_events"].clear()

        def set_script(self_f: LuaTable, handler_name: str, fn: Any) -> None:
            if fn is None:
                self_f["_scripts"].pop(handler_name, None)
            else:
                self_f["_scripts"][handler_name] = fn

        def hook_script(self_f: LuaTable, handler_name: str, fn: Any) -> None:
            hooks = self_f["_hooks"].setdefault(handler_name, [])
            hooks.append(fn)

        def show(self_f: LuaTable) -> None:
            if is_secure and self.combat_lockdown:
                self._record_blocked("SecureFrame:Show")
                return
            was_shown = self_f["_shown"]
            self_f["_shown"] = True
            if not was_shown:
                self._fire_widget_script(self_f, "OnShow")

        def hide(self_f: LuaTable) -> None:
            if is_secure and self.combat_lockdown:
                self._record_blocked("SecureFrame:Hide")
                return
            was_shown = self_f["_shown"]
            self_f["_shown"] = False
            if was_shown:
                self._fire_widget_script(self_f, "OnHide")

        def set_attribute(self_f: LuaTable, k: str, v: Any) -> None:
            if self.combat_lockdown:
                self._record_blocked("SecureFrame:SetAttribute")
                return
            self_f["_attrs"][k] = v

        def create_texture(self_f: LuaTable, *_a: Any) -> LuaTable:
            tex = LuaTable()
            tex["SetAllPoints"] = lambda *_x: None
            tex["SetPoint"] = lambda *_x: None
            tex["SetSize"] = lambda *_x: None
            tex["SetWidth"] = lambda *_x: None
            tex["SetHeight"] = lambda *_x: None
            tex["SetColorTexture"] = lambda *_x: None
            return tex

        def create_font_string(self_f: LuaTable, *_a: Any) -> LuaTable:
            fs = LuaTable()
            fs["_text"] = ""
            fs["SetText"] = lambda s, t: s.set("_text", str(t))
            fs["GetText"] = lambda s: s.get("_text")
            fs["SetPoint"] = lambda *_x: None
            fs["SetTextColor"] = lambda *_x: None
            return fs

        f["RegisterEvent"] = register_event
        f["RegisterUnitEvent"] = register_unit_event
        f["UnregisterEvent"] = unregister_event
        f["UnregisterAllEvents"] = unregister_all
        f["SetScript"] = set_script
        f["HookScript"] = hook_script
        f["Show"] = show
        f["Hide"] = hide
        f["IsShown"] = lambda self_f: bool(self_f["_shown"])
        f["SetSize"] = lambda *_x: None
        f["SetWidth"] = lambda *_x: None
        f["SetHeight"] = lambda *_x: None
        f["SetPoint"] = lambda *_x: None
        f["SetMovable"] = lambda *_x: None
        f["EnableMouse"] = lambda *_x: None
        f["RegisterForDrag"] = lambda *_x: None
        f["StartMoving"] = lambda *_x: None
        f["StopMovingOrSizing"] = lambda *_x: None
        f["SetAttribute"] = set_attribute
        f["CreateTexture"] = create_texture
        f["CreateFontString"] = create_font_string

        if name:
            self.vm.G[name] = f
        self.frames.append(f)
        return f

    def _fire_widget_script(self, frame: LuaTable, script_name: str, *args: Any) -> None:
        primary = frame["_scripts"].get(script_name)
        if callable(primary):
            self.vm._invoke_callable(primary, (frame, *args))
        for hook in list(frame["_hooks"].get(script_name, [])):
            if callable(hook):
                self.vm._invoke_callable(hook, (frame, *args))

    def _record_blocked(self, action_desc: str) -> None:
        self.addon_action_blocked_count += 1
        self.fire_event("ADDON_ACTION_BLOCKED", "ForeverSuite", action_desc)

    def _install_wow_globals(self) -> None:
        G = self.vm.G

        G["UIParent"] = self._make_frame("Frame", "UIParent")
        G["WorldFrame"] = self._make_frame("Frame", "WorldFrame")
        wmf = self._make_frame("Frame", "WorldMapFrame")
        wmf["GetMapID"] = lambda _s: self.current_map_id

        chat = LuaTable()
        chat["AddMessage"] = lambda _s, msg: self.chat_messages.append(str(msg))
        G["DEFAULT_CHAT_FRAME"] = chat

        gt = LuaTable()
        gt["_lines"] = []
        gt["SetOwner"] = lambda *_a: None
        gt["AddLine"] = lambda s, txt, *_c: s["_lines"].append(str(txt))
        gt["AddDoubleLine"] = lambda s, l, r, *_c: s["_lines"].append(f"{l}::{r}")
        gt["Show"] = lambda *_a: None
        gt["Hide"] = lambda *_a: None
        G["GameTooltip"] = gt

        G["SlashCmdList"] = LuaTable()
        G["Enum"] = LuaTable(
            {
                "ItemQuality": LuaTable({"Poor": 0, "Common": 1, "Uncommon": 2, "Rare": 3, "Epic": 4}),
                "TooltipDataType": LuaTable({"Item": 0}),
                "AddOnProfilerMetric": LuaTable({"RecentAverageTime": 1}),
            }
        )

        tdp = LuaTable()
        tdp["AddTooltipPostCall"] = lambda _dtype, fn: self.tooltip_post_calls.append(fn)
        G["TooltipDataProcessor"] = tdp

        G["Settings"] = LuaTable(
            {
                "RegisterCanvasLayoutCategory": lambda canvas, name: LuaTable({"canvas": canvas, "name": name}),
                "RegisterAddOnCategory": lambda _cat: None,
            }
        )
        G["UiMapPoint"] = LuaTable(
            {
                "CreateFromCoordinates": lambda map_id, x, y: LuaTable(
                    {"uiMapID": map_id, "position": LuaTable({"x": x, "y": y})}
                )
            }
        )

        G["CreateFrame"] = lambda ftype, name=None, parent=None, template=None: self._make_frame(
            ftype, name, parent, template
        )
        G["GetBuildInfo"] = lambda: MultiReturn(("1.60.1", "70707", "Oct 28 2026", 11701))
        G["GetTime"] = lambda: self.now
        G["InCombatLockdown"] = lambda: self.combat_lockdown
        G["issecretvalue"] = lambda v: isinstance(v, SecretValue)
        G["debugstack"] = lambda *_a: "MockStack:line 1"
        G["IsShiftKeyDown"] = lambda: self.shift_down
        G["IsModifiedClick"] = lambda _k: False
        G["IsResting"] = lambda: self.resting
        G["IsInGuild"] = lambda: self.in_guild
        G["UnitName"] = lambda _u: self.player_name
        G["GetRealmName"] = lambda: self.realm_name
        G["UnitClass"] = lambda _u: MultiReturn((self.player_class.title(), self.player_class))
        G["UnitHealth"] = lambda _u: self.player_hp
        G["UnitHealthMax"] = lambda _u: self.player_max_hp
        G["UnitIsDeadOrGhost"] = lambda _u: self.player_dead
        G["GetInventoryItemID"] = lambda _u, slot: self.equipped_items.get(int(slot))

        G["GetMoney"] = lambda: self.player_money
        G["CanMerchantRepair"] = lambda: self.can_merchant_repair
        G["GetRepairAllCost"] = lambda: MultiReturn((self.repair_cost, self.repair_cost > 0))
        G["CanGuildBankRepair"] = lambda: self.can_guild_repair
        G["GetGuildBankWithdrawMoney"] = lambda: self.guild_withdraw_limit
        G["GetGuildBankMoney"] = lambda: self.guild_bank_money

        def repair_all(use_guild: bool = False) -> None:
            flag = bool(use_guild)
            self.repair_calls.append(flag)
            if not flag:
                self.player_money -= self.repair_cost
                self.fire_event("PLAYER_MONEY")
            self.repair_cost = 0

        G["RepairAllItems"] = repair_all
        G["GetNumLootItems"] = lambda: len(self.loot_slots)
        G["LootSlot"] = lambda slot: self.looted_slots.append(int(slot))

        G["QuestGetAutoAccept"] = lambda: False
        G["AcceptQuest"] = lambda: setattr(self, "accepted_quests", self.accepted_quests + 1)
        G["IsQuestCompletable"] = lambda: self.quest_completable
        G["CompleteQuest"] = lambda: setattr(self, "completed_quests", self.completed_quests + 1)
        G["GetNumQuestChoices"] = lambda: self.quest_num_choices

        def get_quest_reward(choice: Any = None) -> None:
            self.rewarded_choices.append(choice)

        G["GetQuestReward"] = get_quest_reward

        def set_override_binding_click(owner: Any, _is_priority: bool, key: str, btn_name: str) -> None:
            if self.combat_lockdown:
                self._record_blocked("SetOverrideBindingClick")
                return
            self.override_bindings[owner] = (key, btn_name)

        def clear_override_bindings(owner: Any) -> None:
            if self.combat_lockdown:
                self._record_blocked("ClearOverrideBindings")
                return
            self.override_bindings.pop(owner, None)

        G["SetOverrideBindingClick"] = set_override_binding_click
        G["ClearOverrideBindings"] = clear_override_bindings
        G["UpdateAddOnMemoryUsage"] = lambda: setattr(self, "mem_update_calls", self.mem_update_calls + 1)
        G["GetAddOnMemoryUsage"] = lambda _name: self.addon_mem_kb

        # Strict Fail-Closed C_* Namespaces
        G["C_AddOns"] = StrictCNamespaceTable(
            "C_AddOns",
            {
                "IsAddOnLoaded": lambda name: str(name) in self.loaded_external_addons,
                "DoesAddOnExist": lambda name: str(name) in self.loaded_external_addons,
                "LoadAddOn": lambda name: MultiReturn((str(name) in self.loaded_external_addons, None)),
            },
        )
        G["C_AddOnProfiler"] = StrictCNamespaceTable(
            "C_AddOnProfiler",
            {
                "IsEnabled": lambda: self.profiler_enabled,
                "GetAddOnMetric": lambda _name, _metric: self.profiler_avg_ms,
            },
        )
        G["C_CVar"] = StrictCNamespaceTable(
            "C_CVar",
            {
                "GetCVar": lambda k: self.cvars.get(str(k)),
                "SetCVar": lambda k, v: self.cvars.__setitem__(str(k), str(v)),
            },
        )

        def get_container_item_info(bag: int, slot: int) -> LuaTable | None:
            item = self.bags.get(int(bag), {}).get("items", {}).get(int(slot))
            if not item:
                return None
            return LuaTable(item)

        def use_container_item(bag: int, slot: int, *_a: Any) -> None:
            b, s = int(bag), int(slot)
            item = self.bags.get(b, {}).get("items", {}).pop(s, None)
            if item:
                self.sold_bag_slots.append((b, s))
                info = self.item_db.get(item["itemID"])
                sell_price = info[10] if info else 0
                self.player_money += sell_price * item.get("stackCount", 1)
                self.fire_event("PLAYER_MONEY")

        G["C_Container"] = StrictCNamespaceTable(
            "C_Container",
            {
                "GetContainerNumSlots": lambda bag: self.bags.get(int(bag), {}).get("num_slots", 0),
                "GetContainerNumFreeSlots": lambda bag: MultiReturn(
                    (
                        self.bags.get(int(bag), {}).get("num_slots", 0)
                        - len(self.bags.get(int(bag), {}).get("items", {})),
                        0,
                    )
                ),
                "GetContainerItemInfo": get_container_item_info,
                "GetContainerItemID": lambda bag, slot: (
                    self.bags.get(int(bag), {}).get("items", {}).get(int(slot), {}).get("itemID")
                ),
                "UseContainerItem": use_container_item,
                "SortBags": lambda: None,
            },
        )

        def get_item_info(item_id: Any) -> Any:
            row = self.item_db.get(int(item_id))
            if not row:
                return MultiReturn((None,))
            return MultiReturn(row)

        G["C_Item"] = StrictCNamespaceTable(
            "C_Item",
            {
                "GetItemInfo": get_item_info,
                "GetDetailedItemLevelInfo": lambda item_id: (
                    self.item_db[int(item_id)][3] if int(item_id) in self.item_db else None
                ),
            },
        )

        def get_player_map_pos(_map_id: int, _unit: str) -> LuaTable | None:
            if self.player_pos is None:
                return None
            px, py = self.player_pos
            return LuaTable({"x": px, "y": py, "GetXY": lambda _s: MultiReturn((px, py))})

        G["C_Map"] = StrictCNamespaceTable(
            "C_Map",
            {
                "GetBestMapForUnit": lambda _u: self.current_map_id,
                "GetPlayerMapPosition": get_player_map_pos,
                "GetMapInfo": lambda mid: LuaTable({"mapID": mid, "name": "Elwynn Forest"}),
                "CanSetUserWaypointOnMap": lambda _mid: self.can_set_waypoint,
                "SetUserWaypoint": lambda pt: setattr(self, "user_waypoint", pt),
                "ClearUserWaypoint": lambda: setattr(self, "user_waypoint", None),
            },
        )
        G["C_SuperTrack"] = StrictCNamespaceTable(
            "C_SuperTrack",
            {
                "SetSuperTrackedUserWaypoint": lambda flag: setattr(self, "super_tracked_waypoint", bool(flag)),
                "SetSuperTrackedQuestID": lambda qid: setattr(self, "super_tracked_quest_id", int(qid)),
            },
        )
        G["C_QuestLog"] = StrictCNamespaceTable(
            "C_QuestLog",
            {
                "GetNumQuestLogEntries": lambda: MultiReturn((0, 0)),
                "GetInfo": lambda _idx: None,
                "GetDistanceSqToQuest": lambda _qid: MultiReturn((100.0, True)),
            },
        )
        G["C_Spell"] = StrictCNamespaceTable(
            "C_Spell",
            {
                "GetSpellInfo": lambda sid: LuaTable(
                    {
                        "name": {1459: "신비한 지능", 1243: "신의 권능: 인내", 6673: "전투의 외침", 1126: "야생의 징표", 7620: "낚시"}.get(
                            int(sid), f"Spell#{sid}"
                        ),
                        "spellID": int(sid),
                    }
                ),
                "IsSpellKnown": lambda sid: int(sid) in self.known_spells,
            },
        )
        G["C_UnitAuras"] = StrictCNamespaceTable(
            "C_UnitAuras",
            {
                "GetPlayerAuraBySpellID": lambda sid: self.player_auras.get(int(sid)),
                "GetAuraDataByIndex": lambda _u, _idx, _f=None: None,
            },
        )
        G["C_Minimap"] = StrictCNamespaceTable(
            "C_Minimap",
            {
                "GetNumTrackingTypes": lambda: len(self.tracking_types),
                "GetTrackingInfo": lambda idx: LuaTable(self.tracking_types[int(idx) - 1]),
            },
        )

        def timer_after(delay: float, cb: Callable[..., Any]) -> None:
            self.scheduled_timers.append((self.now + float(delay), cb))

        def timer_new_ticker(interval: float, cb: Callable[..., Any]) -> LuaTable:
            t = LuaTable()
            t["_interval"] = float(interval)
            t["_cb"] = cb
            t["_cancelled"] = False
            t["Cancel"] = lambda self_t: self_t.set("_cancelled", True)
            t["IsCancelled"] = lambda self_t: bool(self_t.get("_cancelled"))
            self.active_tickers.append(t)
            return t

        G["C_Timer"] = StrictCNamespaceTable(
            "C_Timer",
            {
                "After": timer_after,
                "NewTicker": timer_new_ticker,
            },
        )

    def parse_toc_files(self) -> tuple[dict[str, str], list[pathlib.Path]]:
        toc_path = self.addon_root / "ForeverSuite.toc"
        meta: dict[str, str] = {}
        files: list[pathlib.Path] = []
        for raw in toc_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line:
                continue
            if line.startswith("##"):
                kv = line[2:].strip()
                if ":" in kv:
                    k, v = kv.split(":", 1)
                    meta[k.strip()] = v.strip()
                continue
            if line.startswith("#"):
                continue
            files.append(self.addon_root / line)
        return meta, files

    def load_addon(self, addon_name: str = "ForeverSuite") -> LuaTable:
        _, files = self.parse_toc_files()
        shared_ns = LuaTable()
        for lua_file in files:
            src = lua_file.read_text(encoding="utf-8")
            self.vm.run_chunk(src, filename=lua_file.name, chunk_args=(addon_name, shared_ns))
        return shared_ns

    def boot_session(self) -> LuaTable:
        ns = self.load_addon("ForeverSuite")
        self.fire_event("ADDON_LOADED", "ForeverSuite")
        self.fire_event("PLAYER_LOGIN")
        self.fire_event("PLAYER_ENTERING_WORLD")
        return ns

    def simulate_reload(self) -> LuaTable:
        """Simulate WoW /reload: preserve SavedVariables tables while resetting runtime Lua state."""
        saved_acct = self.vm.G.get("ForeverSuiteDB")
        saved_char = self.vm.G.get("ForeverSuiteCharDB")

        self.vm = Lua51VM()
        self.frames.clear()
        self.scheduled_timers.clear()
        self.active_tickers.clear()
        self.tooltip_post_calls.clear()
        self._install_wow_globals()
        self.baseline_global_keys = set(self.vm.G.keys())

        if saved_acct is not None:
            self.vm.G["ForeverSuiteDB"] = saved_acct
        if saved_char is not None:
            self.vm.G["ForeverSuiteCharDB"] = saved_char

        return self.boot_session()

    def fire_event(self, event: str, *args: Any) -> None:
        for frame in list(self.frames):
            if event in frame["_events"]:
                on_event = frame["_scripts"].get("OnEvent")
                if callable(on_event):
                    self.vm._invoke_callable(on_event, (frame, event, *args))

    def advance_time(self, seconds: float) -> None:
        self.now += float(seconds)
        due = [item for item in self.scheduled_timers if item[0] <= self.now]
        self.scheduled_timers = [item for item in self.scheduled_timers if item[0] > self.now]
        for _, cb in due:
            self.vm._invoke_callable(cb, ())
        for ticker in list(self.active_tickers):
            if not ticker.get("_cancelled"):
                cb = ticker.get("_cb")
                if callable(cb):
                    self.vm._invoke_callable(cb, ())

    def run_slash(self, slash_key: str, msg: str = "") -> None:
        fn = self.vm.G["SlashCmdList"].get(slash_key)
        if not callable(fn):
            raise RuntimeError(f"Slash command {slash_key} is not registered")
        self.vm._invoke_callable(fn, (msg,))

    def leaked_globals(self) -> set[str]:
        current = set(self.vm.G.keys())
        frame_names = {f["_name"] for f in self.frames if f["_name"]}
        return current - self.baseline_global_keys - frame_names

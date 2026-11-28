use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use mlua::{Lua, MetaMethod, UserData, UserDataMethods, Value};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct TestSummary {
    pub total: usize,
    pub passed: usize,
}

/// C_Secrets proxy userdata: preserves underlying Lua type via overridden `type()`
/// and raises an error on arithmetic/relational/same-type equality/concat/len/tostring ops.
#[derive(Clone, Debug)]
struct SecretProxy {
    tag: String,
    underlying_type: String,
}

impl UserData for SecretProxy {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        macro_rules! deny_binop {
            ($mm:expr, $op:literal) => {
                methods.add_meta_method($mm, |_, this: &SecretProxy, _: Value| -> mlua::Result<Value> {
                    Err(mlua::Error::RuntimeError(format!(
                        "C_Secrets violation: illegal '{}' on secret value '{}'",
                        $op, this.tag
                    )))
                });
            };
        }
        deny_binop!(MetaMethod::Add, "add");
        deny_binop!(MetaMethod::Sub, "sub");
        deny_binop!(MetaMethod::Mul, "mul");
        deny_binop!(MetaMethod::Div, "div");
        deny_binop!(MetaMethod::Mod, "mod");
        deny_binop!(MetaMethod::Pow, "pow");
        deny_binop!(MetaMethod::Lt, "lt");
        deny_binop!(MetaMethod::Le, "le");
        deny_binop!(MetaMethod::Concat, "concat");
        methods.add_meta_method(MetaMethod::Unm, |_, this: &SecretProxy, ()| -> mlua::Result<Value> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'unm' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::Len, |_, this: &SecretProxy, ()| -> mlua::Result<usize> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'len' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::Eq, |_, this: &SecretProxy, _: Value| -> mlua::Result<bool> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'eq' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this: &SecretProxy, ()| -> mlua::Result<String> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'tostring' on secret value '{}'",
                this.tag
            )))
        });
    }
}

fn lua_err<T>(res: mlua::Result<T>) -> Result<T> {
    res.map_err(|e| anyhow::anyhow!("{e}"))
}

const WOW_MOCK_PRELUDE: &str = r#"
_G.__FS_ASSERT_COUNT = 0
local _raw_assert = assert
function assert(cond, msg)
    _G.__FS_ASSERT_COUNT = _G.__FS_ASSERT_COUNT + 1
    return _raw_assert(cond, msg)
end

local _raw_type = type
function type(v)
    local st = __FS_SECRET_TYPE(v)
    if st then return st end
    return _raw_type(v)
end

_G.__FS_MOCK = {
    inCombat = false,
    realm = "",
    realmFallback = "ForeverKR",
    worldMapShown = false,
    superTrackedQuestID = 0,
    userWaypoint = nil,
    loadedAddOns = {},
    addonExists = {},
    unitExists = {},
    cursorX = 0,
    cursorY = 0,
    tooltipPostCalls = {},
    frames = {},
    printed = {},
    events = {},
    now = 1000,
    money = 50000,
    bagFreeSlots = 12,
    questEntries = {},
    questComplete = {},
    questSpecialItems = {},
    errorsForwarded = {},
    objTrackerTouches = 0,
    shiftDown = false,
    ctrlDown = false,
    altDown = false,
    activeChatEdit = nil,
    insertedLinks = {},
    questWatched = {},
    questFlaggedCompleted = {},
    itemLevels = {},
    worldMapID = 1453,
    mapNames = { [1453] = "스톰윈드", [1454] = "오그리마", [1411] = "듀로타", [1429] = "엘윈 숲" },
    playerName = "영웅",
    unspentTalents = 0,
    inGroup = false,
    inRaid = false,
    groupMembers = 0,
    unitNames = { player = "영웅" },
    threatData = {},
    chatLockdown = false,
    sentChats = {},
    sentEmotes = {},
    spellNames = {},
    fontSetShouldFail = {},
    playerFaction = "Alliance",
    equippedItems = {},
    zoneText = "",
    durability = {},
    bagItems = {},
    soldItems = {},
    canRepair = false,
    repairCost = 0,
    canGuildRepair = false,
    guildWithdraw = -1,
    guildMoney = 100000,
    guildRepairShouldFail = false,
    asyncGuildRepair = false,
    deferMoneyEvents = false,
    auraSecret = false,
    clearWaypointCalls = 0,
    repairedGuild = false,
    repairedPersonal = false,
    buybackCount = 0,
    acceptedQuests = 0,
    turnedInQuests = 0,
    questChoices = 1,
    questPvp = false,
    questReqMoney = 0,
    questReqItems = 0,
    playerPos = nil,
    playerClass = "WARRIOR",
    knownSpells = {},
    activeAuras = {},
    mainHandEnchant = true,
    hp = 1000,
    hpMax = 1000,
    deadOrGhost = false,
    mainHandItemID = nil,
    targetGUID = nil,
    tickers = {},
    afterTimers = {},
    cvars = { autoLootDefault = "1" },
    lootCount = 0,
    lootedSlots = {},
    inInstance = false,
    instanceType = "none",
    instanceName = "",
    hasSoulstone = false,
    releasedSpirit = 0,
    affectingCombat = false,
    unitCombat = {},
    modifiedClicks = {},
    acceptedRes = 0,
    friends = {},
    guildMembers = {},
    acceptedGroup = 0,
    xp = 1000,
    xpMax = 10000,
    level = 20,
    maxLevel = 60,
    restedXP = 500,
}

function IsShiftKeyDown() return _G.__FS_MOCK.shiftDown == true end
function IsControlKeyDown() return _G.__FS_MOCK.ctrlDown == true end
function IsAltKeyDown() return _G.__FS_MOCK.altDown == true end
function GetQuestLink(qid) return "|cffffff00|Hquest:" .. tostring(qid) .. ":60|h[퀘스트 #" .. tostring(qid) .. "]|h|r" end
function ChatEdit_GetActiveWindow() return _G.__FS_MOCK.activeChatEdit end
function ChatFrame_OpenChat(text)
    _G.__FS_MOCK.openedChats = _G.__FS_MOCK.openedChats or {}
    local str = tostring(text or "")
    table.insert(_G.__FS_MOCK.openedChats, str)
    _G.__FS_MOCK.activeChatEdit = {
        _text = str,
        GetText = function(self) return self._text end,
        Insert = function(self, s) self._text = self._text .. tostring(s or "") end,
    }
end
function ChatEdit_InsertLink(link)
    if _G.__FS_MOCK.activeChatEdit then
        table.insert(_G.__FS_MOCK.insertedLinks, link)
        return true
    end
    return false
end
function IsModifiedClick(action)
    local mc = _G.__FS_MOCK.modifiedClicks
    if mc and mc[action] ~= nil then return mc[action] end
    if action == "AUTOLOOTTOGGLE" then return _G.__FS_MOCK.shiftDown == true end
    return false
end
function GetNumLootItems() return _G.__FS_MOCK.lootCount end
function LootSlot(slot) table.insert(_G.__FS_MOCK.lootedSlots, slot) end
function IsInInstance() return _G.__FS_MOCK.inInstance, _G.__FS_MOCK.instanceType end
function GetInstanceInfo() return _G.__FS_MOCK.instanceName, _G.__FS_MOCK.instanceType end
function HasSoulstone() return _G.__FS_MOCK.hasSoulstone end
function RepopMe() _G.__FS_MOCK.releasedSpirit = _G.__FS_MOCK.releasedSpirit + 1 end
function UnitAffectingCombat(unit)
    if unit and unit ~= "player" and _G.__FS_MOCK.unitCombat and _G.__FS_MOCK.unitCombat[unit] ~= nil then
        return _G.__FS_MOCK.unitCombat[unit]
    end
    return _G.__FS_MOCK.affectingCombat
end
function UnitExists(unit)
    if _G.__FS_MOCK.unitExists and _G.__FS_MOCK.unitExists[unit] ~= nil then
        return _G.__FS_MOCK.unitExists[unit]
    end
    return unit ~= nil and unit ~= ""
end
function GetCursorPosition()
    return _G.__FS_MOCK.cursorX or 0, _G.__FS_MOCK.cursorY or 0
end
function AcceptResurrect() _G.__FS_MOCK.acceptedRes = _G.__FS_MOCK.acceptedRes + 1 end
function GetNumGuildMembers() return #(_G.__FS_MOCK.guildMembers or {}) end
function GetGuildRosterInfo(i) return (_G.__FS_MOCK.guildMembers or {})[i] end
function AcceptGroup() _G.__FS_MOCK.acceptedGroup = _G.__FS_MOCK.acceptedGroup + 1 end
function UnitXP() return _G.__FS_MOCK.xp end
function UnitXPMax() return _G.__FS_MOCK.xpMax end
function UnitLevel() return _G.__FS_MOCK.level end
function GetMaxPlayerLevel() return _G.__FS_MOCK.maxLevel end
function GetXPExhaustion() return _G.__FS_MOCK.restedXP end
function GetRealZoneText() return _G.__FS_MOCK.zoneText or "" end
function GetPlayerFacing() return _G.__FS_MOCK.playerPos and _G.__FS_MOCK.playerPos.facing or nil end
function UnitClass(u)
    local c = _G.__FS_MOCK.playerClass
    return c, c
end
function UnitName(u)
    if u == "player" or not u then return _G.__FS_MOCK.playerName end
    return (_G.__FS_MOCK.unitNames or {})[u]
end
function UnitIsUnit(a, b)
    if a == b then return true end
    local map = _G.__FS_MOCK.unitIsPlayer or {}
    if b == "player" and map[a] == true then return true end
    if a == "player" and map[b] == true then return true end
    return false
end
function UnitCharacterPoints() return _G.__FS_MOCK.unspentTalents end
function IsInGroup() return _G.__FS_MOCK.inGroup == true end
function IsInRaid() return _G.__FS_MOCK.inRaid == true end
function GetNumGroupMembers() return _G.__FS_MOCK.groupMembers or 0 end
function UnitDetailedThreatSituation(unit, target)
    local d = (_G.__FS_MOCK.threatData or {})[unit]
    if not d then return nil end
    return d[1], d[2], d[3], d[4], d[5]
end
function SendChatMessage(msg, ch, _, tgt)
    table.insert(_G.__FS_MOCK.sentChats, { msg = msg, channel = ch, target = tgt })
end
function DoEmote(tok, tgt)
    table.insert(_G.__FS_MOCK.sentEmotes, { token = tok, target = tgt })
end
C_ChatInfo = {
    InChatMessagingLockdown = function() return _G.__FS_MOCK.chatLockdown end,
    SendChatMessage = function(msg, ch, _, tgt)
        table.insert(_G.__FS_MOCK.sentChats, { msg = msg, channel = ch, target = tgt })
    end,
}
function UnitHealth() return _G.__FS_MOCK.hp end
function UnitHealthMax() return _G.__FS_MOCK.hpMax end
function UnitIsDeadOrGhost() return _G.__FS_MOCK.deadOrGhost end
function GetWeaponEnchantInfo() return _G.__FS_MOCK.mainHandEnchant == true end
function GetNumBuybackItems() return _G.__FS_MOCK.buybackCount end
function GetGuildBankWithdrawMoney() return _G.__FS_MOCK.guildWithdraw end
function GetGuildBankMoney() return _G.__FS_MOCK.guildMoney end
function GetInventoryItemDurability(slot)
    local d = (_G.__FS_MOCK.durability or {})[slot]
    if d then return d[1], d[2] end
    return nil, nil
end
function UnitFactionGroup() return _G.__FS_MOCK.playerFaction or "Alliance", _G.__FS_MOCK.playerFaction or "Alliance" end
function GetInventoryItemID(_, slot)
    if slot == 16 and _G.__FS_MOCK.mainHandItemID then return _G.__FS_MOCK.mainHandItemID end
    return (_G.__FS_MOCK.equippedItems or {})[slot]
end
function UnitGUID(unit)
    if unit == "target" then return _G.__FS_MOCK.targetGUID end
    return nil
end
function CanMerchantRepair() return _G.__FS_MOCK.canRepair == true end
function GetRepairAllCost()
    local c = _G.__FS_MOCK.repairCost
    if issecretvalue(c) then return c, true end
    local flag = _G.__FS_MOCK.repairAllCanFlag
    if flag == nil then flag = (c or 0) > 0 end
    return c or 0, flag
end
function CanGuildBankRepair() return _G.__FS_MOCK.canGuildRepair == true end
function RepairAllItems(useGuild)
    if useGuild then
        _G.__FS_MOCK.repairedGuild = true
        if not _G.__FS_MOCK.asyncGuildRepair and not _G.__FS_MOCK.guildRepairShouldFail then
            _G.__FS_MOCK.repairCost = 0
            __FS_FIRE_EVENT("UPDATE_INVENTORY_DURABILITY")
        end
    else
        _G.__FS_MOCK.repairedPersonal = true
        local c = _G.__FS_MOCK.repairCost or 0
        _G.__FS_MOCK.repairCost = 0
        _G.__FS_MOCK.money = (_G.__FS_MOCK.money or 0) - c
        if not _G.__FS_MOCK.deferMoneyEvents then
            __FS_FIRE_EVENT("PLAYER_MONEY")
        end
    end
end
function QuestFlagsPVP() return _G.__FS_MOCK.questPvp end
function GetQuestMoneyToGet() return _G.__FS_MOCK.questReqMoney or 0 end
function GetNumQuestItems() return _G.__FS_MOCK.questReqItems or 0 end
function AcceptQuest() _G.__FS_MOCK.acceptedQuests = _G.__FS_MOCK.acceptedQuests + 1 end
function IsQuestCompletable() return true end
function CompleteQuest() _G.__FS_MOCK.completedQuests = (_G.__FS_MOCK.completedQuests or 0) + 1 end
function GetNumQuestChoices() return _G.__FS_MOCK.questChoices end
function GetQuestReward() _G.__FS_MOCK.turnedInQuests = _G.__FS_MOCK.turnedInQuests + 1 end

C_Timer = {
    After = function(delay, fn)
        local t = { _delay = delay, _fn = fn, _fired = false }
        table.insert(_G.__FS_MOCK.afterTimers, t)
        return t
    end,
    NewTicker = function(interval, fn)
        local t = { _interval = interval, _fn = fn, _cancelled = false }
        function t:Cancel() self._cancelled = true end
        function t:Tick() if not self._cancelled then self._fn() end end
        table.insert(_G.__FS_MOCK.tickers, t)
        return t
    end,
}

function __FS_FLUSH_AFTER_TIMERS()
    local list = _G.__FS_MOCK.afterTimers
    _G.__FS_MOCK.afterTimers = {}
    for _, t in ipairs(list) do
        if not t._fired then
            t._fired = true
            t._fn()
        end
    end
end

function geterrorhandler()
    return function(err)
        table.insert(_G.__FS_MOCK.errorsForwarded, tostring(err))
    end
end

function GetQuestLogSpecialItemInfo(idx)
    local item = (_G.__FS_MOCK.questSpecialItems or {})[idx]
    if item then return item[1], item[2] end
    return nil, nil
end

function GetMoney()
    return _G.__FS_MOCK.money
end

function InCombatLockdown()
    return _G.__FS_MOCK.inCombat
end

function GetNormalizedRealmName()
    return _G.__FS_MOCK.realm
end

function GetRealmName()
    return _G.__FS_MOCK.realmFallback
end

function GetTime()
    return _G.__FS_MOCK.now
end

function time()
    return _G.__FS_MOCK.now
end

function GetBuildInfo()
    return "1.60.1", "71037", "Nov 2026", 16001
end

DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg)
        table.insert(_G.__FS_MOCK.printed, tostring(msg))
    end,
}

SlashCmdList = {}

local function MakeMockRegion(kind, parent)
    local r = {
        _kind = kind,
        _parent = parent,
        _shown = true,
        _alpha = 1.0,
        _text = "",
        _points = {},
        _color = nil,
        _width = 0,
        _height = 0,
    }
    function r:SetParent(p) self._parent = p end
    function r:GetParent() return self._parent end
    function r:SetAllPoints(target) self._allPoints = target or self._parent end
    function r:ClearAllPoints() self._points = {} end
    function r:SetPoint(...) table.insert(self._points, { ... }) end
    function r:GetPoint(idx)
        local p = self._points[idx or 1]
        if p then return p[1], p[2], p[3], p[4], p[5] end
        return "CENTER", UIParent, "CENTER", 0, 0
    end
    function r:SetSize(w, h) self._width = w; self._height = h end
    function r:SetWidth(w) self._width = w end
    function r:SetHeight(h) self._height = h end
    function r:GetWidth() return self._width end
    function r:GetHeight() return self._height end
    function r:SetColorTexture(r1, g1, b1, a1) self._color = { r1, g1, b1, a1 } end
    function r:SetTexture(path) self._texture = path end
    function r:SetTexCoord(...) self._texCoord = { ... } end
    function r:SetVertexColor(r1, g1, b1, a1) self._vertexColor = { r1, g1, b1, a1 } end
    function r:SetText(t) self._text = tostring(t or "") end
    function r:GetText() return self._text end
    function r:SetTextColor(r1, g1, b1, a1) self._textColor = { r1, g1, b1, a1 } end
    function r:SetJustifyH(j) self._justifyH = j end
    function r:SetJustifyV(j) self._justifyV = j end
    function r:SetWordWrap(w) self._wordWrap = w end
    function r:SetNonSpaceWrap(w) self._nonSpaceWrap = w end
    function r:SetShadowColor(r1, g1, b1, a1) self._shadowColor = { r1, g1, b1, a1 } end
    function r:SetShadowOffset(x, y) self._shadowOffset = { x, y } end
    function r:SetFontObject(f) self._fontObject = f end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    function r:SetAlpha(a) self._alpha = a end
    function r:GetAlpha() return self._alpha end
    function r:GetLeft() return self._rect and self._rect.left or nil end
    function r:GetRight() return self._rect and (self._rect.left + self._rect.width) or nil end
    function r:GetBottom() return self._rect and self._rect.bottom or nil end
    function r:GetTop() return self._rect and (self._rect.bottom + self._rect.height) or nil end
    return r
end

local function MakeMockFrame(frameType, name, parent, template)
    local f = MakeMockRegion(frameType or "Frame", parent)
    f._name = name
    f._template = template
    f._scripts = {}
    f._hooks = {}
    f._events = {}
    f._attrs = {}
    f._clicks = {}
    f._strata = "MEDIUM"
    f._level = 1
    f._scale = 1.0
    f._movable = false
    f._mouse = true
    function f:GetObjectType() return self._kind end
    function f:GetName() return self._name end
    function f:GetParent() return self._parent end
    function f:SetFrameStrata(s) self._strata = s end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetEffectiveScale() return self._scale end
    function f:SetClampedToScreen(v) self._clamped = v end
    function f:SetMovable(v) self._movable = v end
    function f:EnableMouse(v) self._mouse = v end
    function f:EnableMouseWheel(v) self._mouseWheel = v end
    function f:RegisterForDrag(...) self._dragButtons = { ... } end
    function f:StartMoving() self._moving = true end
    function f:StopMovingOrSizing() self._moving = false end
    function f:RegisterForClicks(...) self._clicks = { ... } end
    function f:SetAttribute(k, v)
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: SetAttribute in combat")
        end
        self._attrs[k] = v
    end
    function f:GetAttribute(k) return self._attrs[k] end
    function f:RegisterEvent(ev)
        self._events[ev] = true
        _G.__FS_MOCK.events[ev] = _G.__FS_MOCK.events[ev] or {}
        table.insert(_G.__FS_MOCK.events[ev], self)
    end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:SetScript(ev, fn) self._scripts[ev] = fn end
    function f:HookScript(ev, fn)
        self._hooks[ev] = self._hooks[ev] or {}
        table.insert(self._hooks[ev], fn)
    end
    function f:FireScript(ev, ...)
        if self._scripts[ev] then self._scripts[ev](self, ...) end
        if self._hooks[ev] then
            for _, h in ipairs(self._hooks[ev]) do h(self, ...) end
        end
    end
    function f:CreateTexture(_, layer)
        local t = MakeMockRegion("Texture", self)
        t._layer = layer
        return t
    end
    function f:CreateFontString(_, layer, fontObj)
        local fs = MakeMockRegion("FontString", self)
        fs._layer = layer
        fs._fontObject = fontObj
        return fs
    end
    function f:SetAutoFocus(v) self._autoFocus = v end
    function f:SetTextInsets(...) self._insets = { ... } end
    function f:SetFocus() self._focused = true end
    function f:ClearFocus() self._focused = false end
    function f:HighlightText() self._highlighted = true end
    function f:SetMultiLine(v) self._multiLine = v end
    function f:SetMaxLetters(n) self._maxLetters = n end
    function f:IsVisible() return self._shown == true end
    function f:SetMinMaxValues(a, b) self._min, self._max = a, b end
    function f:SetValueStep(s) self._step = s end
    function f:SetObeyStepOnDrag(v) self._obeyStep = v end
    function f:SetValue(v) self._value = v end
    function f:GetValue() return self._value or 0 end
    function f:SetOrientation(o) self._orientation = o end
    function f:Show()
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: Show secure frame in combat")
        end
        self._shown = true
        self:FireScript("OnShow")
    end
    function f:Hide()
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: Hide secure frame in combat")
        end
        self._shown = false
        self:FireScript("OnHide")
    end
    if name then _G[name] = f end
    table.insert(_G.__FS_MOCK.frames, f)
    return f
end

function CreateFrame(frameType, name, parent, template)
    return MakeMockFrame(frameType, name, parent, template)
end

UIParent = MakeMockFrame("Frame", "UIParent", nil, nil)
UIParent:SetSize(1920, 1080)
UISpecialFrames = {}

ObjectiveTrackerFrame = MakeMockFrame("Frame", "ObjectiveTrackerFrame", UIParent, nil)
local _origObjShow = ObjectiveTrackerFrame.Show
local _origObjAlpha = ObjectiveTrackerFrame.SetAlpha
ObjectiveTrackerFrame.Show = function(self)
    _G.__FS_MOCK.objTrackerTouches = _G.__FS_MOCK.objTrackerTouches + 1
    return _origObjShow(self)
end
ObjectiveTrackerFrame.SetAlpha = function(self, a)
    _G.__FS_MOCK.objTrackerTouches = _G.__FS_MOCK.objTrackerTouches + 1
    return _origObjAlpha(self, a)
end

WorldMapFrame = MakeMockFrame("Frame", "WorldMapFrame", UIParent, nil)
WorldMapFrame:Hide()
WorldMapFrame.IsShown = function() return _G.__FS_MOCK.worldMapShown end
WorldMapFrame.GetMapID = function() return _G.__FS_MOCK.worldMapID end
WorldMapFrame.ScrollContainer = MakeMockFrame("Frame", nil, WorldMapFrame, nil)
WorldMapFrame.ScrollContainer._rect = { left = 100, bottom = 100, width = 800, height = 600 }
WorldMapFrame.ScrollContainer:SetSize(800, 600)
WorldMapFrame._rect = { left = 100, bottom = 100, width = 800, height = 600 }
WorldMapFrame:SetSize(800, 600)

Minimap = MakeMockFrame("Frame", "Minimap", UIParent, nil)
Minimap:SetSize(140, 140)
function Minimap:GetCenter() return 1820, 980 end

GameTooltip = MakeMockFrame("GameTooltip", "GameTooltip", UIParent, nil)
GameTooltip._lines = {}
GameTooltip._forbidden = false
function GameTooltip:IsForbidden() return self._forbidden == true end
function GameTooltip:SetOwner(owner, anchor)
    self._owner = owner
    self._anchor = anchor
    self._lines = {}
end
function GameTooltip:AddLine(text, r, g, b)
    table.insert(self._lines, { left = text, right = nil, r = r, g = g, b = b })
end
function GameTooltip:AddDoubleLine(left, right, r, g, b)
    table.insert(self._lines, { left = left, right = right, r = r, g = g, b = b })
end
function GameTooltip:ClearLines() self._lines = {} end
function GameTooltip:SetHyperlink(link) self._hyperlink = link end

Enum = {
    TooltipDataType = { Item = 0, Spell = 1 },
}

TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
        _G.__FS_MOCK.tooltipPostCalls[dataType] = _G.__FS_MOCK.tooltipPostCalls[dataType] or {}
        table.insert(_G.__FS_MOCK.tooltipPostCalls[dataType], fn)
    end,
}

function __FS_FIRE_TOOLTIP(dataType, tt, data)
    local list = _G.__FS_MOCK.tooltipPostCalls[dataType] or {}
    for _, fn in ipairs(list) do
        fn(tt, data)
    end
end

function CreateFont(name)
    local f = { _name = name }
    function f:SetFont(path, size, flags)
        if _G.__FS_MOCK.fontSetShouldFail and _G.__FS_MOCK.fontSetShouldFail[path] then
            return false
        end
        self._path, self._size, self._flags = path, size, flags
        return true
    end
    function f:GetFont() return self._path, self._size, self._flags end
    _G[name] = f
    return f
end

C_AddOns = {
    GetAddOnMetadata = function(_, field)
        if field == "Version" then return "3.0.1" end
        if field == "Interface" then return "16001, 120105" end
        return nil
    end,
    DoesAddOnExist = function(name)
        local ex = _G.__FS_MOCK.addonExists
        if ex and ex[name] ~= nil then return ex[name] end
        return true
    end,
    IsAddOnLoaded = function(name) return _G.__FS_MOCK.loadedAddOns[name] == true end,
    LoadAddOn = function(name)
        _G.__FS_MOCK.loadedAddOns[name] = true
        return true, nil
    end,
}

C_SuperTrack = {
    GetSuperTrackedQuestID = function() return _G.__FS_MOCK.superTrackedQuestID end,
    SetSuperTrackedQuestID = function(qid)
        if _G.__FS_MOCK.inCombat then error("ADDON_ACTION_BLOCKED: SetSuperTrackedQuestID in combat") end
        _G.__FS_MOCK.superTrackedQuestID = qid
    end,
    SetSuperTrackedUserWaypoint = function(flag)
        _G.__FS_MOCK.superTrackedWaypoint = flag
    end,
}

C_Map = {
    GetBestMapForUnit = function()
        return (_G.__FS_MOCK.playerPos and _G.__FS_MOCK.playerPos.mapID) or 1411
    end,
    GetMapInfo = function(mapID)
        local n = (_G.__FS_MOCK.mapNames or {})[mapID]
        return n and { mapID = mapID, name = n } or nil
    end,
    GetPlayerMapPosition = function()
        local p = _G.__FS_MOCK.playerPos
        if p then return { x = p.x, y = p.y } end
        return nil
    end,
    CanSetUserWaypointOnMap = function() return true end,
    GetUserWaypoint = function() return _G.__FS_MOCK.userWaypoint end,
    SetUserWaypoint = function(wp)
        if _G.__FS_MOCK.inCombat then error("ADDON_ACTION_BLOCKED: SetUserWaypoint in combat") end
        _G.__FS_MOCK.userWaypoint = wp
    end,
    ClearUserWaypoint = function()
        _G.__FS_MOCK.clearWaypointCalls = (_G.__FS_MOCK.clearWaypointCalls or 0) + 1
        _G.__FS_MOCK.userWaypoint = nil
    end,
}

C_CVar = {
    GetCVar = function(name) return (_G.__FS_MOCK.cvars or {})[name] end,
    SetCVar = function(name, val)
        _G.__FS_MOCK.cvars = _G.__FS_MOCK.cvars or {}
        _G.__FS_MOCK.cvars[name] = tostring(val)
        return true
    end,
}

C_FriendList = {
    GetNumFriends = function() return #(_G.__FS_MOCK.friends or {}) end,
    GetFriendInfoByIndex = function(i)
        local n = (_G.__FS_MOCK.friends or {})[i]
        return n and { name = n } or nil
    end,
}

C_Spell = {
    IsSpellKnown = function(sid) return (_G.__FS_MOCK.knownSpells or {})[sid] == true end,
    GetSpellInfo = function(sid)
        local n = (_G.__FS_MOCK.spellNames or {})[sid]
        return n and { name = n, spellID = sid } or nil
    end,
}

C_UnitAuras = {
    GetPlayerAuraBySpellID = function(sid)
        if _G.__FS_MOCK.auraSecret then
            return FS_MakeSecret("aura", "table")
        end
        return (_G.__FS_MOCK.activeAuras or {})[sid] and { spellId = sid } or nil
    end,
    GetAuraDataByIndex = function(unit, idx)
        if _G.__FS_MOCK.auraListSecret then
            return FS_MakeSecret("aura_row", "table")
        end
        local list = _G.__FS_MOCK.auraList or {}
        return list[idx]
    end,
}

C_Item = {
    GetDetailedItemLevelInfo = function(itemID)
        return (_G.__FS_MOCK.itemLevels or {})[itemID]
    end,
    GetItemInfoInstant = function(itemID)
        local icons = _G.__FS_MOCK.itemIcons or {}
        if icons[itemID] then
            return itemID, "Armor", "Cloth", "INVTYPE_HEAD", icons[itemID], 4, 1
        end
        if type(itemID) == "number" and itemID > 0 then
            return itemID, "Item", "Item", "", 134400 + (itemID % 50), 0, 0
        end
        return nil
    end,
    GetItemInfo = function(itemID)
        if itemID == 6256 then
            return "낚싯대", "|Hitem:6256|h[낚싯대]|h", 1, 5, 1, "무기", "낚싯대", 1, "", 132932, 20, 2, 20
        end
        for _, it in ipairs(_G.__FS_MOCK.bagItems or {}) do
            if it.itemID == itemID then
                return it.name, nil, it.quality, 1, 1, "기타", "잡템", 20, "", 134400, it.unitPrice, 15, 0
            end
        end
        return nil
    end,
}

C_QuestLog = {
    GetLogIndexForQuestID = function(qid)
        return (_G.__FS_MOCK.questLogSet and _G.__FS_MOCK.questLogSet[qid]) or nil
    end,
    GetNumQuestLogEntries = function()
        return #(_G.__FS_MOCK.questEntries or {})
    end,
    GetInfo = function(idx)
        return (_G.__FS_MOCK.questEntries or {})[idx]
    end,
    GetQuestObjectives = function(qid)
        return (_G.__FS_MOCK.questObjectives and _G.__FS_MOCK.questObjectives[qid]) or {}
    end,
    GetQuestExpansion = function() return 0 end,
    IsComplete = function(qid) return (_G.__FS_MOCK.questComplete or {})[qid] == true end,
    ReadyForTurnIn = function(qid) return (_G.__FS_MOCK.questReadyForTurnIn or {})[qid] == true end,
    GetTitleForQuestID = function(qid)
        if _G.__FS_MOCK.questTitles and _G.__FS_MOCK.questTitles[qid] then
            return _G.__FS_MOCK.questTitles[qid]
        end
        for _, e in ipairs(_G.__FS_MOCK.questEntries or {}) do
            if e.questID == qid and e.title then return e.title end
        end
        return nil
    end,
    GetNextWaypoint = function(qid)
        local wp = _G.__FS_MOCK.questWaypoints and _G.__FS_MOCK.questWaypoints[qid]
        if wp then return wp.mapID, wp.x, wp.y end
        return nil
    end,
    GetNextWaypointText = function(qid)
        local wp = _G.__FS_MOCK.questWaypoints and _G.__FS_MOCK.questWaypoints[qid]
        return wp and wp.text or ""
    end,
    GetNextWaypointForMap = function(qid, mapID)
        local m = _G.__FS_MOCK.questMapWaypoints and _G.__FS_MOCK.questMapWaypoints[qid]
        if m and m[mapID] then return m[mapID].x, m[mapID].y end
        return nil
    end,
    GetQuestsOnMap = function(mapID)
        return (_G.__FS_MOCK.questsOnMap and _G.__FS_MOCK.questsOnMap[mapID]) or {}
    end,
    IsQuestFlaggedCompleted = function(qid)
        return (_G.__FS_MOCK.questFlaggedCompleted or {})[qid] == true
    end,
    GetQuestWatchType = function(qid)
        return (_G.__FS_MOCK.questWatched and _G.__FS_MOCK.questWatched[qid]) and 0 or nil
    end,
    AddQuestWatch = function(qid)
        _G.__FS_MOCK.questWatched = _G.__FS_MOCK.questWatched or {}
        _G.__FS_MOCK.questWatched[qid] = true
    end,
    RemoveQuestWatch = function(qid)
        if _G.__FS_MOCK.questWatched then _G.__FS_MOCK.questWatched[qid] = nil end
    end,
}

function GetQuestUiMapID(qid)
    return _G.__FS_MOCK.questUiMapID and _G.__FS_MOCK.questUiMapID[qid] or nil
end
function QuestPOIGetIconInfo(qid)
    local p = _G.__FS_MOCK.questPoiIcons and _G.__FS_MOCK.questPoiIcons[qid]
    if p then return p.completed, p.x, p.y end
    return nil
end

C_Container = {
    GetContainerNumFreeSlots = function() return _G.__FS_MOCK.bagFreeSlots, 0 end,
    GetContainerNumSlots = function(bag)
        if bag == 0 then return math.max(20, #(_G.__FS_MOCK.bagItems or {})) end
        return 0
    end,
    GetContainerItemInfo = function(bag, slot)
        for _, it in ipairs(_G.__FS_MOCK.bagItems or {}) do
            if it.bag == bag and it.slot == slot then
                return { itemID = it.itemID, quality = it.quality, stackCount = it.stackCount, isLocked = it.isLocked, itemName = it.name }
            end
        end
        return nil
    end,
    UseContainerItem = function(bag, slot)
        table.insert(_G.__FS_MOCK.soldItems, { bag = bag, slot = slot })
        for _, it in ipairs(_G.__FS_MOCK.bagItems or {}) do
            if it.bag == bag and it.slot == slot then
                _G.__FS_MOCK.money = (_G.__FS_MOCK.money or 0) + (it.unitPrice * (it.stackCount or 1))
                if not _G.__FS_MOCK.deferMoneyEvents then
                    __FS_FIRE_EVENT("PLAYER_MONEY")
                end
                break
            end
        end
    end,
}

function __FS_FIRE_EVENT(ev, ...)
    local list = _G.__FS_MOCK.events[ev]
    if not list then return end
    for _, frame in ipairs(list) do
        if frame._events[ev] and frame._scripts["OnEvent"] then
            frame._scripts["OnEvent"](frame, ev, ...)
        end
    end
end
"#;

fn setup_vm(v2_root: &Path) -> Result<Lua> {
    let lua = Lua::new();
    let globals = lua.globals();

    let make_secret = lua_err(lua.create_function(
        |_, (tag, utype): (String, Option<String>)| {
            Ok(SecretProxy {
                tag,
                underlying_type: utype.unwrap_or_else(|| "number".to_string()),
            })
        },
    ))?;
    lua_err(globals.set("FS_MakeSecret", make_secret))?;

    let secret_type = lua_err(lua.create_function(|_, val: Value| match val {
        Value::UserData(ud) => {
            if let Ok(sp) = ud.borrow::<SecretProxy>() {
                Ok(Some(sp.underlying_type.clone()))
            } else {
                Ok(None)
            }
        }
        _ => Ok(None),
    }))?;
    lua_err(globals.set("__FS_SECRET_TYPE", secret_type))?;

    let is_secret = lua_err(lua.create_function(|_, val: Value| match val {
        Value::UserData(ud) => Ok(ud.is::<SecretProxy>()),
        _ => Ok(false),
    }))?;
    lua_err(globals.set("issecretvalue", is_secret))?;

    lua_err(lua.load(WOW_MOCK_PRELUDE).set_name("wow_mock_prelude").exec())?;

    let media_dir = v2_root.join("ForeverSuite_Media");
    if media_dir.is_dir() {
        load_addon_into_vm(&lua, &media_dir)?;
    }

    let addon_dir = v2_root.join("ForeverSuite");
    if addon_dir.is_dir() {
        load_addon_into_vm(&lua, &addon_dir)?;
    }

    let v2_root_str = v2_root.to_string_lossy().to_string();
    let loader_fn = lua_err(lua.create_function(move |lua_ctx, addon_name: Option<String>| {
        let folder = addon_name.unwrap_or_else(|| "ForeverSuite_Data".to_string());
        if folder.contains("..") || folder.contains('/') || folder.contains('\\') {
            return Ok(false);
        }
        let p = PathBuf::from(&v2_root_str).join(&folder);
        if p.is_dir() {
            load_addon_into_vm(lua_ctx, &p)
                .map_err(|e| mlua::Error::RuntimeError(e.to_string()))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }))?;
    lua_err(globals.set("__FS_LOAD_DATA_ADDON", loader_fn))?;

    Ok(lua)
}

fn load_addon_into_vm(lua: &Lua, addon_dir: &Path) -> Result<()> {
    let toc = parse_toc(addon_dir)?;
    let ns = lua_err(lua.create_table())?;
    for rel in &toc.files {
        if rel.extension().and_then(|s| s.to_str()) != Some("lua") {
            continue;
        }
        let full = addon_dir.join(rel);
        let src = fs::read_to_string(&full)
            .with_context(|| format!("Failed to read {}", full.display()))?;
        let chunk = lua.load(&src).set_name(full.to_string_lossy().as_ref());
        let func = lua_err(chunk.into_function())?;
        lua_err(func.call::<()>((toc.addon_name.as_str(), ns.clone())))
            .with_context(|| format!("Error executing {}", full.display()))?;
    }
    Ok(())
}

pub fn run_tests(v2_root: &Path) -> Result<TestSummary> {
    let tests_dir = v2_root.join("tests");
    if !tests_dir.is_dir() {
        bail!("Tests directory not found: {}", tests_dir.display());
    }

    let mut test_files: Vec<PathBuf> = fs::read_dir(&tests_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
        .collect();
    test_files.sort();

    if test_files.is_empty() {
        bail!("No .lua test files found in {}", tests_dir.display());
    }

    let mut total = 0usize;
    let mut passed = 0usize;
    let mut failures = Vec::new();

    for tf in &test_files {
        total += 1;
        let label = tf
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown.lua");
        let lua = setup_vm(v2_root)?;
        let src = fs::read_to_string(tf)?;
        match lua.load(&src).set_name(label).exec() {
            Ok(()) => {
                let asserts: usize = lua_err(lua.globals().get("__FS_ASSERT_COUNT"))?;
                if asserts == 0 {
                    let msg = format!("{label}: test file executed 0 assertions (fail-closed)");
                    println!("  [FAIL] {msg}");
                    failures.push(msg);
                } else {
                    passed += 1;
                    println!("  [PASS] {label} ({asserts} assertions)");
                }
            }
            Err(err) => {
                println!("  [FAIL] {label}: {err}");
                failures.push(format!("{label}: {err}"));
            }
        }
    }

    if !failures.is_empty() {
        bail!(
            "fsx test FAILED ({}/{} passed):\n{}",
            passed,
            total,
            failures.join("\n")
        );
    }

    Ok(TestSummary { total, passed })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_proxy_preserves_underlying_type_and_panics_on_ops() -> Result<()> {
        let lua = Lua::new();
        let make_secret = lua_err(lua.create_function(
            |_, (tag, utype): (String, Option<String>)| {
                Ok(SecretProxy {
                    tag,
                    underlying_type: utype.unwrap_or_else(|| "number".to_string()),
                })
            },
        ))?;
        lua_err(lua.globals().set("FS_MakeSecret", make_secret))?;
        let secret_type = lua_err(lua.create_function(|_, val: Value| match val {
            Value::UserData(ud) => Ok(ud.borrow::<SecretProxy>().ok().map(|s| s.underlying_type.clone())),
            _ => Ok(None),
        }))?;
        lua_err(lua.globals().set("__FS_SECRET_TYPE", secret_type))?;
        let is_secret = lua_err(lua.create_function(|_, val: Value| match val {
            Value::UserData(ud) => Ok(ud.is::<SecretProxy>()),
            _ => Ok(false),
        }))?;
        lua_err(lua.globals().set("issecretvalue", is_secret))?;
        lua_err(lua.load(WOW_MOCK_PRELUDE).exec())?;

        let ok: bool = lua_err(
            lua.load(
                r#"
                local s = FS_MakeSecret("hp", "number")
                local s2 = FS_MakeSecret("hp2", "number")
                assert(issecretvalue(s) == true)
                assert(type(s) == "number")
                local okTypeGuard = pcall(function() return type(s) == "number" and s > 0 end)
                local okMod = pcall(function() return s % 2 end)
                local okUnm = pcall(function() return -s end)
                local okEq = pcall(function() return s == s2 end)
                local okCat = pcall(function() return "x" .. s end)
                return (not okTypeGuard) and (not okMod) and (not okUnm) and (not okEq) and (not okCat)
                "#,
            )
            .eval(),
        )?;
        assert!(ok);
        Ok(())
    }
}

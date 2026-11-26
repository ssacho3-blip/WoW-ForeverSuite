-- Module: Features/ProcCooldownHud.lua
-- Responsibility: I6/I7 Full Parity — Event-driven Combat Proc Alerts HUD (Nightfall, Missile Barrage, Clearcasting, etc.)
--                 & Major Skill Cooldown Tracker HUD (0% idle CPU when inactive, C_Secrets safe, /fs move movable).
-- Layer: Features (uses UI/Widgets + Api/SafeAPI/GameAdapters).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local string_format = string.format

-- Forever 1.60.1 signature combat procs (aura spellID -> banner)
local WATCHED_PROCS = {
    [17941]   = { name = "일몰 발동!", desc = "어둠의 화살 즉시 시전", icon = "Interface\\Icons\\Spell_Shadow_Twilight" },
    [400589]  = { name = "화살 탄막 발동!", desc = "신비한 화살 강화", icon = "Interface\\Icons\\Spell_Arcane_StarFire" },
    [1326083] = { name = "화살 탄막 발동!", desc = "신비한 화살 강화", icon = "Interface\\Icons\\Spell_Arcane_StarFire" },
    [12536]   = { name = "정신 집중 발동!", desc = "다음 주문 마나 소모 0", icon = "Interface\\Icons\\Spell_Shadow_ManaBurn" },
    [16870]   = { name = "청명의 전조 발동!", desc = "다음 기술 자원 소모 0", icon = "Interface\\Icons\\Spell_Crystal" },
    [14201]   = { name = "격노 발동!", desc = "공격력 증가", icon = "Interface\\Icons\\Spell_Shadow_UnholyFrenzy" },
    [20216]   = { name = "신의 은총 발동!", desc = "다음 치유 극대화", icon = "Interface\\Icons\\Spell_Holy_Heal" },
}

-- Key major cooldown spell IDs per class (only shown when known & currently on cooldown > 2s)
local CLASS_COOLDOWNS = {
    WARRIOR = { { id = 871, name = "방패의 벽" }, { id = 1719, name = "무모한 희생" }, { id = 12292, name = "죽음의 소원" }, { id = 12975, name = "최후의 저항" } },
    MAGE    = { { id = 12042, name = "신비의 마법 강화" }, { id = 12043, name = "냉정" }, { id = 11958, name = "매서운 한파" }, { id = 12051, name = "환기" } },
    ROGUE   = { { id = 13750, name = "아드레날린 촉진" }, { id = 13877, name = "폭풍의 칼날" }, { id = 1856, name = "소멸" }, { id = 5277, name = "회피" } },
    HUNTER  = { { id = 3045, name = "속사" }, { id = 19574, name = "야수의 격노" }, { id = 23989, name = "만반의 준비" }, { id = 5384, name = "죽은척하기" } },
    PRIEST  = { { id = 10060, name = "마력 주입" }, { id = 14751, name = "내면의 집중력" }, { id = 8122, name = "영혼의 절규" } },
    WARLOCK = { { id = 18288, name = "저주 증폭" }, { id = 18708, name = "지옥의 지배" }, { id = 5484, name = "공포의 울부짖음" } },
    PALADIN = { { id = 642, name = "천상의 보호막" }, { id = 633, name = "신의 축복" }, { id = 1022, name = "보호의 축복" } },
    SHAMAN  = { { id = 16166, name = "정기의 깨달음" }, { id = 16188, name = "자연의 신속함" }, { id = 20608, name = "윤회" } },
    DRUID   = { { id = 29166, name = "정신 자극" }, { id = 17116, name = "자연의 신속함" }, { id = 22812, name = "나무 껍질" } },
}

local ProcCooldownHud = {
    WATCHED_PROCS = WATCHED_PROCS,
    CLASS_COOLDOWNS = CLASS_COOLDOWNS,
    procCard = nil,
    procIcon = nil,
    procTitle = nil,
    procSub = nil,
    activeProcId = nil,
    cdCard = nil,
    cdRows = {},
    cdTicker = nil,
    initialized = false,
}
ns.Features.ProcCooldownHud = ProcCooldownHud

function ProcCooldownHud:Init()
    if self.initialized then return true end
    self.initialized = true

    -- 1. Proc Alert Banner
    local pc = W.Card(_G.UIParent, 244, 44, "ForeverSuiteProcAlertHud", T.ELEVATION.L1_CARD)
    pc:EnableMouse(false)
    W.SetBorderColor(pc, T.BORDER.GOLD)
    local ico = W.IconFrame(pc, 28)
    ico:SetPoint("LEFT", pc, "LEFT", 8, 0)
    local pt = W.Label(pc, "", "heading", T.TEXT.GOLD, { justifyH = "LEFT", wordWrap = false })
    pt:SetPoint("TOPLEFT", pc, "TOPLEFT", 44, -6)
    pt:SetPoint("TOPRIGHT", pc, "TOPRIGHT", -8, -6)
    local ps = W.Label(pc, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
    ps:SetPoint("BOTTOMLEFT", pc, "BOTTOMLEFT", 44, 6)
    ps:SetPoint("BOTTOMRIGHT", pc, "BOTTOMRIGHT", -8, 6)
    pc:Hide()
    self.procCard = pc
    self.procIcon = ico
    self.procTitle = pt
    self.procSub = ps
    ns.UI.HudLayout:Register("procAlertHud", pc, {
        point = "CENTER",
        relPoint = "CENTER",
        x = 0,
        y = 112,
    }, "전투 발동(Proc) 경보 HUD")

    -- 2. Skill Cooldown Tracker HUD
    local cc = W.Card(_G.UIParent, 212, 92, "ForeverSuiteCooldownHud", T.ELEVATION.L1_CARD)
    cc:EnableMouse(false)
    W.SetBorderColor(cc, T.BORDER.GOLD_SOFT)
    for i = 1, 4 do
        local lbl = W.Label(cc, "", "small", T.TEXT.PRIMARY, { justifyH = "LEFT", wordWrap = false })
        lbl:SetPoint("TOPLEFT", cc, "TOPLEFT", 8, -(8 + (i - 1) * 20))
        lbl:SetPoint("TOPRIGHT", cc, "TOPRIGHT", -8, -(8 + (i - 1) * 20))
        self.cdRows[i] = lbl
    end
    cc:Hide()
    self.cdCard = cc
    ns.UI.HudLayout:Register("skillCooldownHud", cc, {
        point = "CENTER",
        relPoint = "CENTER",
        x = -184,
        y = -84,
    }, "주요 쿨다운 추적 HUD")

    return true
end

function ProcCooldownHud:RefreshProcs()
    if not self.procCard then return false end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return false end
    if ns.Api.ProfileStore:Get("combat", "showProcAlerts") == false then
        self.activeProcId = nil
        self.procCard:Hide()
        return false
    end
    local auras = ns.Api.GameAdapters.GetPlayerHelpfulAuras()
    local foundId, foundSpec = nil, nil
    for _, a in ipairs(auras) do
        local spec = a.spellId and WATCHED_PROCS[a.spellId] or nil
        if spec then
            foundId, foundSpec = a.spellId, spec
            break
        end
    end
    if foundSpec then
        local newlyTriggered = (self.activeProcId ~= foundId)
        self.activeProcId = foundId
        self.procIcon:SetIcon(foundSpec.icon, T.BORDER.GOLD, "✦")
        self.procTitle:SetText(foundSpec.name)
        self.procSub:SetText(foundSpec.desc)
        self.procCard:Show()
        if newlyTriggered then
            local snd = ns.Api.ProfileStore:Get("ui", "alertSoundKey") or "dingdong"
            if snd ~= "none" then
                ns.Api.GameAdapters.PlayNotificationSound(snd, 75, "SFX")
            end
        end
        return true, foundId
    end
    self.activeProcId = nil
    self.procCard:Hide()
    return false
end

function ProcCooldownHud:StopCdTicker()
    if self.cdTicker then
        ns.Api.GameAdapters.CancelTicker(self.cdTicker)
        self.cdTicker = nil
    end
end

function ProcCooldownHud:AddCustomCooldown(spellID)
    local id = tonumber(spellID)
    if not (id and id > 0) then return false end
    local custom = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("customCooldownSpells")
    if type(custom) ~= "table" then custom = {} end
    local name = ns.Api.GameAdapters.GetSpellName(id) or ("주문 #" .. tostring(id))
    for _, c in ipairs(custom) do
        if c.id == id then return true end
    end
    custom[#custom + 1] = { id = id, name = name }
    if ns.Api.ProfileStore then ns.Api.ProfileStore:SetState("customCooldownSpells", custom) end
    ns.Api.SafeAPI.Print("사용자 지정 쿨다운 추적 추가: " .. name .. " (#" .. tostring(id) .. ")")
    self:RefreshCooldowns()
    return true
end

function ProcCooldownHud:ClearCustomCooldowns()
    if ns.Api.ProfileStore then ns.Api.ProfileStore:SetState("customCooldownSpells", {}) end
    ns.Api.SafeAPI.Print("사용자 지정 쿨다운 추적 목록을 초기화했습니다.")
    self:RefreshCooldowns()
    return true
end

function ProcCooldownHud:RefreshCooldowns()
    if not self.cdCard then return 0 end
    if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then return 0 end
    if ns.Api.ProfileStore:Get("combat", "showSkillCooldowns") == false then
        self:StopCdTicker()
        self.cdCard:Hide()
        return 0
    end
    local cls = ns.Api.GameAdapters.GetPlayerClass()
    local baseList = (cls and CLASS_COOLDOWNS[cls]) or {}
    local list = {}
    local seen = {}
    for _, sp in ipairs(baseList) do
        list[#list + 1] = sp
        seen[sp.id] = true
    end
    local custom = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("customCooldownSpells")
    if type(custom) == "table" then
        for _, sp in ipairs(custom) do
            if type(sp) == "table" and type(sp.id) == "number" and not seen[sp.id] then
                list[#list + 1] = { id = sp.id, name = tostring(sp.name or ("#" .. tostring(sp.id))) }
                seen[sp.id] = true
            end
        end
    end
    local now = ns.Api.GameAdapters.GetMonotonicTime()
    if type(now) ~= "number" then
        self:StopCdTicker()
        self.cdCard:Hide()
        return 0
    end
    local active = {}
    for _, sp in ipairs(list) do
        local st, dur = ns.Api.GameAdapters.GetSpellCooldownSafe(sp.id)
        if type(st) == "number" and type(dur) == "number" and dur > 2.0 and st > 0 then
            local rem = (st + dur) - now
            if rem > 0.2 then
                active[#active + 1] = { name = sp.name, remaining = rem }
            end
        end
    end
    if #active == 0 then
        self:StopCdTicker()
        self.cdCard:Hide()
        return 0
    end
    table.sort(active, function(a, b) return a.remaining < b.remaining end)
    local shown = (#active > 4) and 4 or #active
    for i = 1, 4 do
        local r = active[i]
        local lbl = self.cdRows[i]
        if r and i <= shown then
            lbl:SetText(string_format("%s  %.1fs", r.name, r.remaining))
            local col = (r.remaining <= 5.0) and T.SEMANTIC.SUCCESS or T.TEXT.GOLD
            lbl:SetTextColor(col[1], col[2], col[3], 1)
            lbl:Show()
        else
            lbl:SetText("")
            lbl:Hide()
        end
    end
    self.cdCard:SetHeight(16 + shown * 20)
    self.cdCard:Show()
    if not self.cdTicker then
        self.cdTicker = ns.Api.GameAdapters.StartTicker(0.25, function()
            ProcCooldownHud:RefreshCooldowns()
        end)
    end
    return shown
end

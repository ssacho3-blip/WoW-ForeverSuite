-- Test 18: ForeverSuite v4.0 Forensic Anti-Fake Real-Wiring Regression Suite (Wave A + Wave B)
-- Verifies every single P0 & P1 gap caught in the independent Claude Opus 5.5 forensic audit is genuinely wired end-to-end.
local ns = _G.ForeverSuite
assert(type(ns) == "table", "ForeverSuite namespace must exist")

__FS_FIRE_EVENT("PLAYER_LOGIN")
local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") or name == "ForeverSuite_Media_Assets" then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

local fsx_assert = assert
local passed = 0
local function check(cond, msg)
    fsx_assert(cond, msg)
    passed = passed + 1
end

-- 1. A1: Fresh-login Tooltip lazy-loads REAL LoD packs OOC + translates clauses + shows quest starter hint + CursorTooltip has no scoping crash
do
    local addedLines = {}
    local mockTooltip = {
        IsForbidden = function() return false end,
        GetName = function() return "MockForensicTT" end,
        NumLines = function() return 3 end,
        AddLine = function(_, left, r, g, b) addedLines[#addedLines + 1] = { left = left } end,
        AddDoubleLine = function(_, left, right) addedLines[#addedLines + 1] = { left = left, right = right } end,
        SetOwner = function(self, parent, anchor) self._lastAnchor = anchor end,
    }
    _G.MockForensicTTTextLeft2 = { GetText = function() return "Binds when equipped" end }
    _G.MockForensicTTTextLeft3 = { GetText = function() return "Soulbound" end }

    -- Simulate fresh login before any Hub tab was opened (REAL packs loaded lazily on hover!)
    ns.Features.TooltipEnhanceModule.triedPacksLoad = false
    ns.Features.TooltipEnhanceModule.sourceIndex = nil
    ns.Features.TooltipEnhanceModule.bisIndex = nil
    ns.Features.TooltipEnhanceModule.profMatIndex = nil
    ns.Features.TooltipEnhanceModule.itemTransMap = nil
    ns.Features.TooltipEnhanceModule.clauseTransMap = nil

    local n = ns.Features.TooltipEnhanceModule:OnItemTooltip(mockTooltip, 1307)
    check(ns.Features.TooltipEnhanceModule.triedPacksLoad == true, "A1: Tooltip EnsureIndexes must trigger OOC lazy pack load")
    local sawClause, sawStarter = false, false
    for _, ln in ipairs(addedLines) do
        if ln.left == "한글 설명" and ln.right == "착용 시 귀속" then sawClause = true end
        if ln.left == "! 퀘스트 시작 아이템" then sawStarter = true end
    end
    check(n >= 3 and sawClause, "A1: OnItemTooltip must translate visible English clauses via TranslateVisibleLines")
    check(sawStarter, "A1: OnItemTooltip must display quest_starters hint")

    -- Verify CursorTooltip hook works without local IsTooltipForbidden nil crash
    local hookFn = nil
    local prevHook = _G.hooksecurefunc
    local prevSetDef = _G.GameTooltip_SetDefaultAnchor
    _G.GameTooltip_SetDefaultAnchor = function() end
    _G.hooksecurefunc = function(name, fn) if name == "GameTooltip_SetDefaultAnchor" then hookFn = fn end end
    ns.Blizzard.TooltipAdapter.cursorHooked = false
    ns.Blizzard.TooltipAdapter:InitCursorAnchor(function() return true end)
    check(type(hookFn) == "function", "A1: InitCursorAnchor must register hooksecurefunc")
    hookFn(mockTooltip, _G.UIParent)
    check(mockTooltip._lastAnchor == "ANCHOR_CURSOR", "A1: CursorTooltip must anchor to ANCHOR_CURSOR without scoping crash")
    _G.hooksecurefunc = prevHook
    _G.GameTooltip_SetDefaultAnchor = prevSetDef
    _G.MockForensicTTTextLeft2 = nil
    _G.MockForensicTTTextLeft3 = nil
end

-- 2. A3 + Wave B: WorldMap multi-tile Fog-of-War + explored filter + canvas click /way + 240px collapse/expand + Pet Heatmap
do
    local multiTile = { mapID = 1411, x = 244, y = 0, w = 512, h = 256, filesCsv = "8074091,8074092" }
    local subs = ns.Domain.WorldMapModel.ExpandRevealSubTiles(multiTile, { [8074091] = true })
    check(#subs == 1 and subs[1].fileID == 8074092 and subs[1].x == 500 and subs[1].w == 256, "A3: ExpandRevealSubTiles must tile multi-file overlays and skip explored fileIDs")

    local allSubs = ns.Domain.WorldMapModel.ExpandRevealSubTiles(multiTile, {})
    check(#allSubs == 2 and allSubs[1].x == 244 and allSubs[2].x == 500, "A3: ExpandRevealSubTiles must emit both 256x256 columns for 512x256 tile")

    -- Verify REAL compiled Pet Heatmap pack renders sprites on Elwynn Forest (mapID = 1429)
    ns.Features.WorldMapOverlay.showPetHeatmap = true
    local _, _, pCnt = ns.Features.WorldMapOverlay:RenderMapExtras(1429, { left = 100, bottom = 100, width = 800, height = 533, scale = 1 })
    check(pCnt >= 1, "Wave B: WorldMapOverlay must render real pet_heatmap sprites on Elwynn Forest (1429), got " .. tostring(pCnt))
    ns.Features.WorldMapOverlay.showPetHeatmap = false

    -- Verify canvas-click /way works with explicit normalized coords (never requires mouse on card button)
    local okPin = ns.Features.WorldMapOverlay:PinCurrentCursorLocation(1429, 0.42, 0.65)
    check(okPin == true, "A3: PinCurrentCursorLocation must accept canvas-click normalized coordinates directly")

    -- Verify collapse/expand restores full 240px height
    ns.Features.WorldMapOverlay:EnsureCard()
    ns.Features.WorldMapOverlay:SetCollapsed(true)
    ns.Features.WorldMapOverlay:SetCollapsed(false)
    check(ns.Features.WorldMapOverlay.card:GetHeight() == 240, "A3: WorldMapOverlay expand must restore full 240px height")
end

-- 3. A2: QuestExtra collection bag scan + proximity ticker + QuestTracker party/route rendering
do
    _G.ForeverSuiteData.packs.quest_collection = {
        entries = { { itemID = 915, title = "붉은 비단 복면", questsCsv = "214" } },
    }
    local prevScan = ns.Api.GameAdapters.ScanBagsAndBankCounts
    ns.Api.GameAdapters.ScanBagsAndBankCounts = function() return { [915] = 3 } end
    ns.Features.QuestExtraModule.notifiedCollectionItems = { [915] = 1 }
    local trig = ns.Features.QuestExtraModule:CheckCollectionAlerts()
    check(trig >= 1 and ns.Features.QuestExtraModule.notifiedCollectionItems[915] == 3, "A2: CheckCollectionAlerts must cross-check quest_collection pack against bags")
    ns.Api.GameAdapters.ScanBagsAndBankCounts = prevScan

    -- Party progress & dialogue route visible in QuestTrackerView detail card
    ns.Features.QuestExtraModule.partyProgress["아라곤"] = { [857] = "1/1" }
    _G.ForeverSuiteData.packs.quest_routes = {
        entries = { { kind = "dialogue", questID = 857, mapID = 1413, x = 0.49, y = 0.86, title = "추방된 피글리 보고" } },
    }
    ns.Features.QuestTrackerView:ShowDetailCard({ questID = 857, title = "달의 눈물", objectives = {} })
    local bodyTxt = ns.Features.QuestTrackerView.detailCard._body:GetText() or ""
    check(string.find(bodyTxt, "아라곤", 1, true) ~= nil, "A2: QuestTrackerView detail card must display party sync summary")
    check(string.find(bodyTxt, "추방된 피글리", 1, true) ~= nil, "A2: QuestTrackerView detail card must display dialogue turn-in route")
end

-- 4. A4 & A5: Real Escort names (no fake '호위 퀘스트 #155') + 35 restored dungeons (including SFK, Stockades, Uldaman)
do
    ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Dungeon")
    local dList = _G.ForeverSuiteData.packs.dungeons.entries
    check(#dList >= 35, "A5: Restored dungeon catalog must contain >= 35 dungeons (got " .. tostring(#dList) .. ")")
    local byName = {}
    for _, d in ipairs(dList) do byName[d.title] = true end
    check(byName["그림자송곳니 성채"] and byName["스톰윈드 지하감옥"] and byName["울다만"] and byName["가시덩굴 우리"], "A5: Classic dungeons (SFK, Stockades, Uldaman, RFK) must be present")

    ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_QuestExtra")
    local tips = _G.ForeverSuiteData.packs.quest_tips.entries
    check(#tips >= 70, "A4: quest_tips must load all real escort + quicktip + growth entries")
    local sawRealEscort = false
    for _, t in ipairs(tips) do
        check(not string.find(tostring(t.title or ""), "호위 퀘스트 #", 1, true), "A4: Zero synthetic '호위 퀘스트 #...' titles allowed")
        if t.kind == "escort" and string.find(tostring(t.title or ""), "Defias Traitor", 1, true) then
            sawRealEscort = true
        end
    end
    check(sawRealEscort, "A4: Escort quests must preserve real EscortQuests249 target names")
end

-- 5. Wave B: A7 GJ 189-CVar preset + C_Spell.PickupSpell 1.60.1 fallback + SharedSettings restore + G4 dynamic channel + H2 GDKP archive + I7 custom cooldown + K2 independent World/Damage fonts
do
    ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    local gp = _G.ForeverSuiteData.packs.game_presets
    check(type(gp) == "table" and #gp.entries >= 150, "Wave B A7: game_presets pack must contain real GJ CVars (>=150)")

    -- Verify C_Spell.PickupSpell 1.60.1 fallback
    local pickedSpell = nil
    local prevCSpell = _G.C_Spell
    local prevPlace = _G.PlaceAction
    _G.C_Spell = { PickupSpell = function(id) pickedSpell = id end }
    _G.PlaceAction = function() end
    local okBar, cntBar = ns.Api.GameAdapters.RestoreActionBarSafe({ [1] = { kind = "spell", id = 133 } })
    check(okBar and cntBar == 1 and pickedSpell == 133, "Wave B A7: RestoreActionBarSafe must support 1.60.1 C_Spell.PickupSpell")
    _G.C_Spell = prevCSpell
    _G.PlaceAction = prevPlace

    -- Shared settings sync + restore round-trip
    ns.Api.ProfileStore:Set("ui", "cursorSize", "large")
    local okSync = ns.Features.PresetManagerModule:SyncSharedSettingsToChar()
    ns.Api.ProfileStore:Set("ui", "cursorSize", "small")
    local okRest = ns.Features.PresetManagerModule:RestoreSharedSettingsFromChar()
    check(okSync and okRest and ns.Api.ProfileStore:Get("ui", "cursorSize") == "large", "Wave B A7: SyncSharedSettingsToChar + RestoreSharedSettingsFromChar must round-trip settings")

    -- Dynamic channel number lookup
    local prevGetCh = _G.GetChannelName
    _G.GetChannelName = function(n) if n == "파티찾기" then return 6, "파티찾기" end end
    check(ns.Api.GameAdapters.GetChannelIndexByNameSafe("파티찾기") == 6, "Wave B G4: GetChannelIndexByNameSafe must resolve dynamic channel index")
    _G.GetChannelName = prevGetCh

    -- GDKP archive via slash command
    ns.Features.UtilitiesPage:AddGdkpSaleDirect("혈문검", "아서스", 500)
    local okArch = ns.Features.UtilitiesPage:HandleGdkpCommand("archive 화산 심장부")
    check(okArch == true and #ns.Features.UtilitiesPage.lootArchive >= 1, "Wave B H2: /fs gdkp archive must persist GDKP run to lootArchive")

    -- Custom cooldown tracker
    local okCd = ns.Features.ProcCooldownHud:AddCustomCooldown(11426)
    local savedCds = ns.Api.ProfileStore:GetState("customCooldownSpells")
    check(okCd and type(savedCds) == "table" and #savedCds >= 1, "Wave B I7: AddCustomCooldown must persist custom cooldown spell ID")
    ns.Features.ProcCooldownHud:ClearCustomCooldowns()

    -- Cursor ring circular texture + size/alpha
    ns.Api.ProfileStore:Set("ui", "showCursorRing", true)
    ns.Api.ProfileStore:Set("ui", "cursorSize", "large")
    ns.Api.ProfileStore:Set("ui", "cursorAlpha", "75")
    ns.Features.CursorTrailHud:ApplyVisibility(false)
    check(ns.Features.CursorTrailHud.ringTex ~= nil, "Wave B I5: CursorTrailHud must use circular ring texture instead of square box")
    check(ns.Features.CursorTrailHud.ring:GetWidth() == 46, "Wave B I5: cursorSize='large' must resize ring to 46px")
    ns.Api.ProfileStore:Set("ui", "showCursorRing", false)
end

print(string.format("[PASS] 18_v41_forensic_wiring_and_anti_fake: all %d forensic anti-fake assertions verified!", passed))

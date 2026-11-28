-- Module: Features/Bootstrap.lua
-- Responsibility: Wires v2 declarative schemas, L2 Command Hub (4 pages), Phase 2A modules, lifecycle events, and /fs2 + /way2 commands.
-- Layer: Features
local _, ns = ...
ns.Features = ns.Features or {}

local pairs = pairs
local string_match = string.match
local string_lower = string.lower

local MAX_TAINT_KEYS = 200

-- Strangler Fig: declarative schemas extracted to Features/Boot/Schemas.lua
local DEFAULT_SCHEMAS = (ns.Features.Boot and ns.Features.Boot.DEFAULT_SCHEMAS) or {}

local Bootstrap = {
    initialized = false,
}
ns.Features.Bootstrap = Bootstrap

local function ApplyTrackerModeSafely(requestedMode)
    ns.Blizzard.ObjectiveTrackerAdapter:ApplyMode(requestedMode or "hide")
end

local function RecordTaintEvent(kind, addonName, funcName)
    if not ns.Api.ProfileStore:CanWrite() then
        return
    end
    local diag = ns.Api.ProfileStore.db.v2.diagnostics
    local a = ns.Api.SafeAPI.IsSecret(addonName) and "SECRET" or tostring(addonName or "UNKNOWN")
    local f = ns.Api.SafeAPI.IsSecret(funcName) and "SECRET" or tostring(funcName or "UNKNOWN")
    local k = kind .. ":" .. a .. ":" .. f
    diag.taintTotal = (diag.taintTotal or 0) + 1
    if diag.taintCounts[k] ~= nil then
        diag.taintCounts[k] = diag.taintCounts[k] + 1
    else
        local keyCount = 0
        for _ in pairs(diag.taintCounts) do
            keyCount = keyCount + 1
        end
        if keyCount < MAX_TAINT_KEYS then
            diag.taintCounts[k] = 1
        end
    end
end

function Bootstrap:Init()
    if self.initialized then
        return
    end

    ns.Api.ProfileStore:RegisterSchema(DEFAULT_SCHEMAS)
    ns.Api.ProfileStore:Init()
    -- Phase 1 (C7): Recover any crash-interrupted CVar mutations before mounting features
    ns.Api.ProfileStore:RestoreCvarJournal(function(k, fn)
        return ns.Secure.CombatQueue:RunOrDefer(k, fn)
    end)

    -- Phase 4 (Coexistence Resolve - must precede Secure/UI/Feature mount)
    if ns.Bridges and ns.Bridges.BridgeHost then
        if ns.Bridges.Baganator then
            ns.Bridges.Baganator:SetProviders({
                badge = function(itemID)
                    if ns.Features.TooltipEnhanceModule then
                        if ns.Features.TooltipEnhanceModule.bisIndex and ns.Features.TooltipEnhanceModule.bisIndex[itemID] then
                            return { text = "BiS", r = 0.33, g = 0.83, b = 0.42 }
                        end
                        if ns.Features.TooltipEnhanceModule.profMatIndex and ns.Features.TooltipEnhanceModule.profMatIndex[itemID] then
                            return { text = "재료", r = 0.90, g = 0.76, b = 0.36 }
                        end
                    end
                    return nil
                end,
                cheapAction = function()
                    if ns.Features.MerchantModule then
                        ns.Features.MerchantModule:PrintCheapestItems()
                    end
                end,
            })
        end
        if ns.Bridges.DialogueUI then
            ns.Bridges.DialogueUI:SetProviders({
                evaluator = function(itemLink)
                    local itemID = tonumber(string_match(itemLink or "", "item:(%d+)"))
                    if itemID and ns.Features.TooltipEnhanceModule and ns.Features.TooltipEnhanceModule.bisIndex then
                        local bis = ns.Features.TooltipEnhanceModule.bisIndex[itemID]
                        if bis then
                            return true, "ForeverSuite BiS: " .. tostring(bis)
                        end
                    end
                    return false, nil
                end,
                translator = function(questID)
                    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs
                    local qt = packs and packs.quest_tips and packs.quest_tips.entries
                    if type(qt) == "table" then
                        for i = 1, #qt do
                            local rec = qt[i]
                            if rec and rec.questID == questID and type(rec.title) == "string" and rec.title ~= "" then
                                return { title = rec.title, description = rec.note }
                            end
                        end
                    end
                    return nil
                end,
            })
        end
        if ns.Bridges.Spoken and ns.Api.GameAdapters and type(ns.Api.GameAdapters.SetAudioDuckPredicate) == "function" then
            ns.Api.GameAdapters.SetAudioDuckPredicate(function(isSurvivalAlert)
                return ns.Bridges.Spoken:ShouldDuckAudio(isSurvivalAlert)
            end)
        end
        local bridgeOverrides = ns.Api.ProfileStore:GetState("bridgeOverrides")
        ns.Bridges.BridgeHost:SetScheduler(ns.Api.GameAdapters.RunAfter)
        ns.Bridges.BridgeHost:ResolveAll(bridgeOverrides, {
            playerClass = ns.Api.GameAdapters.GetPlayerClass(),
        })
    end

    if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetTheme) == "function" then
        ns.UI.Tokens.SetTheme(ns.Api.ProfileStore:Get("ui", "uiTheme") or "gold")
        if type(ns.UI.Tokens.SetBrightness) == "function" then
            ns.UI.Tokens.SetBrightness(
                ns.Api.ProfileStore:Get("ui", "textureBrightness"),
                ns.Api.ProfileStore:Get("ui", "goldBrightness")
            )
        end
    end
    if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SetReducedMotion) == "function" then
        ns.UI.Motion.SetReducedMotion(ns.Api.ProfileStore:Get("ui", "reducedMotion") == true)
    end

    -- Register L2 Command Hub workspace pages (v3.0 4-Group Unified Hub; Home is default landing)
    ns.UI.CommandHub:RegisterPage(ns.Features.HomePage)
    ns.UI.CommandHub:RegisterPage(ns.Features.PartyFinderPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.QuestGuidePage)
    ns.UI.CommandHub:RegisterPage(ns.Features.DungeonBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.BiSBrowserPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.CodexPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.ProfessionPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.UtilitiesPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.LedgerPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.SettingsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.FontsPage)
    ns.UI.CommandHub:RegisterPage(ns.Features.DiagnosticsPage)

    ns.Blizzard.WorldMapAdapter:Init()

    local mode = ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide"
    ApplyTrackerModeSafely(mode)

    ns.Api.EventBus:Subscribe("hud:layout_locked", function()
        ns.Features.CombatHudPack:RefreshAll()
        ns.Features.ThreatMeterHud:Refresh()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.CombatAssistHud:Refresh()
        ns.Features.EncounterTimerHud:Refresh()
        ns.Features.StatusPillHud:ApplyVisibility()
    end)

    ns.Api.EventBus:Subscribe("hud:layout_unlocked", function()
        if ns.Secure and ns.Secure.FishingCastButton and type(ns.Secure.FishingCastButton.SyncDock) == "function" then
            ns.Secure.FishingCastButton:SyncDock(ns.Features.FishingCardHud and ns.Features.FishingCardHud.card, false, nil)
        end
    end)
    ns.Api.EventBus:Subscribe("hud:layout_locked", function()
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
    end)
    ns.Api.EventBus:Subscribe("setting:changed", function(sec, key, val)
        if sec == "quest" and key == "defaultTrackerMode" then
            ns.Api.ProfileStore:SetState("userExplicitTrackerMode", true)
            ApplyTrackerModeSafely(val)
        elseif sec == "quest" and (key == "groupMode" or key == "currentZoneOnly" or key == "trackerMinimized" or key == "trackerLocked" or key == "compactMode") then
            ns.Features.QuestTrackerView:RefreshLive()
        elseif sec == "quest" and key == "combatFade" then
            ns.Features.QuestTrackerView:UpdateCombatVisuals()
        elseif sec == "quest" and key == "proximityAlerts" then
            ns.Features.QuestExtraModule:SyncProximityTicker()
        elseif sec == "ui" and key == "uiTheme" then
            if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetTheme) == "function" then
                ns.UI.Tokens.SetTheme(val)
            end
        elseif sec == "ui" and (key == "textureBrightness" or key == "goldBrightness") then
            if ns.UI and ns.UI.Tokens and type(ns.UI.Tokens.SetBrightness) == "function" then
                ns.UI.Tokens.SetBrightness(
                    ns.Api.ProfileStore:Get("ui", "textureBrightness"),
                    ns.Api.ProfileStore:Get("ui", "goldBrightness")
                )
            end
        elseif sec == "ui" and key == "reducedMotion" then
            if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SetReducedMotion) == "function" then
                ns.UI.Motion.SetReducedMotion(val == true)
            end
        elseif sec == "ui" and key == "showStatusPill" then
            ns.Features.StatusPillHud:ApplyVisibility()
        elseif sec == "ui" and key == "showQuickDock" then
            ns.Features.QuickDockHud:ApplyVisibility()
        elseif sec == "ui" and (key == "showWorldMapOverlay" or key == "showWorldMapPins" or key == "worldMapReveal" or key == "worldMapHeatmap" or key == "worldMapPetHeatmap") then
            ns.Features.WorldMapOverlay:ApplyVisibility()
        elseif sec == "ui" and key == "showMinimapButton" then
            ns.Features.MinimapButton:ApplyVisibility()
        elseif sec == "ui" and (key == "showCursorRing" or key == "cursorStyle" or key == "cursorCombatOnly" or key == "cursorColor" or key == "cursorSize" or key == "cursorAlpha") then
            ns.Features.CursorTrailHud:ApplyVisibility()
        elseif sec == "ui" and key == "navArrowStyle" then
            ns.Features.NavigationHud:Refresh()
        elseif sec == "ui" and key == "showScreenClock" then
            ns.Features.CombatHudPack:RefreshClock()
        elseif sec == "ui" and (key == "fontPreset" or key == "fontOutline") then
            ns.Features.FontsPage:ApplySavedFonts()
        elseif sec == "social" and key == "showChatButtons" then
            ns.Features.ChatToolsModule:RefreshChannelBar()
        elseif sec == "combat" and key == "showThreatMeter" then
            ns.Features.ThreatMeterHud:Refresh()
        elseif sec == "combat" and key == "showEncounterTimer" then
            ns.Features.EncounterTimerHud:Refresh()
        elseif sec == "combat" and (key == "showProcAlerts" or key == "showSkillCooldowns") then
            ns.Features.ProcCooldownHud:RefreshProcs()
            ns.Features.ProcCooldownHud:RefreshCooldowns()
        elseif sec == "combat" and (key == "showComboHud" or key == "showRangeHud" or key == "showShortBuffHud") then
            ns.Features.CombatHudPack:RefreshAll()
        elseif sec == "combat" then
            ns.Features.CombatAssistHud:Refresh()
        elseif sec == "profession" and (key == "showFishingCard" or key == "fishingDoubleClick") then
            ns.Features.FishingCardHud:Refresh()
        elseif sec == "profession" and key == "gatheringTrackAlert" then
            ns.Features.TrackingSwitcher:CheckMissingTrackingAlert(false)
        elseif sec == "profession" and key == "autoCycleTracking" then
            ns.Features.TrackingSwitcher:SyncAutoCycle()
        elseif sec == "qol" and key == "captureLuaErrors" then
            ns.Features.DiagnosticsPage:InstallErrorCaptureIfEnabled()
        elseif sec == "qol" and key == "corpseGuide" then
            ns.Features.CorpseGuideModule:Refresh()
        elseif sec == "qol" and key == "maxCameraZoom" then
            ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
        elseif sec == "qol" and key == "mailboxSafeOpen" then
            if ns.Features.MailboxModule then ns.Features.MailboxModule:Refresh() end
        end
    end)

    -- Initialize L0/L1 HUDs & Zero-Taint adapters
    ns.Features.QuestTrackerView:Init()
    ns.Features.QuestTrackerView:RefreshLive()
    ns.Features.WorldMapOverlay:Init()
    ns.Features.StatusPillHud:Init()
    ns.Features.NavigationHud:Init()
    ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
    ns.Features.CombatAssistHud:Init()
    ns.Features.CombatAssistHud:Refresh()
    ns.Features.ThreatMeterHud:Init()
    ns.Features.CursorTrailHud:Init()
    ns.Features.CombatHudPack:Init()
    ns.Features.ProcCooldownHud:Init()
    ns.Features.EncounterTimerHud:Init()
    ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
    ns.Features.FishingCardHud:Init()
    ns.Features.FishingCardHud:Refresh()
    if ns.Bridges and ns.Bridges.Spoken and type(ns.Bridges.Spoken.OnPlaybackChange) == "function" then
        ns.Bridges.Spoken:OnPlaybackChange(function(isPlaying)
            if ns.Features.FishingCardHud and type(ns.Features.FishingCardHud.OnSpokenPlaybackChanged) == "function" then
                ns.Features.FishingCardHud:OnSpokenPlaybackChanged(isPlaying)
            end
        end)
    end
    ns.Features.QuickDockHud:Init()
    ns.Features.MinimapButton:Init()
    ns.Features.TooltipEnhanceModule:Init()
    ns.Features.ChatToolsModule:Init()
    ns.Features.QuestExtraModule:Init()
    ns.Features.DiagnosticsPage:InstallErrorCaptureIfEnabled()
    ns.Features.AutoGreetingModule:SyncInitialRoster()
    ns.Features.FontsPage:ApplySavedFonts()
    ns.Features.LedgerPage:SyncFromPlayerMoney()
    ns.Features.UtilitiesPage:LoadSavedGdkp()
    ns.Features.UtilitiesPage:LoadSavedBookmarks()
    ns.Features.UtilitiesPage:RecordCurrentCharacter()
    ns.Features.TradeLogModule:LoadSaved()
    ns.Features.TradeLogModule:ResetFarm()
    ns.Features.QuestAnnounceModule:OnQuestLogUpdate()
    ns.Features.DungeonBrowserPage:OnInstanceChanged()
    ns.Features.QoLModule:ResetSessionXP()
    ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
    ns.Features.CharacterDockPanel:Init()

    -- Phase 3: Wire Director 5-State Morphing non-secure HUD channels, scheduler & live signal sync
    local directorInDialogue = false
    local function CollectDirectorSignals(combatOverride)
        local inCombat
        if combatOverride == nil then
            inCombat = ns.Api.SafeAPI.InCombat() and true or false
        else
            inCombat = combatOverride == true
        end
        return {
            isEditOverride  = (ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked()) and true or false,
            inCombat        = inCombat,
            isDeadOrGhost   = ns.Api.GameAdapters.IsPlayerDeadOrGhost() == true,
            isFeignDeath    = (ns.Api.GameAdapters.IsPlayerFeignDeath and ns.Api.GameAdapters.IsPlayerFeignDeath()) and true or false,
            hasFishingPole  = (
                (ns.Api.GameAdapters.IsFishingPoleEquipped and ns.Api.GameAdapters.IsFishingPoleEquipped())
                or (ns.Features.FishingCardHud and ns.Features.FishingCardHud.pinned == true)
            ) and true or false,
            isMounted       = (ns.Api.GameAdapters.IsPlayerMounted and ns.Api.GameAdapters.IsPlayerMounted()) and true or false,
            isDialogueShown = directorInDialogue == true,
        }
    end
    local function SyncDirectorState(combatOverride, forceImmediate)
        if not (ns.UI and ns.UI.Director) then return end
        ns.UI.Director:ApplySignals(CollectDirectorSignals(combatOverride), forceImmediate)
    end
    if ns.UI and ns.UI.Director then
        ns.UI.Director:SetScheduler(ns.Api.GameAdapters.RunAfter)
        ns.UI.Director:SetSignalProvider(function() return CollectDirectorSignals(nil) end)
        if ns.Features.QuestTrackerView.container then ns.UI.Director:RegisterChannel("questTracker", ns.Features.QuestTrackerView.container) end
        if ns.Features.NavigationHud.card then ns.UI.Director:RegisterChannel("navArrow", ns.Features.NavigationHud.card) end
        if ns.Features.FishingCardHud.card then ns.UI.Director:RegisterChannel("fishingCard", ns.Features.FishingCardHud.card) end
        if ns.Features.StatusPillHud.card then ns.UI.Director:RegisterChannel("statusPill", ns.Features.StatusPillHud.card) end
        if ns.Features.CombatAssistHud.strip then ns.UI.Director:RegisterChannel("combatAssist", ns.Features.CombatAssistHud.strip) end
        SyncDirectorState(nil, true)
    end

    -- Lifecycle & Feature event wiring
    ns.Api.EventBus:OnEvent("v2:addonLoaded", "ADDON_LOADED", function(_, addonName)
        if ns.Bridges and ns.Bridges.BridgeHost and type(addonName) == "string" then
            ns.Bridges.BridgeHost:OnAddonLoaded(addonName)
        end
        ns.Blizzard.WorldMapAdapter:Init()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
    end)
    local function RefreshHomeIfVisible()
        if ns.UI and ns.UI.CommandHub and ns.UI.CommandHub.activePageId == "home"
            and ns.UI.CommandHub.window and type(ns.UI.CommandHub.window.IsShown) == "function"
            and ns.UI.CommandHub.window:IsShown()
            and ns.Features.HomePage and type(ns.Features.HomePage.OnShow) == "function"
        then
            ns.Features.HomePage:OnShow()
        end
    end

    ns.Api.EventBus:OnEvent("v2:enterWorld", "PLAYER_ENTERING_WORLD", function()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.DungeonBrowserPage:OnInstanceChanged()
        ns.Features.ThreatMeterHud:Refresh()
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.AutoGreetingModule:SyncInitialRoster()
        ns.Features.CharacterAssistModule:CheckTalents(false)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
        ns.Features.ProfessionPage:SyncAltCooldowns(true)
        ns.Features.TrackingSwitcher:CheckMissingTrackingAlert(false)
        ns.Features.TrackingSwitcher:SyncAutoCycle()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
        directorInDialogue = false
        SyncDirectorState(nil, true)
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:questWatchChanged", "QUEST_WATCH_LIST_CHANGED", function()
        ApplyTrackerModeSafely(ns.Api.ProfileStore:Get("quest", "defaultTrackerMode") or "hide")
    end)
    ns.Api.EventBus:OnEvent("v2:levelUpTracker", "PLAYER_LEVEL_UP", function()
        ns.Features.QuestTrackerView:RefreshLive()
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:groupRoster", "GROUP_ROSTER_UPDATE", function()
        ns.Features.AutoGreetingModule:OnGroupRosterUpdate()
    end)
    ns.Api.EventBus:OnEvent("v2:charPoints", "CHARACTER_POINTS_CHANGED", function()
        ns.Features.CharacterAssistModule:CheckTalents(false)
    end)
    ns.Api.EventBus:OnEvent("v2:questLog", "QUEST_LOG_UPDATE", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.QuestAnnounceModule:OnQuestLogUpdate()
        ns.Features.QuestExtraModule:CheckCollectionAlerts()
        ns.Features.QuestExtraModule:BroadcastPartyQuestSync(false)
        ns.Features.QuestExtraModule:SyncProximityTicker()
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        ns.Features.NavigationHud:OnQuestLogUpdate()
    end)
    ns.Api.EventBus:OnEvent("v2:superTrack", "SUPER_TRACKING_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
    end)
    ns.Api.EventBus:OnEvent("v2:bags", "BAG_UPDATE_DELAYED", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.ProfessionPage:RecordBagBankMaterials(false)
        ns.Features.QuestExtraModule:CheckCollectionAlerts()
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
    end)
    ns.Api.EventBus:OnEvent("v6:fishLoot", "CHAT_MSG_LOOT", function(_, msg)
        if ns.Api.SafeAPI.IsSecret(msg) then return end
        if ns.Features.TradeLogModule and type(ns.Features.TradeLogModule.OnLootMessage) == "function" then
            ns.Features.TradeLogModule:OnLootMessage(msg)
        end
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:OnLootMessage(msg)
        end
    end)
    ns.Api.EventBus:OnEvent("v6:logoutCleanup", "PLAYER_LOGOUT", function()
        if ns.Features.ProfessionPage and type(ns.Features.ProfessionPage.SyncAltCooldowns) == "function" then
            pcall(ns.Features.ProfessionPage.SyncAltCooldowns, ns.Features.ProfessionPage, false, true)
        end
        if ns.Features.FishingCardHud then
            if ns.Features.FishingCardHud.soundBoost then
                ns.Features.FishingCardHud:ToggleSoundBoost(false)
            end
            if ns.Features.FishingCardHud.oneKeyInteract then
                ns.Features.FishingCardHud:ToggleOneKeyInteract(false)
            end
        end
    end)
    ns.Api.EventBus:OnEvent("v4:bankOpen", "BANKFRAME_OPENED", function()
        ns.Features.ProfessionPage:RecordBagBankMaterials(true)
    end)
    ns.Api.EventBus:OnEvent("v4:lootRoll", "START_LOOT_ROLL", function(_, rollID)
        ns.Features.DungeonBrowserPage:OnStartLootRoll(rollID)
    end)
    ns.Api.EventBus:OnEvent("v4:spellCd", "SPELL_UPDATE_COOLDOWN", function()
        ns.Features.ProcCooldownHud:RefreshCooldowns()
        ns.Features.ProfessionPage:SyncAltCooldowns(false)
    end)
    ns.Api.EventBus:OnEvent("v6:bagCd", "BAG_UPDATE_COOLDOWN", function()
        ns.Features.ProfessionPage:SyncAltCooldowns(false)
    end)
    ns.Api.EventBus:OnEvent("v2:durability", "UPDATE_INVENTORY_DURABILITY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.MerchantModule:ResolvePendingGuildRepair("event")
    end)
    ns.Api.EventBus:OnEvent("v2:money", "PLAYER_MONEY", function()
        ns.Features.StatusPillHud:RefreshLive()
        ns.Features.LedgerPage:SyncFromPlayerMoney()
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantShow", "MERCHANT_SHOW", function()
        ns.Features.MerchantModule:OnMerchantShow()
    end)
    ns.Api.EventBus:OnEvent("v2:merchantClose", "MERCHANT_CLOSED", function()
        ns.Features.MerchantModule:OnMerchantClosed()
    end)
    ns.Api.EventBus:OnEvent("v6:mailShow", "MAIL_SHOW", function()
        if ns.Features.MailboxModule then ns.Features.MailboxModule:OnMailShow() end
    end)
    ns.Api.EventBus:OnEvent("v6:mailUpdate", "MAIL_INBOX_UPDATE", function()
        if ns.Features.MailboxModule then ns.Features.MailboxModule:OnMailInboxUpdate() end
    end)
    ns.Api.EventBus:OnEvent("v6:mailClosed", "MAIL_CLOSED", function()
        if ns.Features.MailboxModule then ns.Features.MailboxModule:OnMailClosed() end
    end)
    ns.Api.EventBus:OnEvent("v2:qDetail", "QUEST_DETAIL", function()
        ns.Features.QuestAutomation:OnQuestDetail()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:gossipShow", "GOSSIP_SHOW", function()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:gossipClosed", "GOSSIP_CLOSED", function()
        directorInDialogue = false
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:qFinished", "QUEST_FINISHED", function()
        directorInDialogue = false
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:mountChanged", "PLAYER_MOUNT_DISPLAY_CHANGED", function()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qProgress", "QUEST_PROGRESS", function()
        ns.Features.QuestAutomation:OnQuestProgress()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qComplete", "QUEST_COMPLETE", function()
        ns.Features.QuestAutomation:OnQuestComplete()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v6:qTurnedIn", "QUEST_TURNED_IN", function(_, questID)
        if ns.Api.SafeAPI.IsSecret(questID) then return end
        ns.Features.QuestExtraModule:OnQuestTurnedIn(questID)
    end)
    ns.Api.EventBus:OnEvent("v6:qGreeting", "QUEST_GREETING", function()
        directorInDialogue = true
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:qAccepted", "QUEST_ACCEPTED", function(_, a1, a2)
        if ns.Api.SafeAPI.IsSecret(a1) or ns.Api.SafeAPI.IsSecret(a2) then return end
        local qid = (type(a2) == "number") and a2 or a1
        if type(qid) == "number" and qid > 0 then
            ns.Features.QuestAutomation:OnQuestAccepted(qid)
        end
    end)
    ns.Api.EventBus:OnEvent("v2:lootReady", "LOOT_READY", function()
        ns.Features.QoLModule:OnLootReady()
    end)
    ns.Api.EventBus:OnEvent("v2:playerDead", "PLAYER_DEAD", function()
        ns.Features.EncounterTimerHud:OnPlayerDead()
        ns.Features.QoLModule:OnPlayerDead()
        ns.Features.CorpseGuideModule:OnPlayerDead()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:playerAlive", "PLAYER_ALIVE", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        -- PLAYER_ALIVE also fires when releasing spirit to ghost: Refresh() keeps guiding while ghost and clears when alive
        ns.Features.CorpseGuideModule:Refresh()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:playerUnghost", "PLAYER_UNGHOST", function()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.CorpseGuideModule:OnPlayerRevived()
        SyncDirectorState(nil, false)
    end)
    ns.Api.EventBus:OnEvent("v2:resRequest", "RESURRECT_REQUEST", function(_, casterName)
        ns.Features.QoLModule:OnResurrectRequest(casterName)
    end)
    ns.Api.EventBus:OnEvent("v2:partyInvite", "PARTY_INVITE_REQUEST", function(_, inviterName)
        ns.Features.QoLModule:OnPartyInviteRequest(inviterName)
    end)
    ns.Api.EventBus:OnEvent("v2:xpUpdate", "PLAYER_XP_UPDATE", function()
        ns.Features.QoLModule:SyncSessionXP()
    end)
    ns.Api.EventBus:OnEvent("v2:levelUp", "PLAYER_LEVEL_UP", function(_, newLevel)
        ns.Features.QoLModule:SyncSessionXP()
        ns.Features.CharacterAssistModule:CheckTalents(true)
        ns.Features.UtilitiesPage:RecordCurrentCharacter()
        ns.Features.QuestExtraModule:CheckGrowthMilestone(newLevel)
    end)
    ns.Api.EventBus:OnEvent("v2:encStart", "ENCOUNTER_START", function(_, _, encounterName)
        ns.Features.EncounterTimerHud:OnEncounterStart(encounterName)
    end)
    ns.Api.EventBus:OnEvent("v2:encEnd", "ENCOUNTER_END", function(_, _, encounterName, _, _, success)
        ns.Features.EncounterTimerHud:OnEncounterEnd(encounterName, success)
        ns.Features.DungeonBrowserPage:OnBossKilled(encounterName, success)
    end)
    ns.Api.EventBus:OnEvent("v2:aura", "UNIT_AURA", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then
            ns.Features.CombatAssistHud:Refresh()
            ns.Features.CombatHudPack:RefreshShortBuffs()
            ns.Features.ProcCooldownHud:RefreshProcs()
            ns.Features.AutoGreetingModule:OnPlayerAuraChanged()
            ns.Features.QuestExtraModule:CheckXpBuffExpiry()
        end
    end)
    ns.Api.EventBus:OnEvent("v2:power", "UNIT_POWER_UPDATE", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then ns.Features.CombatHudPack:RefreshCombo() end
    end)
    ns.Api.EventBus:OnEvent("v2:targetChanged", "PLAYER_TARGET_CHANGED", function()
        ns.Features.CombatHudPack:RefreshCombo()
        ns.Features.CombatHudPack:RefreshRange()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeShow", "TRADE_SHOW", function()
        ns.Features.TradeLogModule:OnTradeShow()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeMoney", "TRADE_MONEY_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradePItem", "TRADE_PLAYER_ITEM_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeTItem", "TRADE_TARGET_ITEM_CHANGED", function()
        ns.Features.TradeLogModule:OnTradeUpdated()
    end)
    ns.Api.EventBus:OnEvent("v2:tradeAccept", "TRADE_ACCEPT_UPDATE", function(_, pAcc, tAcc)
        ns.Features.TradeLogModule:OnTradeAcceptUpdate(pAcc, tAcc)
    end)
    ns.Api.EventBus:OnEvent("v2:tradeInfo", "UI_INFO_MESSAGE", function(_, _, msg)
        ns.Features.TradeLogModule:OnInfoMessage(msg)
    end)
    ns.Api.EventBus:OnEvent("v2:tradeClosed", "TRADE_CLOSED", function()
        ns.Features.TradeLogModule:OnTradeClosed()
    end)
    ns.Api.EventBus:OnEvent("v2:hp", "UNIT_HEALTH", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then ns.Features.CombatAssistHud:Refresh() end
    end)
    ns.Api.EventBus:OnEvent("v2:enchant", "WEAPON_ENCHANT_CHANGED", function()
        ns.Features.CombatAssistHud:Refresh()
    end)
    ns.Api.EventBus:OnEvent("v2:equip", "UNIT_INVENTORY_CHANGED", function(_, unit)
        if ns.Api.SafeAPI.IsSecret(unit) then return end
        if unit == "player" then
            ns.Features.FishingCardHud:Refresh()
            SyncDirectorState(nil, false)
            if ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
                and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
                and ns.Features.BiSBrowserPage.host:IsVisible()
            then
                ns.Features.BiSBrowserPage:Render(ns.Features.BiSBrowserPage.lastQuery)
            end
        end
    end)
    local itemInfoPending = false
    ns.Api.EventBus:OnEvent("v2:itemInfo", "GET_ITEM_INFO_RECEIVED", function(_, itemID, okFlag)
        if ns.Api.SafeAPI.IsSecret(itemID) or ns.Api.SafeAPI.IsSecret(okFlag) or okFlag == false then return end
        if itemInfoPending then return end
        local bisVis = ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
            and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
            and ns.Features.BiSBrowserPage.host:IsVisible()
        local dungVis = ns.Features.DungeonBrowserPage and ns.Features.DungeonBrowserPage.host
            and type(ns.Features.DungeonBrowserPage.host.IsVisible) == "function"
            and ns.Features.DungeonBrowserPage.host:IsVisible()
        if not (bisVis or dungVis) then return end
        itemInfoPending = true
        local function flush()
            itemInfoPending = false
            if ns.Features.BiSBrowserPage and ns.Features.BiSBrowserPage.host
                and type(ns.Features.BiSBrowserPage.host.IsVisible) == "function"
                and ns.Features.BiSBrowserPage.host:IsVisible()
            then
                ns.Features.BiSBrowserPage:Render(ns.Features.BiSBrowserPage.lastQuery)
            end
            if ns.Features.DungeonBrowserPage and ns.Features.DungeonBrowserPage.host
                and type(ns.Features.DungeonBrowserPage.host.IsVisible) == "function"
                and ns.Features.DungeonBrowserPage.host:IsVisible()
            then
                ns.Features.DungeonBrowserPage:RenderRight()
            end
        end
        if not ns.Api.GameAdapters.RunAfter(0.25, flush) then
            flush()
        end
    end)
    ns.Api.EventBus:OnEvent("v2:zone", "ZONE_CHANGED_NEW_AREA", function()
        ns.Features.QuestTrackerView:RefreshLive()
        ns.Features.FishingCardHud:Refresh()
        ns.Features.NavigationHud:Refresh()
        ns.Features.EncounterTimerHud:OnZoneOrInstanceChanged()
        ns.Features.QuestExtraModule:CheckProximityAlerts()
        ns.Features.QuestExtraModule:SyncProximityTicker()
        ns.Features.TrackingSwitcher:CheckMissingTrackingAlert(false)
        RefreshHomeIfVisible()
    end)
    ns.Api.EventBus:OnEvent("v2:zoneSub", "ZONE_CHANGED", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:zoneIndoors", "ZONE_CHANGED_INDOORS", function()
        ns.Features.QuestTrackerView:RefreshLive()
    end)
    ns.Api.EventBus:OnEvent("v2:combatStart", "PLAYER_REGEN_DISABLED", function()
        if ns.UI and ns.UI.Motion and type(ns.UI.Motion.SnapAllForCombat) == "function" then
            ns.UI.Motion.SnapAllForCombat()
        end
        if ns.UI.HudLayout and ns.UI.HudLayout:IsUnlocked() then
            ns.UI.HudLayout:SetUnlocked(false)
        end
        if ns.Secure and ns.Secure.FishingCastButton then
            ns.Secure.FishingCastButton:OnCombatEntered()
        end
        if ns.Features.FishingCardHud and type(ns.Features.FishingCardHud.OnCombatEntered) == "function" then
            ns.Features.FishingCardHud:OnCombatEntered()
        end
        ns.Features.QuestTrackerView:UpdateCombatVisuals(true)
        ns.Features.CombatAssistHud:Refresh(true)
        ns.Features.CombatHudPack:RefreshRange(true)
        ns.Features.ThreatMeterHud:OnCombatStart()
        ns.Features.CursorTrailHud:ApplyVisibility(true)
        ns.Features.EncounterTimerHud:OnCombatStart()
        ns.Features.QuestExtraModule:SyncProximityTicker(true)
        ns.Features.TrackingSwitcher:StopAutoCycle()
        SyncDirectorState(true, true)
    end)
    ns.Api.EventBus:OnEvent("v2:combatEnd", "PLAYER_REGEN_ENABLED", function()
        ns.Secure.CombatQueue:Flush()
        ns.Api.NavPort.FlushIfSafe()
        ns.Features.NavigationHud:SyncSuperTrackedQuest(false)
        if ns.Features.FishingCardHud and type(ns.Features.FishingCardHud.ReconcileSpokenAudio) == "function" then
            ns.Features.FishingCardHud:ReconcileSpokenAudio()
        end
        if ns.Features.WorldMapOverlay and type(ns.Features.WorldMapOverlay.InvalidatePinCache) == "function" then
            ns.Features.WorldMapOverlay:InvalidatePinCache()
        end
        if ns.Features.FontsPage and not ns.Features.FontsPage.lastAppliedPreset then
            ns.Features.FontsPage:ApplySavedFonts()
        end
        ns.Features.QuestTrackerView:UpdateCombatVisuals(false)
        ns.Features.QuestTrackerView:ReRenderLast()
        ns.Features.CombatAssistHud:Refresh(false)
        ns.Features.CombatHudPack:RefreshRange(false)
        ns.Features.ThreatMeterHud:OnCombatEnd()
        ns.Features.CursorTrailHud:ApplyVisibility(false)
        ns.Features.EncounterTimerHud:OnCombatEnd()
        ns.Features.QoLModule:ApplyCameraZoomIfEnabled()
        ns.Features.QuestExtraModule:SyncProximityTicker(false)
        ns.Features.TrackingSwitcher:SyncAutoCycle()
        if ns.Features.FishingCardHud and ns.Features.FishingCardHud.visible then
            ns.Features.FishingCardHud:Refresh()
        end
        SyncDirectorState(false, false)
    end)

    ns.Api.EventBus:OnEvent("v2:taintBlocked", "ADDON_ACTION_BLOCKED", function(_, addonName, funcName)
        RecordTaintEvent("BLOCKED", addonName, funcName)
    end)
    ns.Api.EventBus:OnEvent("v2:taintForbidden", "ADDON_ACTION_FORBIDDEN", function(_, addonName, funcName)
        RecordTaintEvent("FORBIDDEN", addonName, funcName)
    end)

    if type(_G.SlashCmdList) == "table" then
        local function HandleMainSlash(raw)
            local trimmed = string_match(tostring(raw or ""), "^%s*(.-)%s*$") or ""
            local cmd, rest = string_match(trimmed, "^(%S+)%s*(.*)$")
            cmd = cmd and string_lower(cmd) or ""
            if cmd == "move" then
                local unlocked, reason = ns.UI.HudLayout:ToggleUnlock()
                if reason == "IN_COMBAT" then
                    ns.Api.SafeAPI.Print("전투 중에는 HUD 이동 모드를 켤 수 없습니다.")
                else
                    SyncDirectorState(nil, true)
                    ns.Api.SafeAPI.Print(unlocked and "HUD 이동 모드 활성화 (/fs move)" or "HUD 위치 잠금")
                end
            elseif cmd == "home" or cmd == "codex" or cmd == "ledger" or cmd == "settings" or cmd == "utilities" or cmd == "fonts"
                or cmd == "dungeons" or cmd == "bis" or cmd == "professions" or cmd == "questguide" or cmd == "partyfinder"
                or cmd == "diagnostics"
            then
                local win = ns.UI.CommandHub:EnsureWindow()
                win:Show()
                ns.UI.CommandHub:SelectPage(cmd)
            elseif cmd == "train" then
                ns.Features.CharacterAssistModule:PrintTrainableSummary()
            elseif cmd == "gdkp" then
                ns.Features.UtilitiesPage:HandleGdkpCommand(rest)
            elseif cmd == "farm" then
                ns.Features.TradeLogModule:HandleFarmCommand(rest)
            elseif cmd == "fav" then
                ns.Features.UtilitiesPage:HandleFavCommand(rest)
            elseif cmd == "profile" then
                ns.Features.UtilitiesPage:HandleProfileCommand(rest)
            elseif cmd == "kw" then
                ns.Features.ChatToolsModule:SetKeywords(rest)
            elseif cmd == "watch" then
                ns.Features.PartyFinderPage:SetWatchKeywords(rest)
            elseif cmd == "quickloot" then
                ns.Features.DungeonBrowserPage:ToggleQuickLootPopup()
            elseif cmd == "channel" then
                ns.Features.ChatToolsModule:JoinChannel(rest ~= "" and rest or "파티찾기")
            elseif cmd == "greet" then
                local gKind, gText = string_match(rest or "", "^(%S+)%s+(.+)$")
                if gKind == "join" or gKind == "welcome" then
                    ns.Features.AutoGreetingModule:SetCustomMessage(gKind, gText)
                    ns.Api.SafeAPI.Print("자동 인사(" .. gKind .. ") 문구 저장됨: " .. gText)
                elseif gKind == "filter" then
                    ns.Features.AutoGreetingModule:SetExcludedBuffs(gText)
                    ns.Api.SafeAPI.Print("버프 감사 제외 목록 저장됨: " .. gText)
                else
                    ns.Api.SafeAPI.Print("사용법: /fs greet <join|welcome|filter> <문구>")
                end
            elseif cmd == "preset" then
                local pSub, pArg = string_match(rest or "", "^(%S+)%s*(.*)$")
                pSub = pSub and string_lower(pSub) or ""
                if pSub == "cvar" then
                    ns.Features.PresetManagerModule:ApplyRecommendedGameCVars()
                elseif pSub == "barsave" then
                    ns.Features.PresetManagerModule:SaveActionBarLoadout(pArg)
                elseif pSub == "barload" then
                    ns.Features.PresetManagerModule:RestoreActionBarLoadout(pArg)
                elseif pSub == "import" then
                    ns.Features.PresetManagerModule:ImportEditModeLayout(pArg, "ForeverSuite")
                elseif pSub == "sync" then
                    ns.Features.PresetManagerModule:SyncSharedSettingsToChar()
                    ns.Api.SafeAPI.Print("계정 설정을 캐릭터에 동기화했습니다.")
                elseif pSub == "load" then
                    ns.Features.PresetManagerModule:RestoreSharedSettingsFromChar()
                else
                    ns.Api.SafeAPI.Print("사용법: /fs preset <cvar|barsave|barload|import|sync|load>")
                end
            elseif cmd == "cd" then
                local cSub, cArg = string_match(rest or "", "^(%S+)%s*(.*)$")
                cSub = cSub and string_lower(cSub) or ""
                if cSub == "add" then
                    ns.Features.ProcCooldownHud:AddCustomCooldown(cArg)
                elseif cSub == "clear" then
                    ns.Features.ProcCooldownHud:ClearCustomCooldowns()
                else
                    ns.Api.SafeAPI.Print("사용법: /fs cd <add <spellID>|clear>")
                end
            elseif cmd == "party" then
                ns.Features.ChatToolsModule:PrintPartyClassRoster()
            elseif cmd == "protect" then
                ns.Features.MerchantModule:ToggleProtectItem(rest)
            elseif cmd == "cheap" then
                ns.Features.MerchantModule:PrintCheapestItems()
            elseif cmd == "layer" then
                local layer = ns.Api.GameAdapters.GetZoneLayerID("target")
                ns.Api.SafeAPI.Print(layer and ("현재 대상 위상(ZoneUID): #" .. tostring(layer)) or "대상을 선택하면 위상(ZoneUID)을 확인할 수 있습니다.")
            elseif cmd == "xp" then
                ns.Features.QoLModule:HandleXPCommand(rest)
            elseif cmd == "pull" then
                ns.Features.EncounterTimerHud:HandlePullCommand(rest)
            elseif cmd == "timer" then
                ns.Features.EncounterTimerHud:PrintStatus()
            elseif cmd == "clearway" then
                ns.Features.NavigationHud:Clear()
                ns.Api.SafeAPI.Print("웨이포인트를 해제했습니다.")
            elseif cmd == "bridges" then
                if ns.Bridges and ns.Bridges.BridgeHost then
                    local summary = ns.Bridges.BridgeHost:GetSummary()
                    local parts = {}
                    for i = 1, #summary do
                        local s = summary[i]
                        parts[#parts + 1] = s.target .. "=" .. s.state
                    end
                    ns.Api.SafeAPI.Print("외부 브리지 공존 상태: " .. table.concat(parts, " | "))
                end
            elseif cmd == "reset" then
                if ns.Bridges and ns.Bridges.BridgeHost then
                    ns.Bridges.BridgeHost:Reset(rest ~= "" and rest or nil)
                    ns.Api.SafeAPI.Print("Coexistence/Bridge 상태를 재초기화했습니다.")
                end
            elseif cmd == "setup" then
                ns.Features.SetupWizard:HandleCommand(string_lower(rest or ""))
            elseif cmd == "k" or cmd == "palette" or cmd == "search" then
                ns.Features.CommandPalette:Toggle(rest)
            elseif cmd == "mail" then
                ns.Features.MailboxModule:CollectAllSafe()
            elseif cmd == "track" then
                ns.Features.TrackingSwitcher:HandleCommand(rest)
            elseif cmd == "fish" then
                ns.Features.FishingCardHud:HandleCommand(rest)
            elseif cmd == "dock" then
                local shown = ns.Features.QuickDockHud:Toggle()
                ns.Api.SafeAPI.Print(shown and "빠른 도구 바 표시 ON" or "빠른 도구 바 숨김 OFF")
            elseif cmd == "help" then
                ns.Api.SafeAPI.Print("허브 페이지: /fs [dungeons|bis|professions|questguide|codex|partyfinder|utilities|ledger|fonts|settings|move]")
                ns.Api.SafeAPI.Print("기능 커맨드: /fs [k|fish|dock|setup|track|mail|bridges|reset|gdkp|kw|train|farm|fav|profile|protect|cheap|layer|xp|pull|timer|clearway] · /fsdb · /way <x> <y> [이름]")
            else
                ns.UI.CommandHub:Toggle()
            end
        end

        _G.SLASH_FOREVERSUITE1 = "/fs"
        _G.SLASH_FOREVERSUITE2 = "/fs2"
        _G.SlashCmdList["FOREVERSUITE"] = HandleMainSlash
        _G.SlashCmdList["FOREVERSUITEV2"] = HandleMainSlash

        local function HandleWaySlash(raw)
            ns.Features.NavigationHud:HandleWaySlash(raw)
        end
        _G.SLASH_FOREVERSUITEWAY1 = "/way"
        _G.SLASH_FOREVERSUITEWAY2 = "/way2"
        _G.SlashCmdList["FOREVERSUITEWAY"] = HandleWaySlash
        _G.SlashCmdList["FOREVERSUITEWAYV2"] = HandleWaySlash

        local function HandleDbSlash(raw)
            local trimmed = string_match(tostring(raw or ""), "^%s*(.-)%s*$") or ""
            local sub, arg = string_match(trimmed, "^(%S+)%s*(.*)$")
            sub = sub and string_lower(sub) or ""
            arg = arg and string_lower(arg) or ""
            if sub == "restore" and arg == "v5" then
                local ok, reason = ns.Api.ProfileStore:RestoreV5()
                if ok then
                    ns.Api.SafeAPI.Print("v5 백업 스냅샷으로 복원했습니다. /reload 로 반영하세요.")
                else
                    ns.Api.SafeAPI.Print("복원 가능한 v5 백업이 없습니다 (" .. tostring(reason) .. ").")
                end
            else
                local ver = ns.Api.ProfileStore.db and ns.Api.ProfileStore.db.schemaVersion or "?"
                local dev = ns.Api.ProfileStore:GetDeviceKey()
                ns.Api.SafeAPI.Print("ForeverSuite DB 스키마 v" .. tostring(ver) .. " · 기기키=" .. tostring(dev) .. " · 복원: /fsdb restore v5")
            end
        end
        _G.SLASH_FOREVERSUITEDB1 = "/fsdb"
        _G.SlashCmdList["FOREVERSUITEDB"] = HandleDbSlash
    end

    self.initialized = true
end

_G.ForeverSuite = ns
_G.ForeverSuiteV2 = ns

ns.Api.EventBus:OnEvent("v2:boot", "PLAYER_LOGIN", function()
    Bootstrap:Init()
end)

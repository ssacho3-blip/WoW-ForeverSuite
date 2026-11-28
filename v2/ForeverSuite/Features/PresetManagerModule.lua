-- Module: Features/PresetManagerModule.lua
-- Responsibility: A7 Full Parity - Safe OOC Game CVar Presets, ActionBar Loadout Snapshots/Restore,
--                 EditMode Layout String Export/Import, and Account-Wide Shared Character Settings Sync.
-- Layer: Features (strictly OOC via SafeAPI.InCombat() guards; zero combat taint).
local _, ns = ...
ns.Features = ns.Features or {}

local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local type = type

local RECOMMENDED_GAME_CVARS = {
    { name = "autoLootDefault", value = "1", label = "자동 루팅 기본 활성화" },
    { name = "instantQuestText", value = "1", label = "퀘스트 텍스트 즉시 표시" },
    { name = "cameraDistanceMaxZoomFactor", value = "2.6", label = "최대 카메라 시야 확장" },
    { name = "floatingCombatTextCombatDamage", value = "1", label = "전투 데미지 숫자 표시" },
    { name = "chatClassColorOverride", value = "0", label = "채팅 직업 색상 표시" },
}

local PresetManagerModule = {
    RECOMMENDED_GAME_CVARS = RECOMMENDED_GAME_CVARS,
}
ns.Features.PresetManagerModule = PresetManagerModule

function PresetManagerModule:ApplyRecommendedGameCVars()
    if ns.Api.SafeAPI.InCombat() then return false, "IN_COMBAT" end
    -- A7: Load real compiled GodJohnson GameSettingsPresetData5139 (189 safe CVars, excluding enemy nameplates & audio/hw)
    ns.Api.SafeAPI.LoadDataPack("ForeverSuite_Data_Atlas")
    local pack = _G.ForeverSuiteData and _G.ForeverSuiteData.packs and _G.ForeverSuiteData.packs.game_presets
    local list = (type(pack) == "table" and type(pack.entries) == "table" and #pack.entries > 0)
        and pack.entries or RECOMMENDED_GAME_CVARS
    local applied, skipped = 0, 0
    for _, cv in ipairs(list) do
        if type(cv) == "table" and type(cv.name) == "string" and type(cv.value) == "string" then
            -- Verify CVar exists on this client build when GetCVar is available; report honest applied/skipped counts
            local existing, gStatus = ns.Api.GameAdapters.GetCVarSafe(cv.name)
            local canApply = (existing ~= nil) or (gStatus == "UNSUPPORTED")
            if canApply and ns.Api.GameAdapters.SetCVarSafe(cv.name, cv.value) then
                applied = applied + 1
            else
                skipped = skipped + 1
            end
        end
    end
    ns.Api.SafeAPI.Print("권장 게임 CVar 프리셋: 적용 " .. tostring(applied) .. "개 · 미지원/건너뜀 " .. tostring(skipped) .. "개 (총 " .. tostring(#list) .. "개)")
    return applied > 0, applied, skipped
end

function PresetManagerModule:SaveActionBarLoadout(slotName)
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite()) then return false, "READ_ONLY" end
    local name = (type(slotName) == "string" and slotName ~= "") and slotName or "default"
    local snap = ns.Api.GameAdapters.SnapshotActionBarSafe(72)
    local loadouts = ns.Api.ProfileStore:GetState("actionBarLoadouts")
    if type(loadouts) ~= "table" then loadouts = {} end
    local count = 0
    for _ in pairs(snap) do count = count + 1 end
    loadouts[name] = {
        savedAt = ns.Api.GameAdapters.GetEpochTimestamp(),
        count = count,
        slots = snap,
    }
    ns.Api.ProfileStore:SetState("actionBarLoadouts", loadouts)
    ns.Api.SafeAPI.Print("행동 단축바 스냅샷 저장: [" .. name .. "] (" .. tostring(count) .. "슬롯)")
    return true, count
end

function PresetManagerModule:RestoreActionBarLoadout(slotName)
    if ns.Api.SafeAPI.InCombat() then return false, "IN_COMBAT" end
    local name = (type(slotName) == "string" and slotName ~= "") and slotName or "default"
    local loadouts = ns.Api.ProfileStore and ns.Api.ProfileStore:GetState("actionBarLoadouts")
    local rec = type(loadouts) == "table" and loadouts[name] or nil
    if type(rec) ~= "table" or type(rec.slots) ~= "table" then
        ns.Api.SafeAPI.Print("저장된 행동 단축바 프리셋을 찾을 수 없습니다: " .. name)
        return false, "NOT_FOUND"
    end
    local ok, cnt = ns.Api.GameAdapters.RestoreActionBarSafe(rec.slots)
    if ok then
        ns.Api.SafeAPI.Print("행동 단축바 프리셋 복원 완료: [" .. name .. "] (" .. tostring(cnt) .. "슬롯)")
    end
    return ok, cnt
end

function PresetManagerModule:ExportEditModeLayout()
    local str, st = ns.Api.GameAdapters.ExportEditModeStringSafe()
    if str then
        if ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() then
            ns.Api.ProfileStore:SetState("savedEditModeString", str)
        end
        return str, "OK"
    end
    return nil, st
end

function PresetManagerModule:ImportEditModeLayout(layoutStr, name)
    local ok, st = ns.Api.GameAdapters.ImportEditModeStringSafe(layoutStr, name)
    if ok then
        ns.Api.SafeAPI.Print("편집 모드 레이아웃 가져오기 완료: " .. tostring(name or "ForeverSuite"))
    else
        ns.Api.SafeAPI.Print("편집 모드 레이아웃 가져오기 실패: " .. tostring(st))
    end
    return ok, st
end

function PresetManagerModule:SyncSharedSettingsToChar()
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore.db and ns.Api.ProfileStore.charDB) then
        return false, "UNAVAILABLE"
    end
    local shared = ns.Api.ProfileStore.db.v2 and ns.Api.ProfileStore.db.v2.settings
    if type(shared) ~= "table" then return false, "NO_SETTINGS" end
    local copy = {}
    for sec, tbl in pairs(shared) do
        if type(tbl) == "table" then
            copy[sec] = {}
            for k, v in pairs(tbl) do copy[sec][k] = v end
        end
    end
    ns.Api.ProfileStore.charDB.syncedSharedSettings = copy
    ns.Api.ProfileStore.charDB.syncedAt = ns.Api.GameAdapters.GetEpochTimestamp()
    return true, "SYNCED"
end

function PresetManagerModule:RestoreSharedSettingsFromChar()
    if not (ns.Api.ProfileStore and ns.Api.ProfileStore:CanWrite() and ns.Api.ProfileStore.charDB) then
        return false, "UNAVAILABLE"
    end
    local saved = ns.Api.ProfileStore.charDB.syncedSharedSettings
    if type(saved) ~= "table" then return false, "NOT_FOUND" end
    local applied = 0
    for sec, tbl in pairs(saved) do
        if type(tbl) == "table" then
            for k, v in pairs(tbl) do
                if ns.Api.ProfileStore:Set(sec, k, v) then
                    applied = applied + 1
                end
            end
        end
    end
    ns.Api.SafeAPI.Print("캐릭터 동기화 설정 복원 완료 (" .. tostring(applied) .. "개)")
    return true, applied
end

-- Module: Domain/DataResolver.lua
-- Responsibility: Pure 3-tier data resolution (STATIC -> LIVE -> EMBEDDED <=60KB), manifest interface/TTL
--                 compatibility check, and 0-pack survival embedded fallback tables.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local pcall = pcall
local tonumber = tonumber

local DataResolver = {
    TARGET_INTERFACE = 16001,
}
ns.Domain.DataResolver = DataResolver

-- Essential offline fallback subset (< 60KB) guaranteeing 100% core operation even when ForeverSuite_Data is deleted.
DataResolver.CORE_EMBEDDED = {
    fishing = {
        ["엘윈 숲"] = { title = "은빛머리 연어 · 반짝이는 작은 물고기", minSkill = 1 },
        ["듀로타"] = { title = "은빛머리 연어 · 붉은지느러미 개복치", minSkill = 1 },
        ["불모의 땅"] = { title = "돌비늘 뱀장어 · 돌연변이 물고기", minSkill = 75 },
        ["가시덤불 골짜기"] = { title = "돌비늘 뱀장어 · 겨울 오징어", minSkill = 130 },
        ["타나리스"] = { title = "돌비늘 뱀장어 · 불지느러미 통돔", minSkill = 205 },
        ["아즈샤라"] = { title = "겨울 오징어 · 돌비늘 뱀장어", minSkill = 205 },
    },
    craft_cooldowns = {
        transmute = { name = "연금술 변환 (아케이나이트/원소)", hours = 48 },
        salt_shaker = { name = "소금 정제기 (정제된 깊은바다 소금)", hours = 72 },
        mooncloth = { name = "달빛 옷감 (달샘 변환)", hours = 96 },
    },
    dungeons = {
        [36] = { name = "죽음의 폐광", minLevel = 15, maxLevel = 21, zone = "서부 몰락지대" },
        [43] = { name = "통곡의 동굴", minLevel = 15, maxLevel = 25, zone = "불모의 땅" },
        [189] = { name = "붉은십자군 수도원", minLevel = 28, maxLevel = 42, zone = "티리스팔 숲" },
        [209] = { name = "줄파락", minLevel = 42, maxLevel = 48, zone = "타나리스" },
        [230] = { name = "검은바위 나락", minLevel = 52, maxLevel = 60, zone = "이글거리는 협곡" },
        [409] = { name = "화산 심장부", minLevel = 60, maxLevel = 60, zone = "검은바위 산" },
    },
}

-- Returns (isCompatibleBool, reasonCode: "OK" | "NO_MANIFEST" | "STALE_INTERFACE" | "TTL_EXPIRED")
function DataResolver.IsManifestCompatible(manifest, currentInterface, nowEpoch)
    if type(manifest) ~= "table" then
        return true, "NO_MANIFEST"
    end
    local curIf = tonumber(currentInterface) or DataResolver.TARGET_INTERFACE
    local builtIf = tonumber(manifest.builtForInterface)
    if builtIf and builtIf ~= curIf then
        return false, "STALE_INTERFACE"
    end
    local gen = tonumber(manifest.generatedEpoch)
    local ttlDays = tonumber(manifest.ttlDays)
    local now = tonumber(nowEpoch)
    if gen and ttlDays and ttlDays > 0 and now and now > 0 then
        if (now - gen) > (ttlDays * 86400) then
            return false, "TTL_EXPIRED"
        end
    end
    return true, "OK"
end

-- 3-Tier resolution gateway:
--   1. STATIC: pack._status == "ACTIVE" (or _complete ~= false) & manifest compatible & entry exists
--   2. LIVE:   pcall(liveGetterFn, kind, key) returns non-nil
--   3. EMBED:  CORE_EMBEDDED[kind][key] (or custom embeddedMap)
--   Else:      nil, "MISSING" (Zero Fabricated Status — never returns fake 0)
function DataResolver.Resolve(kind, key, staticPacks, manifest, currentInterface, nowEpoch, liveGetterFn, embeddedMap)
    if type(kind) ~= "string" or kind == "" or key == nil then
        return nil, "INVALID_ARGS"
    end

    local manifestOk, manifestReason = DataResolver.IsManifestCompatible(manifest, currentInterface, nowEpoch)

    -- Tier 1: STATIC
    if manifestOk and type(staticPacks) == "table" then
        local pack = staticPacks[kind]
        if type(pack) == "table" and pack._complete ~= false and pack._status ~= "PENDING" then
            if type(pack.byKey) == "table" and pack.byKey[key] ~= nil then
                return pack.byKey[key], "STATIC"
            end
            if type(pack.entries) == "table" then
                if pack.entries[key] ~= nil then
                    return pack.entries[key], "STATIC"
                end
                for i = 1, #pack.entries do
                    local row = pack.entries[i]
                    if type(row) == "table" and (row.id == key or row.itemID == key or row.questID == key or row.zone == key) then
                        return row, "STATIC"
                    end
                end
            end
        end
    end

    -- Tier 2: LIVE API fallback
    if type(liveGetterFn) == "function" then
        local ok, liveVal = pcall(liveGetterFn, kind, key)
        if ok and liveVal ~= nil then
            return liveVal, manifestOk and "LIVE" or "LIVE_STALE_BYPASS"
        end
    end

    -- Tier 3: OFFLINE EMBEDDED fallback (<= 60KB, 0-pack survival)
    local emb = (type(embeddedMap) == "table") and embeddedMap or DataResolver.CORE_EMBEDDED
    local kindTbl = type(emb[kind]) == "table" and emb[kind] or nil
    if kindTbl and kindTbl[key] ~= nil then
        return kindTbl[key], manifestOk and "EMBEDDED" or "EMBEDDED_STALE_BYPASS"
    end

    return nil, manifestOk and "MISSING" or manifestReason
end

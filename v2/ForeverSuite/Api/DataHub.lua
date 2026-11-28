-- Module: Api/DataHub.lua
-- Responsibility: Single 3-tier data gateway (STATIC -> LIVE -> EMBEDDED) with FS.Data.epoch cache invalidation
--                 and [STALE_PACK] diagnostic telemetry (guarantees 100% 0-pack survival).
-- Layer: Api (no Frame creation, depends ONLY on Domain + Api/SafeAPI).
local _, ns = ...
ns.Api = ns.Api or {}

local type = type
local pcall = pcall
local tonumber = tonumber

local DataHub = {
    localEpoch = 0,
    lastManifestReason = "OK",
}
ns.Api.DataHub = DataHub
ns.Data = DataHub

local function GetCurrentInterface()
    if type(_G.GetBuildInfo) == "function" then
        local ok, _, _, _, tocVer = pcall(_G.GetBuildInfo)
        if ok and type(tocVer) == "number" and tocVer > 0 then
            return tocVer
        end
    end
    return ns.Domain.DataResolver.TARGET_INTERFACE
end

local function GetNowEpoch()
    if type(_G.time) == "function" then
        local ok, t = pcall(_G.time)
        if ok and type(t) == "number" and t > 0 then
            return t
        end
    end
    return 0
end

function DataHub:GetEpoch()
    local packEpoch = (_G.ForeverSuiteData and tonumber(_G.ForeverSuiteData.epoch)) or 0
    return self.localEpoch + packEpoch
end

function DataHub:BumpEpoch()
    self.localEpoch = self.localEpoch + 1
    return self:GetEpoch()
end

function DataHub:CheckManifestStatus()
    local manifest = _G.ForeverSuiteData and _G.ForeverSuiteData.manifest or nil
    local ok, reason = ns.Domain.DataResolver.IsManifestCompatible(
        manifest,
        GetCurrentInterface(),
        GetNowEpoch()
    )
    self.lastManifestReason = reason
    return ok, reason
end

function DataHub:IsStalePack()
    local ok = self:CheckManifestStatus()
    return not ok
end

-- Unified gateway: FS.Data:Get(kind, key, liveGetterFn) -> value | nil, tierTag
function DataHub:Get(kind, key, liveGetterFn)
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs or nil
    local manifest = _G.ForeverSuiteData and _G.ForeverSuiteData.manifest or nil
    local curIf = GetCurrentInterface()
    local nowEpoch = GetNowEpoch()
    local okManifest, reason = ns.Domain.DataResolver.IsManifestCompatible(manifest, curIf, nowEpoch)
    self.lastManifestReason = reason
    return ns.Domain.DataResolver.Resolve(
        kind,
        key,
        packs,
        manifest,
        curIf,
        nowEpoch,
        liveGetterFn,
        ns.Domain.DataResolver.CORE_EMBEDDED
    )
end

function DataHub:GetDiagnostics()
    local ok, reason = self:CheckManifestStatus()
    local packCount = 0
    local packs = _G.ForeverSuiteData and _G.ForeverSuiteData.packs or nil
    if type(packs) == "table" then
        for _ in pairs(packs) do
            packCount = packCount + 1
        end
    end
    return {
        epoch = self:GetEpoch(),
        manifestOk = ok,
        manifestStatus = ok and "OK" or "[STALE_PACK:" .. tostring(reason) .. "]",
        loadedPacks = packCount,
        zeroPackMode = (packCount == 0),
    }
end

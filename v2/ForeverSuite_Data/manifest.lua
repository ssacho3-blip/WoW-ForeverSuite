-- Module: ForeverSuite_Data/manifest.lua
-- Responsibility: v6 Static LoD Data Pack Manifest (interface version, build, TTL, and pack registry).
--                 Enables instant LIVE/EMBEDDED fallback when WoW Forever interface updates invalidate static packs.
_G.ForeverSuiteData = _G.ForeverSuiteData or { version = "6.0.0", epoch = 0, packs = {} }

_G.ForeverSuiteData.manifest = {
    schema = 6,
    builtForInterface = 16001,
    builtForBuild = "71037",
    generatedEpoch = 1795796800,
    ttlDays = 365,
    packs = {
        bis = { shards = 1, ttlDays = 365 },
        dungeons = { shards = 1, ttlDays = 365 },
        fishing = { shards = 1, ttlDays = 365 },
        professions = { shards = 1, ttlDays = 365 },
        rewards = { shards = 1, ttlDays = 365 },
    },
}

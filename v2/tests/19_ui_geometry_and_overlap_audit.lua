-- Test 19: ForeverSuite v4.0 Automated UI Pixel-Box Geometry, Overlap, Clipping & HUD Layout Audit
-- Resolves real WoW anchor chains across all 12 CommandHub pages (including all sub-tabs),
-- modal/chrome frames, and all 15+ Floating HUDs at 1920x1080 and 1366x768.
local ns = _G.ForeverSuite
assert(type(ns) == "table", "ForeverSuite namespace must exist")

_G.__FS_MOCK.playerName = "아르타스"
_G.__FS_MOCK.playerClass = "HUNTER"
_G.__FS_MOCK.level = 60
_G.__FS_MOCK.zoneText = "동부 역병지대"
_G.__FS_MOCK.bagFreeSlots = 14
_G.__FS_MOCK.money = 2450800
_G.__FS_MOCK.durability = { [1] = { 88, 100 }, [5] = { 92, 100 } }
_G.__FS_MOCK.inGroup = true
_G.__FS_MOCK.groupMembers = 5
_G.__FS_MOCK.playerPos = { mapID = 1423, x = 0.45, y = 0.52, facing = 0.8 }
_G.__FS_MOCK.questEntries = {
    { title = "붉은십자군 정찰", questID = 5201, level = 58, isHeader = false },
    { title = "역병지대 정화", questID = 5202, level = 59, isHeader = false },
    { title = "스트라솔름의 수호자", questID = 5203, level = 60, isHeader = false },
}

__FS_FIRE_EVENT("PLAYER_LOGIN")

local origLoad = C_AddOns.LoadAddOn
C_AddOns.LoadAddOn = function(name)
    if string.find(tostring(name), "^ForeverSuite_Data") or name == "ForeverSuite_Media_Assets" or name == "ForeverSuite_Fonts_Global" then
        local loaded = __FS_LOAD_DATA_ADDON(name)
        _G.__FS_MOCK.loadedAddOns[name] = loaded
        return loaded, loaded and nil or "LOAD_FAILED"
    end
    return origLoad(name)
end

-- Load ForeverSuite_Fonts_Global manually if not loaded via __FS_LOAD_DATA_ADDON
if type(_G.ForeverSuiteGlobalFonts) ~= "table" then
    pcall(__FS_LOAD_DATA_ADDON, "ForeverSuite_Fonts_Global")
end
-- Ensure all 18 global fonts are present when testing FontsPage geometry even in headless mock
if type(_G.ForeverSuiteGlobalFonts) ~= "table" then
    local labels = {}
    for i = 1, 18 do
        labels[i] = { id = "font_" .. tostring(i), label = "한글폰트" .. tostring(i) }
    end
    _G.ForeverSuiteGlobalFonts = {
        FONT_LABELS = labels,
        GetConfig = function() return { enabled = false, worldFont = "font_1", damageFont = "font_1", damageScale = 1.0, chatFontSize = 14 } end,
        Configure = function() return true end,
    }
end

-- =========================================================================
-- WoW Anchor Geometry Solver (origin = BOTTOMLEFT of UIParent, +X right, +Y up)
-- =========================================================================
local function AnchorXY(rect, pt)
    local cx = (rect.left + rect.right) * 0.5
    local cy = (rect.bottom + rect.top) * 0.5
    if pt == "TOPLEFT" then return rect.left, rect.top
    elseif pt == "TOP" then return cx, rect.top
    elseif pt == "TOPRIGHT" then return rect.right, rect.top
    elseif pt == "LEFT" then return rect.left, cy
    elseif pt == "CENTER" then return cx, cy
    elseif pt == "RIGHT" then return rect.right, cy
    elseif pt == "BOTTOMLEFT" then return rect.left, rect.bottom
    elseif pt == "BOTTOM" then return cx, rect.bottom
    elseif pt == "BOTTOMRIGHT" then return rect.right, rect.bottom
    end
    return cx, cy
end

local function ParsePointArgs(p, parent)
    local pt = p[1] or "CENTER"
    local relTo, relPt, ox, oy
    if type(p[2]) == "table" then
        relTo = p[2]
        if type(p[3]) == "string" then
            relPt = p[3]
            ox = tonumber(p[4]) or 0
            oy = tonumber(p[5]) or 0
        else
            relPt = pt
            ox = tonumber(p[3]) or 0
            oy = tonumber(p[4]) or 0
        end
    elseif type(p[2]) == "string" then
        relTo = _G[p[2]] or parent or UIParent
        relPt = type(p[3]) == "string" and p[3] or pt
        ox = tonumber(p[4]) or 0
        oy = tonumber(p[5]) or 0
    else
        relTo = parent or UIParent
        relPt = pt
        ox = tonumber(p[2]) or 0
        oy = tonumber(p[3]) or 0
    end
    return pt, relTo, relPt, ox, oy
end

local function MakeResolver(screenW, screenH)
    local cache = {}
    local visiting = {}
    local function Resolve(f)
        if not f then return nil end
        if cache[f] ~= nil then return cache[f] or nil end
        if f == UIParent then
            local r = { left = 0, bottom = 0, right = screenW, top = screenH }
            cache[f] = r
            return r
        end
        if visiting[f] then return nil end
        visiting[f] = true

        local rect = nil
        if f._allPoints then
            local tgt = (type(f._allPoints) == "table") and f._allPoints or f._parent
            local tr = Resolve(tgt)
            if tr then
                rect = { left = tr.left, bottom = tr.bottom, right = tr.right, top = tr.top }
            end
        elseif type(f._points) == "table" and #f._points > 0 then
            local left, right, cx, top, bottom, cy
            for _, p in ipairs(f._points) do
                local pt, relTo, relPt, ox, oy = ParsePointArgs(p, f._parent)
                local rr = Resolve(relTo)
                if rr then
                    local ax, ay = AnchorXY(rr, relPt)
                    local tx, ty = ax + ox, ay + oy
                    if pt == "TOPLEFT" then left = tx; top = ty
                    elseif pt == "TOP" then cx = tx; top = ty
                    elseif pt == "TOPRIGHT" then right = tx; top = ty
                    elseif pt == "LEFT" then left = tx; cy = ty
                    elseif pt == "CENTER" then cx = tx; cy = ty
                    elseif pt == "RIGHT" then right = tx; cy = ty
                    elseif pt == "BOTTOMLEFT" then left = tx; bottom = ty
                    elseif pt == "BOTTOM" then cx = tx; bottom = ty
                    elseif pt == "BOTTOMRIGHT" then right = tx; bottom = ty
                    end
                end
            end
            local w = tonumber(f._width) or 0
            local h = tonumber(f._height) or 0
            if left and right then
                -- stretched horizontally
            elseif left then
                right = left + w
            elseif right then
                left = right - w
            elseif cx then
                left = cx - w * 0.5
                right = cx + w * 0.5
            end
            if top and bottom then
                -- stretched vertically
            elseif top then
                bottom = top - h
            elseif bottom then
                top = bottom + h
            elseif cy then
                bottom = cy - h * 0.5
                top = cy + h * 0.5
            end
            if left and right and bottom and top then
                rect = { left = left, bottom = bottom, right = right, top = top }
            end
        elseif f._rect then
            rect = {
                left = f._rect.left,
                bottom = f._rect.bottom,
                right = f._rect.left + f._rect.width,
                top = f._rect.bottom + f._rect.height,
            }
        end

        visiting[f] = nil
        cache[f] = rect or false
        return rect
    end
    return Resolve
end

local function IsEffectivelyShown(f)
    local cur = f
    local guard = 0
    while cur and cur ~= UIParent and guard < 32 do
        if cur._shown == false then return false end
        cur = cur._parent
        guard = guard + 1
    end
    return true
end

local function FrameTag(f)
    if f._name and f._name ~= "" then return f._name end
    if f._label and type(f._label._text) == "string" and f._label._text ~= "" then
        return f._kind .. "['" .. string.sub(f._label._text, 1, 24) .. "']"
    end
    if f._title and type(f._title._text) == "string" and f._title._text ~= "" then
        return f._kind .. "['" .. string.sub(f._title._text, 1, 24) .. "']"
    end
    if f._left and type(f._left._text) == "string" and f._left._text ~= "" then
        return f._kind .. "['" .. string.sub(f._left._text, 1, 24) .. "']"
    end
    if f._placeholder and type(f._placeholder._text) == "string" and f._placeholder._text ~= "" then
        return f._kind .. "[input:'" .. string.sub(f._placeholder._text, 1, 20) .. "']"
    end
    if f._caption and type(f._caption._text) == "string" and f._caption._text ~= "" then
        return f._kind .. "[card:'" .. string.sub(f._caption._text, 1, 20) .. "']"
    end
    return tostring(f._kind or "Frame")
end

local function RectStr(r)
    return string.format("(x=%.0f..%.0f w=%.0f, y=%.0f..%.0f h=%.0f)", r.left, r.right, r.right - r.left, r.bottom, r.top, r.top - r.bottom)
end

local function AuditSubtree(rootFrame, label, screenW, screenH, issues)
    local Resolve = MakeResolver(screenW, screenH)
    local childrenByParent = {}
    for _, f in ipairs(_G.__FS_MOCK.frames) do
        local p = f._parent
        if p then
            childrenByParent[p] = childrenByParent[p] or {}
            childrenByParent[p][#childrenByParent[p] + 1] = f
        end
    end

    local function Walk(parent)
        if not IsEffectivelyShown(parent) then return end
        local pr = Resolve(parent)
        if not pr then return end
        local kids = childrenByParent[parent]
        if not kids then return end

        local visibleKids = {}
        for _, c in ipairs(kids) do
            if IsEffectivelyShown(c) and (not c._allPoints) then
                local cr = Resolve(c)
                if cr then
                    local cw = cr.right - cr.left
                    local ch = cr.top - cr.bottom
                    -- Skip pure decorative 1-3px rules or tiny checkbox fills
                    local isTinyDecor = (cw <= 4 or ch <= 4)
                    if not isTinyDecor then
                        if cw < 6 or ch < 6 then
                            issues[#issues + 1] = string.format("[%s] CRUSHED %s %s inside %s %s",
                                label, FrameTag(c), RectStr(cr), FrameTag(parent), RectStr(pr))
                        end
                        -- Containment check (1.5px tolerance for border stroke)
                        if cr.left < pr.left - 1.5 or cr.right > pr.right + 1.5
                            or cr.bottom < pr.bottom - 1.5 or cr.top > pr.top + 1.5
                        then
                            issues[#issues + 1] = string.format("[%s] OVERFLOW %s %s outside parent %s %s",
                                label, FrameTag(c), RectStr(cr), FrameTag(parent), RectStr(pr))
                        end
                        visibleKids[#visibleKids + 1] = { frame = c, rect = cr }
                    end
                    Walk(c)
                end
            elseif IsEffectivelyShown(c) and c._allPoints then
                Walk(c)
            end
        end

        -- Pairwise sibling overlap check (>1.5px in BOTH X and Y)
        for i = 1, #visibleKids do
            for j = i + 1, #visibleKids do
                local a, b = visibleKids[i], visibleKids[j]
                -- Skip intentional map pin buttons over map card background (pins are children of mapPanel; mTex is a Texture not Frame)
                local ox = math.min(a.rect.right, b.rect.right) - math.max(a.rect.left, b.rect.left)
                local oy = math.min(a.rect.top, b.rect.top) - math.max(a.rect.bottom, b.rect.bottom)
                if ox > 1.5 and oy > 1.5 then
                    issues[#issues + 1] = string.format("[%s] OVERLAP(%.0fx%.0fpx) %s %s <-> %s %s (in %s)",
                        label, ox, oy, FrameTag(a.frame), RectStr(a.rect), FrameTag(b.frame), RectStr(b.rect), FrameTag(parent))
                end
            end
        end
    end

    Walk(rootFrame)
end

local allIssues = {}

-- 1. Open CommandHub and audit EVERY page + sub-tab!
local hub = ns.UI.CommandHub
hub:Toggle()
assert(hub.window and hub.window:IsShown(), "CommandHub must open")

-- Audit hub chrome (header, rail, footer)
AuditSubtree(hub.window, "Hub:chrome", 1920, 1080, allIssues)

local function AuditPage(pageId, subLabel, prepFn)
    hub:SelectPage(pageId)
    if prepFn then prepFn() end
    AuditSubtree(hub.contentHost, "Page:" .. pageId .. (subLabel and (":" .. subLabel) or ""), 1920, 1080, allIssues)
end

AuditPage("home")
AuditPage("questguide", "class", function()
    ns.Features.QuestGuidePage.activeTab = "class"
    ns.Features.QuestGuidePage:Render("")
end)
AuditPage("questguide", "leveling", function()
    ns.Features.QuestGuidePage.activeTab = "leveling"
    ns.Features.QuestGuidePage:Render("")
end)
AuditPage("questguide", "books", function()
    ns.Features.QuestGuidePage.activeTab = "books"
    ns.Features.QuestGuidePage:Render("")
end)
AuditPage("questguide", "routes", function()
    ns.Features.QuestGuidePage.activeTab = "routes"
    ns.Features.QuestGuidePage:Render("")
end)
AuditPage("questguide", "special", function()
    ns.Features.QuestGuidePage.activeTab = "special"
    ns.Features.QuestGuidePage:Render("")
end)

AuditPage("dungeons", "overview", function()
    ns.Features.DungeonBrowserPage.activeTab = "overview"
    ns.Features.DungeonBrowserPage:RenderRight()
end)
AuditPage("dungeons", "map", function()
    ns.Features.DungeonBrowserPage.activeTab = "map"
    ns.Features.DungeonBrowserPage:RenderRight()
end)
AuditPage("dungeons", "bosses", function()
    ns.Features.DungeonBrowserPage.activeTab = "bosses"
    ns.Features.DungeonBrowserPage:RenderRight()
end)
AuditPage("dungeons", "quests", function()
    ns.Features.DungeonBrowserPage.activeTab = "quests"
    ns.Features.DungeonBrowserPage:RenderRight()
end)
AuditPage("dungeons", "steps", function()
    ns.Features.DungeonBrowserPage.activeTab = "steps"
    ns.Features.DungeonBrowserPage:RenderRight()
end)
AuditPage("dungeons", "report", function()
    ns.Features.DungeonBrowserPage.activeTab = "report"
    ns.Features.DungeonBrowserPage:RenderRight()
end)

AuditPage("bis", "default")

AuditPage("professions", "guide", function()
    ns.Features.ProfessionPage.activeTab = "guide"
    ns.Features.ProfessionPage:RenderRight()
end)
AuditPage("professions", "recipes", function()
    ns.Features.ProfessionPage.activeTab = "recipes"
    ns.Features.ProfessionPage:RenderRight()
end)
AuditPage("professions", "trainers", function()
    ns.Features.ProfessionPage.activeTab = "trainers"
    ns.Features.ProfessionPage:RenderRight()
end)
AuditPage("professions", "materials", function()
    ns.Features.ProfessionPage.activeTab = "materials"
    ns.Features.ProfessionPage:RenderRight()
end)
AuditPage("professions", "picks", function()
    ns.Features.ProfessionPage.activeTab = "picks"
    ns.Features.ProfessionPage:RenderRight()
end)

for _, pk in ipairs({ "fishing", "dungeons", "rewards", "hunter_pets", "item_catalog", "quest_tips" }) do
    AuditPage("codex", pk, function()
        ns.Features.CodexPage:SelectPack(pk)
    end)
end

AuditPage("partyfinder", "populated", function()
    ns.Features.PartyFinderPage:IngestChatMessage("스트라솔름 후문 탱1 힐1 모십니다", "성기사테스터", "파티찾기")
    ns.Features.PartyFinderPage:IngestChatMessage("스칼로맨스 딜2 힐1 구함", "법사테스터", "파티찾기")
    ns.Features.PartyFinderPage:Render("")
    if ns.Features.PartyFinderPage.lastDisplayedList[1] then
        ns.Features.PartyFinderPage:SelectListing(ns.Features.PartyFinderPage.lastDisplayedList[1])
    end
end)

for _, sub in ipairs({ "gdkp", "bookmarks", "protect", "chat", "alts", "trade", "character" }) do
    AuditPage("utilities", sub, function()
        ns.Features.UtilitiesPage.activeSub = sub
        ns.Features.UtilitiesPage.scrollOffset = 0
        ns.Features.UtilitiesPage:Render("")
    end)
end
AuditPage("utilities", "gdkp_active_auction", function()
    ns.Features.UtilitiesPage.activeSub = "gdkp"
    ns.Features.UtilitiesPage:AddGdkpSaleDirect("화산심장부 벨트", "전사1", 300)
    ns.Features.UtilitiesPage:StartGdkpAuctionDirect("설퍼라스의 눈", 500)
    ns.Features.UtilitiesPage:Render("")
end)
-- Verify active auction banner hides cleanly when switching to another sub-tab AND re-shows on return to gdkp
AuditPage("utilities", "bookmarks_during_auction", function()
    ns.Features.UtilitiesPage.activeSub = "bookmarks"
    ns.Features.UtilitiesPage:Render("")
    assert(ns.Features.UtilitiesPage.gdkpMeta.banner:IsShown() == false, "GDKP banner must hide when switching sub-tab")
end)
AuditPage("utilities", "gdkp_return_during_auction", function()
    ns.Features.UtilitiesPage.activeSub = "gdkp"
    ns.Features.UtilitiesPage:Render("")
    assert(ns.Features.UtilitiesPage.gdkpMeta.banner:IsShown() == true, "GDKP banner must re-show when returning to gdkp during open auction")
end)
ns.Features.UtilitiesPage:HandleGdkpCommand("cancel")

AuditPage("ledger")
AuditPage("fonts")
AuditPage("diagnostics")
for _, cat in ipairs({ "general", "quest", "combat", "ui", "social" }) do
    AuditPage("settings", cat, function()
        if ns.Features.SettingsPage.SelectCategory then
            ns.Features.SettingsPage:SelectCategory(cat)
        end
    end)
end

-- 1b. Stale UI text check across all created FontStrings in Hub
local function ScanStaleCopy(rootFrame)
    local seen = {}
    local function CheckText(lbl, tag)
        if type(lbl) ~= "table" or seen[lbl] then return end
        seen[lbl] = true
        local txt = type(lbl._text) == "string" and lbl._text or ""
        if txt == "" then return end
        if string.find(txt, "v3%.0", 1, false) or string.find(txt, "8대 LoD", 1, true) or string.find(txt, "8대 LoadOnDemand", 1, true) then
            allIssues[#allIssues + 1] = string.format("[StaleCopy] %s contains stale label: '%s'", tag, txt)
        end
    end
    for _, f in ipairs(_G.__FS_MOCK.frames) do
        CheckText(f._label, FrameTag(f))
        CheckText(f._title, FrameTag(f))
        CheckText(f._left, FrameTag(f))
        CheckText(f._right, FrameTag(f))
        CheckText(f._sub, FrameTag(f))
    end
    if ns.Features.HomePage and ns.Features.HomePage.heroTitle then
        CheckText(ns.Features.HomePage.heroTitle, "HomePage.heroTitle")
    end
end
ScanStaleCopy(hub.window)

-- 2. Audit WorldMapOverlay, CopyPasteModal, HudLayout.controlBar, QuickLootPopup
if ns.Features.WorldMapOverlay and ns.Features.WorldMapOverlay.EnsureCard then
    ns.Features.WorldMapOverlay:EnsureCard()
    if ns.Features.WorldMapOverlay.card then
        ns.Features.WorldMapOverlay.card:Show()
        AuditSubtree(ns.Features.WorldMapOverlay.card, "WorldMapOverlay", 1920, 1080, allIssues)
    end
end
local modal = ns.UI.Widgets.CopyPasteModal()
modal:OpenImport("테스트", "설명", function() return true end, "FS2:test")
AuditSubtree(modal, "CopyPasteModal", 1920, 1080, allIssues)
modal:Hide()

-- 3. Audit ALL 15 registered Floating HUD default positions at 1920x1080 AND 1366x768!
if ns.Features.DungeonBrowserPage and ns.Features.DungeonBrowserPage.EnsureQuickLootHud then
    ns.Features.DungeonBrowserPage:EnsureQuickLootHud()
    if ns.Features.DungeonBrowserPage.quickLootPopup then
        ns.Features.DungeonBrowserPage.quickLootPopup:Show()
        AuditSubtree(ns.Features.DungeonBrowserPage.quickLootPopup, "QuickLootPopup", 1920, 1080, allIssues)
        ns.Features.DungeonBrowserPage.quickLootPopup:Hide()
    end
end
if ns.Features.NavigationHud and ns.Features.NavigationHud.Init then ns.Features.NavigationHud:Init() end
if ns.Features.FishingCardHud and ns.Features.FishingCardHud.Init then ns.Features.FishingCardHud:Init() end
if ns.Features.EncounterTimerHud and ns.Features.EncounterTimerHud.Init then ns.Features.EncounterTimerHud:Init() end
if ns.Features.ThreatMeterHud and ns.Features.ThreatMeterHud.Init then ns.Features.ThreatMeterHud:Init() end
if ns.Features.CombatAssistHud and ns.Features.CombatAssistHud.Init then ns.Features.CombatAssistHud:Init() end
if ns.Features.StatusPillHud and ns.Features.StatusPillHud.Init then ns.Features.StatusPillHud:Init() end
if ns.Features.QuestTrackerView and ns.Features.QuestTrackerView.Init then ns.Features.QuestTrackerView:Init() end
if ns.Features.ChatToolsModule and ns.Features.ChatToolsModule.EnsureChannelBar then ns.Features.ChatToolsModule:EnsureChannelBar() end
if ns.Features.CombatHudPack and ns.Features.CombatHudPack.Init then ns.Features.CombatHudPack:Init() end
if ns.Features.ProcCooldownHud and ns.Features.ProcCooldownHud.Init then ns.Features.ProcCooldownHud:Init() end

-- Verify all 15 expected HUDs are actually registered before collision matrix!
local regCount = 0
for _ in pairs(ns.UI.HudLayout.registry) do regCount = regCount + 1 end
assert(regCount >= 15, "Expected at least 15 registered HUDs in HudLayout.registry, got " .. tostring(regCount))

local function AuditHudCollisions(sw, sh)
    local Resolve = MakeResolver(sw, sh)
    local huds = {}
    local blizzZones = {
        { id = "BlizzMinimap",     rect = { left = sw - 196, right = sw, bottom = sh - 200, top = sh } },
        { id = "BlizzChatFrame1",  rect = { left = 0, right = 440, bottom = 0, top = 220 } },
        { id = "BlizzBagMicroBar", rect = { left = sw - 310, right = sw, bottom = 0, top = 56 } },
        { id = "BlizzActionBars",  rect = { left = sw * 0.5 - 280, right = sw * 0.5 + 280, bottom = 0, top = 125 } },
    }
    for id, rec in pairs(ns.UI.HudLayout.registry) do
        local r = Resolve(rec.frame)
        if r then
            if r.left < -1 or r.right > sw + 1 or r.bottom < -1 or r.top > sh + 1 then
                allIssues[#allIssues + 1] = string.format("[HUD@%dx%d] OFFSCREEN %s %s", sw, sh, id, RectStr(r))
            end
            for _, bz in ipairs(blizzZones) do
                local ox = math.min(r.right, bz.rect.right) - math.max(r.left, bz.rect.left)
                local oy = math.min(r.top, bz.rect.top) - math.max(r.bottom, bz.rect.bottom)
                if ox > 1.5 and oy > 1.5 then
                    allIssues[#allIssues + 1] = string.format("[HUD@%dx%d] BLIZZ_COLLISION(%.0fx%.0fpx) %s %s <-> %s %s",
                        sw, sh, ox, oy, id, RectStr(r), bz.id, RectStr(bz.rect))
                end
            end
            huds[#huds + 1] = { id = id, rect = r }
        end
    end
    table.sort(huds, function(a, b) return a.id < b.id end)
    for i = 1, #huds do
        for j = i + 1, #huds do
            local a, b = huds[i], huds[j]
            local ox = math.min(a.rect.right, b.rect.right) - math.max(a.rect.left, b.rect.left)
            local oy = math.min(a.rect.top, b.rect.top) - math.max(a.rect.bottom, b.rect.bottom)
            if ox > 1.5 and oy > 1.5 then
                allIssues[#allIssues + 1] = string.format("[HUD@%dx%d] HUD_COLLISION(%.0fx%.0fpx) %s %s <-> %s %s",
                    sw, sh, ox, oy, a.id, RectStr(a.rect), b.id, RectStr(b.rect))
            end
        end
    end
end

-- Verify ALL 6 real UIParent viewports: 4K low-scale (2101x1182, 1920x1080), mid-band (1440x900),
-- 4K auto-scale (1366x768), MacBook Pro 16" Retina auto-scale (1188x768), and Remote 4:3 auto-scale (1024x768)!
AuditHudCollisions(2101, 1182)
AuditHudCollisions(1920, 1080)
AuditHudCollisions(1440, 900)
AuditHudCollisions(1366, 768)
AuditHudCollisions(1188, 768)
AuditHudCollisions(1024, 768)

-- Verify CommandHub responsive FitScaleToViewport across 4K, 4:3, and narrow windowed viewports
do
    local origW, origH = UIParent:GetWidth(), UIParent:GetHeight()
    UIParent:SetSize(1366, 768)
    assert(hub:FitScaleToViewport() == 1.0, "4K default (1366x768) must keep Hub scale 1.0")
    UIParent:SetSize(2101, 1182)
    assert(hub:FitScaleToViewport() == 1.0, "4K low-scale (2101x1182) must keep Hub scale 1.0")
    UIParent:SetSize(1024, 768)
    hub.window:ClearAllPoints()
    hub.window:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 500, -10)
    assert(hub:FitScaleToViewport() == 0.96, "Remote 4:3 (1024x768) must auto-scale Hub to 0.96")
    local pt = hub.window:GetPoint(1)
    assert(pt == "CENTER", "FitScaleToViewport must re-center Hub when shrinking below 1.0 to prevent offscreen drag clip")
    UIParent:SetSize(840, 600)
    assert(hub:FitScaleToViewport() == 0.79, "Narrow windowed (840x600) must auto-scale Hub to 0.79")
    UIParent:SetSize(origW, origH)
    hub:FitScaleToViewport()
end

-- Verify QuestTrackerView auto-caps visible rows at 9 on 768h viewports so even 15 active quests never hit ThreatMeter!
do
    local origW, origH = UIParent:GetWidth(), UIParent:GetHeight()
    local manyQuests = {}
    for i = 1, 15 do
        manyQuests[i] = { questID = 7000 + i, title = "퀘스트 #" .. tostring(i), level = 60, zone = "동부 역병지대", objectives = {} }
    end
    UIParent:SetSize(1366, 768)
    ns.Features.QuestTrackerView:Render(manyQuests, nil)
    local h768 = ns.Features.QuestTrackerView.container:GetHeight()
    assert(h768 <= 262, "On 768h viewport, 15-quest tracker must cap height <=262px to clear ThreatMeter (got " .. tostring(h768) .. ")")
    UIParent:SetSize(1440, 900)
    ns.Features.QuestTrackerView:Render(manyQuests, nil)
    local h900 = ns.Features.QuestTrackerView.container:GetHeight()
    assert(h900 <= 386, "On 900h mid-band viewport, 15-quest tracker must continuously cap height <=386px to clear ThreatMeter (got " .. tostring(h900) .. ")")
    UIParent:SetSize(origW, origH)
    ns.Features.QuestTrackerView:RefreshLive()
end

-- 4. Verify movable windows, screen-clamping, interactive HUD Edit Bar geometry, live overlap warning & ResolveOverlaps!
do
    -- CommandHub scale stepper & transform reset (including viewport-capped downward step!)
    hub:SetUserScale(1.25)
    local origW2, origH2 = UIParent:GetWidth(), UIParent:GetHeight()
    UIParent:SetSize(1024, 768)
    assert(hub:FitScaleToViewport() == 0.96, "125% desired scale at 1024x768 must cap to 0.96")
    assert(hub:AdjustUserScale(-0.05) == 0.91, "Single minus click while viewport-capped must immediately step down to 0.91")
    UIParent:SetSize(origW2, origH2)
    hub:ResetWindowTransform()
    assert(hub:GetUserScale() == 1.00, "CommandHub ResetWindowTransform must restore scale 1.00")

    -- All 4 floating popups/overlays must be screen-clamped & draggable
    assert(ns.Features.WorldMapOverlay.card._movable == true and ns.Features.WorldMapOverlay.card._clamped == true, "WorldMapOverlay must be draggable & clamped")
    assert(ns.Features.DungeonBrowserPage.quickLootPopup._movable == true and ns.Features.DungeonBrowserPage.quickLootPopup._clamped == true, "QuickLootPopup must be draggable & clamped")
    ns.Features.QuestTrackerView:ShowDetailCard({ questID = 5201, title = "테스트 퀘스트", level = 60, zone = "동부 역병지대", objectives = {} })
    assert(ns.Features.QuestTrackerView.detailCard._movable == true and ns.Features.QuestTrackerView.detailCard._clamped == true, "QuestDetailCard must be draggable & clamped")
    ns.Features.QuestTrackerView.detailCard:Hide()

    -- All 15 registered HUDs must be screen-clamped
    for id, rec in pairs(ns.UI.HudLayout.registry) do
        assert(rec.frame._clamped == true, "Registered HUD " .. tostring(id) .. " must enforce SetClampedToScreen(true)")
    end

    -- Unlock HUD Edit Mode, audit HudEditBar geometry (0 internal overlaps!), test overlap detection & 1-click ResolveOverlaps
    ns.UI.HudLayout:SetUnlocked(true)
    local editBar = ns.UI.HudLayout.controlBar
    assert(editBar and editBar:IsShown() and editBar._movable == true, "HudEditBar must be shown and draggable")
    AuditSubtree(editBar, "HudEditBar", 1920, 1080, allIssues)

    ns.UI.HudLayout:Select("statusPill")
    -- Intentionally collide statusPill onto clockHud (y=-238 -> nudge +30 => y=-208)
    ns.UI.HudLayout:Nudge("statusPill", 0, 30)
    local overlaps = ns.UI.HudLayout:FindOverlaps()
    assert(#overlaps >= 1, "HudLayout:FindOverlaps must detect intentional statusPill <-> clockHud collision")
    local moved, remaining = ns.UI.HudLayout:ResolveOverlaps()
    assert(moved >= 1 and remaining == 0, "HudLayout:ResolveOverlaps must separate colliding HUDs cleanly (rem=" .. tostring(remaining) .. ")")

    -- Per-HUD scale adjustment, read-only failure propagation, & individual reset
    local okSc, scVal = ns.UI.HudLayout:SetScale("statusPill", 1.20)
    assert(okSc and scVal == 1.20, "HudLayout:SetScale must clamp and persist 1.20")
    local prevRO = ns.Api.ProfileStore.readOnly
    ns.Api.ProfileStore.readOnly = true
    local roOk, roReason = ns.UI.HudLayout:SetScale("statusPill", 0.80)
    ns.Api.ProfileStore.readOnly = prevRO
    assert(roOk == false and roReason == "READ_ONLY", "HudLayout:SetScale must return false, READ_ONLY when ProfileStore is read-only")
    ns.UI.HudLayout:ResetOne("statusPill")
    local restored = ns.UI.HudLayout:GetEffectiveAnchor("statusPill")
    assert(restored.scale == 1.0 and restored.y == -240, "HudLayout:ResetOne must restore default anchor & 1.0 scale")
    ns.UI.HudLayout:SetUnlocked(false)
end

-- 3b. Explicit vertical clearance assertions for key high-density components (FontStrings & Textures)
do
    local Resolve = MakeResolver(1920, 1080)
    hub:SelectPage("bis")
    local rSlot = Resolve(ns.Features.BiSBrowserPage.slotPillGroup)
    local rSpec = Resolve(ns.Features.BiSBrowserPage.specPillBar)
    assert(rSlot and rSpec and rSlot.bottom >= rSpec.top + 4,
        "BiSBrowserPage slotPillGroup must have >=4px vertical clearance above specPillBar")

    hub:SelectPage("dungeons")
    ns.Features.DungeonBrowserPage.activeTab = "map"
    ns.Features.DungeonBrowserPage:RenderRight()
    local rMapPanel = Resolve(ns.Features.DungeonBrowserPage.mapPanel)
    local rMapTex = Resolve(ns.Features.DungeonBrowserPage.mapTex)
    assert(rMapPanel and rMapTex and rMapTex.bottom >= rMapPanel.bottom + 24,
        "DungeonBrowserPage mapTex must leave >=24px bottom clearance inside mapPanel for mapNoteLbl")

    hub:SelectPage("fonts")
    local rHost = Resolve(hub.contentHost)
    local rGlobalBar = Resolve(ns.Features.FontsPage.globalFontBar)
    assert(rHost and rGlobalBar and rGlobalBar.bottom >= rHost.bottom + 60,
        "FontsPage 18-font globalFontBar must leave >=60px below it for chat/damage sliders + statusLbl")
end

-- 4. Print full diagnostic report if any issues exist
if #allIssues > 0 then
    local lines = { "UI GEOMETRY AUDIT FOUND " .. tostring(#allIssues) .. " ISSUE(S):" }
    for idx, msg in ipairs(allIssues) do
        lines[#lines + 1] = string.format("  %2d. %s", idx, msg)
    end
    error(table.concat(lines, "\n"))
end

print("Test 19 PASS: 0 UI geometry/overlap/clipping/HUD-collision issues across all 12 pages + all sub-tabs + all HUDs!")

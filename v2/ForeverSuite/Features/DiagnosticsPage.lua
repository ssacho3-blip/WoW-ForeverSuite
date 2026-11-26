-- Module: Features/DiagnosticsPage.lua
-- Responsibility: ForeverSuite 4.0.0 Diagnostics, live Taint Canary count, 11 LoD pack manager,
--                 A7 Safe OOC Presets (CVar / ActionBar / EditMode / Shared Sync), and J6 Opt-In Lua Error Capture.
-- Layer: Features (zero raw CreateFrame / C_*; uses UI/Widgets + Api/SafeAPI).
local _, ns = ...
ns.Features = ns.Features or {}

local W = ns.UI.Widgets
local T = ns.UI.Tokens
local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local DiagnosticsPage = {
    id = "diagnostics",
    label = "진단 · 프리셋",
    host = nil,
    summaryLabel = nil,
    readinessLabel = nil,
    moduleRows = {},
    errorLog = {},
    errorHooked = false,
    prevErrorHandler = nil,
}
ns.Features.DiagnosticsPage = DiagnosticsPage

local LOD_DATA_ADDONS = {
    "ForeverSuite_Data",
    "ForeverSuite_Data_Dungeon",
    "ForeverSuite_Data_BiS",
    "ForeverSuite_Data_Profession",
    "ForeverSuite_Data_Reward",
    "ForeverSuite_Data_Pet",
    "ForeverSuite_Data_Atlas",
    "ForeverSuite_Data_MapPins",
    "ForeverSuite_Data_Items",
    "ForeverSuite_Data_QuestExtra",
    "ForeverSuite_Data_MapExtra",
    "ForeverSuite_Media_Assets",
}

local MODULE_STATUS_DEFS = {
    { label = "상점 자동 수리·판매 (Merchant)", toggles = { { "merchant", "autoRepair" }, { "merchant", "autoSellJunk" } } },
    { label = "퀘스트 추적기 · 수집알림 · 파티동기화 · 시체안내", toggles = { { "quest", "autoAccept" }, { "quest", "collectionAlerts" }, { "quest", "partyQuestSync" } } },
    { label = "편의 자동화 (QoL · 루팅/부활/전장/카메라)", toggles = { { "qol", "fastLoot" }, { "qol", "autoReleaseBG" }, { "qol", "autoAcceptRes" }, { "qol", "autoAcceptFriends" }, { "qol", "maxCameraZoom" } } },
    { label = "월드맵 핀·안개·히트맵 · 툴팁(커서/번역/출처)", toggles = { { "ui", "showWorldMapOverlay" }, { "ui", "showWorldMapPins" }, { "ui", "enhanceTooltips" } } },
    { label = "전투 HUD (콤보·사거리·단기버프·발동Proc·쿨다운·위협)", toggles = { { "combat", "showComboHud" }, { "combat", "showProcAlerts" }, { "combat", "showSkillCooldowns" } } },
    { label = "소셜 · 파티찾기알림 · 채팅버튼 · 12대 LoD 팩", toggles = { { "social", "chatKeywordAlerts" }, { "social", "partyWatchAlerts" }, { "profession", "showFishingCard" } } },
}

local function IsModuleEnabledInSettings(def)
    if not def.toggles then return true end
    for _, pair in ipairs(def.toggles) do
        if ns.Api.ProfileStore:Get(pair[1], pair[2]) == true then return true end
    end
    return false
end

-- J6: Opt-in bounded Lua error capture coexisting cleanly with BugSack (chains original handler)
function DiagnosticsPage:RecordCapturedError(msg)
    if ns.Api.SafeAPI.IsSecret(msg) then return end
    local text = tostring(msg or "")
    if #text > 400 then text = string.sub(text, 1, 400) end
    table.insert(self.errorLog, 1, {
        time = ns.Api.GameAdapters.GetEpochTimestamp(),
        msg = text,
    })
    if #self.errorLog > 30 then table.remove(self.errorLog) end
end

function DiagnosticsPage:InstallErrorCaptureIfEnabled()
    if self.errorHooked then return true end
    if ns.Api.ProfileStore:Get("qol", "captureLuaErrors") ~= true then return false end
    if type(_G.geterrorhandler) == "function" and type(_G.seterrorhandler) == "function" then
        local prev = _G.geterrorhandler()
        self.prevErrorHandler = prev
        self.errorHooked = true
        pcall(_G.seterrorhandler, function(err)
            DiagnosticsPage:RecordCapturedError(err)
            if type(prev) == "function" then
                return prev(err)
            end
        end)
        return true
    end
    return false
end

function DiagnosticsPage:ExportBugReportText()
    local ver = ns.Api.SafeAPI.GetAddonVersion()
    local lines = {
        "ForeverSuite " .. tostring(ver) .. " 진단 리포트",
        "렐름: " .. ns.Api.SafeAPI.GetCanonicalRealm(),
        "수집된 Lua 오류: " .. tostring(#self.errorLog) .. "건",
    }
    for i, e in ipairs(self.errorLog) do
        lines[#lines + 1] = tostring(i) .. ". " .. tostring(e.msg)
    end
    return table.concat(lines, "\n")
end

function DiagnosticsPage:Build(parent)
    self.host = parent
    local ver = ns.Api.SafeAPI.GetAddonVersion()
    local hdr = W.SectionHeader(parent, "ForeverSuite " .. ver .. " · Zero-Taint 진단 · 프리셋 · 오류 로그")
    hdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)

    local card = W.Card(parent, 640, 148)
    card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -30)
    card:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -30)

    local lbl = W.Label(card, "", "body", T.TEXT.PRIMARY)
    lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
    self.summaryLabel = lbl

    local ready = W.Label(card, "", "small", T.TEXT.SECONDARY)
    ready:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)
    self.readinessLabel = ready

    local resetBtn = W.Button(card, "HUD 위치 초기화", 132, 24, function()
        ns.UI.HudLayout:ResetAll()
        ns.Api.SafeAPI.Print("모든 HUD 위치를 4px 기본 그리드로 초기화했습니다.")
    end, true)
    resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -62)

    local loadBtn = W.Button(card, "전체 LoD 팩 로드", 136, 24, function()
        local loaded = 0
        for _, addonName in ipairs(LOD_DATA_ADDONS) do
            if ns.Api.SafeAPI.LoadDataPack(addonName) then
                loaded = loaded + 1
            end
        end
        ns.Api.SafeAPI.Print("도감·미디어 LoD 팩 " .. tostring(loaded) .. "/" .. tostring(#LOD_DATA_ADDONS) .. "개 로드 완료.")
        DiagnosticsPage:OnShow()
        ns.UI.CommandHub:RefreshStatusBar()
    end)
    loadBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)

    local xpResetBtn = W.Button(card, "세션 XP 초기화", 112, 24, function()
        if ns.Features.QoLModule then
            ns.Features.QoLModule:ResetSessionXP()
            ns.Api.SafeAPI.Print("세션 XP 통계를 초기화했습니다.")
        end
    end)
    xpResetBtn:SetPoint("LEFT", loadBtn, "RIGHT", 6, 0)

    local bugBtn = W.Button(card, "오류 리포트 복사", 122, 24, function()
        W.CopyPasteModal():OpenExport("ForeverSuite 오류 · 진단 리포트", "수집된 Lua 오류와 상태를 복사할 수 있습니다.", DiagnosticsPage:ExportBugReportText())
    end)
    bugBtn:SetPoint("LEFT", xpResetBtn, "RIGHT", 6, 0)

    -- A7: Safe OOC Preset buttons row
    local cvarBtn = W.Button(card, "권장 CVar 적용", 116, 24, function()
        if ns.Features.PresetManagerModule then ns.Features.PresetManagerModule:ApplyRecommendedGameCVars() end
    end)
    cvarBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -96)

    local barSaveBtn = W.Button(card, "단축바 저장", 92, 24, function()
        if ns.Features.PresetManagerModule then ns.Features.PresetManagerModule:SaveActionBarLoadout("default") end
    end)
    barSaveBtn:SetPoint("LEFT", cvarBtn, "RIGHT", 6, 0)

    local barLoadBtn = W.Button(card, "단축바 복원", 92, 24, function()
        if ns.Features.PresetManagerModule then ns.Features.PresetManagerModule:RestoreActionBarLoadout("default") end
    end)
    barLoadBtn:SetPoint("LEFT", barSaveBtn, "RIGHT", 6, 0)

    local editExportBtn = W.Button(card, "편집모드 백업", 96, 24, function()
        if ns.Features.PresetManagerModule then
            local str, st = ns.Features.PresetManagerModule:ExportEditModeLayout()
            if str then
                W.CopyPasteModal():OpenExport("편집 모드 레이아웃 내보내기", "현재 EditMode 레이아웃 문자열입니다.", str)
            else
                ns.Api.SafeAPI.Print("편집 모드 백업 불가: " .. tostring(st))
            end
        end
    end)
    editExportBtn:SetPoint("LEFT", barLoadBtn, "RIGHT", 6, 0)

    local editImportBtn = W.Button(card, "편집모드 복원", 96, 24, function()
        W.CopyPasteModal():OpenImport("편집 모드 레이아웃 가져오기", "EditMode 문자열을 붙여넣어 비전투 시 가져옵니다.", function(str)
            if ns.Features.PresetManagerModule then
                return ns.Features.PresetManagerModule:ImportEditModeLayout(str, "ForeverSuite")
            end
            return false
        end)
    end)
    editImportBtn:SetPoint("LEFT", editExportBtn, "RIGHT", 6, 0)

    local syncBtn = W.Button(card, "설정 동기화", 86, 24, function()
        if ns.Features.PresetManagerModule then
            local ok = ns.Features.PresetManagerModule:SyncSharedSettingsToChar()
            ns.Api.SafeAPI.Print(ok and "계정 공통 설정을 현재 캐릭터에 동기화했습니다." or "동기화 실패")
        end
    end)
    syncBtn:SetPoint("LEFT", editImportBtn, "RIGHT", 6, 0)

    local modHdr = W.SectionHeader(parent, "핵심 모듈 상태")
    modHdr:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -190)
    modHdr:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -190)

    self.moduleRows = {}
    local y = 218
    for i, def in ipairs(MODULE_STATUS_DEFS) do
        local row = W.ListRow(parent, 24)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -y)
        row._left:SetText(def.label)
        self.moduleRows[i] = { row = row, def = def }
        y = y + 26
    end

    self:OnShow()
end

function DiagnosticsPage:OnShow()
    if not self.summaryLabel then return end
    local db = ns.Api.ProfileStore.db
    local realm = ns.Api.SafeAPI.GetCanonicalRealm()
    local pending = ns.Secure.CombatQueue:PendingCount()
    local taintText
    if ns.Api.ProfileStore.readOnly then
        taintText = "읽기전용"
    elseif db and db.v2 and db.v2.diagnostics and type(db.v2.diagnostics.taintTotal) == "number" then
        taintText = tostring(db.v2.diagnostics.taintTotal) .. "건"
    else
        taintText = "집계 없음"
    end

    local ver = ns.Api.SafeAPI.GetAddonVersion()
    self.summaryLabel:SetText(
        "버전: " .. ver .. "  |  렐름: " .. realm ..
        "  |  Taint: " .. taintText ..
        "  |  전투큐: " .. tostring(pending) .. "건  |  오류캡처: " .. tostring(#self.errorLog) .. "건"
    )

    local packCount, entryCount = 0, 0
    if type(_G.ForeverSuiteData) == "table" and type(_G.ForeverSuiteData.packs) == "table" then
        for _, p in pairs(_G.ForeverSuiteData.packs) do
            if type(p) == "table" then
                packCount = packCount + 1
                if type(p.entries) == "table" then entryCount = entryCount + #p.entries end
            end
        end
    end
    local mediaInfo = type(_G.ForeverSuiteMediaAssets) == "table" and _G.ForeverSuiteMediaAssets.counts or nil
    local mediaTxt = (type(mediaInfo) == "table" and type(mediaInfo.total) == "number")
        and (" · 미디어 " .. tostring(mediaInfo.total) .. "종") or ""
    local dataText = (packCount > 0)
        and (tostring(packCount) .. "팩 / " .. tostring(entryCount) .. "항목 로드됨" .. mediaTxt)
        or ("미로드 (로그인 RAM 0MB)" .. mediaTxt)
    self.readinessLabel:SetText("독립 실행: Zero-Taint 6-Layer  |  도감·미디어 LoD: " .. dataText)

    for _, item in ipairs(self.moduleRows) do
        local active = IsModuleEnabledInSettings(item.def)
        item.row._right:SetText(active and "활성" or "비활성(설정 꺼짐)")
        local col = active and T.SEMANTIC.SUCCESS or T.TEXT.MUTED
        item.row._right:SetTextColor(col[1], col[2], col[3], 1)
    end
end

-- Test 10: M3 (ThreatMeter SecretProxy 5-return fuzz, CursorTrail 0% idle CPU, Talent/Training Advisor,
--          AutoGreeting burst/cooldown boundary, ChatTools Secret drop & URL pipe-escape, AltInventory C3, GDKP copper exactness)
--          + M4 (FontsPage SetFont verify & rollback, zero global STANDARD_TEXT_FONT mutation).
local ns = _G.ForeverSuiteV2

__FS_FIRE_EVENT("PLAYER_LOGIN")

-- 1. ThreatMeter: live sorting + aggro warning + SecretProxy on EVERY ONE of 5 UnitDetailedThreatSituation returns (Invariant I1)
_G.__FS_MOCK.inCombat = true
_G.__FS_MOCK.inGroup = true
_G.__FS_MOCK.groupMembers = 2
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "탱커" }
_G.__FS_MOCK.threatData = {
    player = { false, 2, 92, 92, 18400 },
    party1 = { true, 3, 100, 100, 20000 },
}
__FS_FIRE_EVENT("PLAYER_REGEN_DISABLED")
local tm = ns.Features.ThreatMeterHud
assert(tm.card:IsShown() == true and tm.lastSnapshot.mode == "LIVE")
assert(tm.lastSnapshot.rows[1].isTanking == true, "tank must sort first")
assert(tm.lastSnapshot.warning == true, "player >= 90% non-tank must trigger warning")

-- F4: Raid rank #7 player at 92% aggro STILL triggers playerWarning even though display caps at 6 rows!
local raidSamples = {}
for i = 1, 6 do
    raidSamples[i] = { unit = "raid" .. tostring(i), name = "딜러" .. tostring(i), isPlayer = false, isTanking = (i == 1), scaledPct = 100 - i, threatValue = 30000 - i * 1000 }
end
raidSamples[7] = { unit = "raid7", name = "영웅", isPlayer = true, isTanking = false, scaledPct = 92, threatValue = 20000 }
local raidSnap = ns.Domain.ThreatModel.BuildSnapshot(raidSamples, 6)
assert(raidSnap.mode == "LIVE" and #raidSnap.rows == 6 and raidSnap.warning == true, "Raid rank #7 player at 92% must still warn")

-- Fuzz all 5 return positions individually with SecretProxy -> ZERO errors, mode=SECRET_LOCKED, "집계 불가" (never 0%), ratio=nil
for pos = 1, 5 do
    local tuple = { false, 2, 80, 80, 12000 }
    tuple[pos] = FS_MakeSecret("threat_" .. tostring(pos), (pos == 1) and "boolean" or "number")
    _G.__FS_MOCK.threatData = { player = tuple }
    local snap = tm:Refresh()
    assert(snap.mode == "SECRET_LOCKED", "Secret at return #" .. tostring(pos) .. " must trigger SECRET_LOCKED")
    assert(snap.rows[1].rightText == "집계 불가" and snap.rows[1].ratio == nil, "Must show 집계 불가 with nil ratio, never 0%")
end

_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")
assert(tm.card:IsShown() == false and tm.ticker == nil, "ThreatMeter must stop ticker & hide OOC")

-- F4: Mid-combat /reload recovery via PLAYER_ENTERING_WORLD restores ThreatMeter & ticker
_G.__FS_MOCK.inCombat = true
_G.__FS_MOCK.threatData = { player = { true, 3, 100, 100, 5000 } }
__FS_FIRE_EVENT("PLAYER_ENTERING_WORLD")
assert(tm.card:IsShown() == true and tm.ticker ~= nil, "Mid-combat PLAYER_ENTERING_WORLD must revive ThreatMeter")
_G.__FS_MOCK.inCombat = false
__FS_FIRE_EVENT("PLAYER_REGEN_ENABLED")

-- 2. CursorTrailHud: OFF by default (OnUpdate nil = 0% CPU); ON attaches OnUpdate & never steals mouse
local ct = ns.Features.CursorTrailHud
assert(ct.ring:IsShown() == false and ct.ring._scripts["OnUpdate"] == nil)
assert(ct.ring._mouse == false, "Cursor ring must never intercept mouse clicks")
ns.Api.ProfileStore:Set("ui", "showCursorRing", true)
assert(ct.ring:IsShown() == true and type(ct.ring._scripts["OnUpdate"]) == "function")
ns.Api.ProfileStore:Set("ui", "showCursorRing", false)
assert(ct.ring:IsShown() == false and ct.ring._scripts["OnUpdate"] == nil)

-- 3. AutoGreeting: login/reload/raid suppression + exact cooldown boundary (now < expiresAt blocked, now == expiresAt allowed)
local ag = ns.Features.AutoGreetingModule
ns.Api.ProfileStore:Set("social", "autoGreetJoin", true)
ns.Api.ProfileStore:Set("social", "autoGreetWelcome", true)
_G.__FS_MOCK.inGroup = false
_G.__FS_MOCK.inRaid = false
_G.__FS_MOCK.sentChats = {}
ag:SyncInitialRoster()
assert(#_G.__FS_MOCK.sentChats == 0, "Initial sync must never spam")

-- Join a normal 5-man party OOC -> sends 1 greeting
_G.__FS_MOCK.now = 2000
_G.__FS_MOCK.inGroup = true
_G.__FS_MOCK.groupMembers = 2
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "동료" }
local okJ, stJ = ag:OnGroupRosterUpdate()
assert(okJ == true and #_G.__FS_MOCK.sentChats == 1)

-- Cooldown boundary test on pure model: now = expiresAt - 1 blocked; now == expiresAt allowed!
local cdState = { cooldowns = { ["welcome:민수"] = 2015 } }
local okBefore, rBefore = ns.Domain.AutoGreetingModel.CanSend("welcome", {
    enabled = true, inCombat = false, chatLockdown = false, rosterSynced = true, targetKey = "민수", now = 2014,
}, cdState)
assert(okBefore == false and rBefore == "COOLDOWN")
local okExact, rExact = ns.Domain.AutoGreetingModel.CanSend("welcome", {
    enabled = true, inCombat = false, chatLockdown = false, rosterSynced = true, targetKey = "민수", now = 2015,
}, cdState)
assert(okExact == true and rExact == "OK")

-- F3: Unresolved UNKNOWNOBJECT or transient Secret member MUST NOT welcome or overwrite knownMembers
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "알 수 없음" }
local okUnk, rUnk = ag:OnGroupRosterUpdate()
assert(okUnk == false and rUnk == "UNRESOLVED_OR_SECRET_MEMBER")
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = FS_MakeSecret("p1", "string") }
local okSecMem, rSecMem = ag:OnGroupRosterUpdate()
assert(okSecMem == false and rSecMem == "UNRESOLVED_OR_SECRET_MEMBER")
-- When party1 resolves back to existing known member "동료", NO duplicate welcome is sent!
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "동료" }
local okKnown, rKnown = ag:OnGroupRosterUpdate()
assert(okKnown == false and rKnown == "BURST_OR_NONE")

-- F3: SyncInitialRoster with unresolved party1 MUST stay un-synced, then establish baseline on resolve WITHOUT welcoming!
_G.__FS_MOCK.inGroup = true
_G.__FS_MOCK.groupMembers = 2
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "알 수 없음" }
local syncedBad = ag:SyncInitialRoster()
assert(syncedBad == false and ag.state.rosterSynced == false)
local chatsBeforeResolve = #_G.__FS_MOCK.sentChats
_G.__FS_MOCK.unitNames = { player = "영웅", party1 = "기존동료" }
local okBase, rBase = ag:OnGroupRosterUpdate()
assert(okBase == false and rBase == "INITIAL_SYNC" and ag.state.rosterSynced == true)
assert(#_G.__FS_MOCK.sentChats == chatsBeforeResolve, "Resolving initial baseline must NEVER welcome existing party member")

-- F5: UNIT_AURA runtime consumer: unreadable/secret scan must NOT prime or wipe seenAuras -> zero false /thank!
ns.Api.ProfileStore:Set("social", "autoThankBuff", true)
ag.state.aurasPrimed = false
ag.state.seenAuras = {}
_G.__FS_MOCK.sentEmotes = {}
_G.__FS_MOCK.auraListSecret = true
__FS_FIRE_EVENT("UNIT_AURA", "player")
assert(ag.state.aurasPrimed == false, "Unreadable first scan must NOT prime auras")
_G.__FS_MOCK.auraListSecret = false
_G.__FS_MOCK.auraList = { { spellId = 21562, name = "신의 권능: 인내", sourceUnit = "party1" } }
__FS_FIRE_EVENT("UNIT_AURA", "player")
assert(ag.state.aurasPrimed == true and #_G.__FS_MOCK.sentEmotes == 0, "First clean scan primes baseline without emote")
-- Secret aura during combat must NOT erase seenAuras[21562]
_G.__FS_MOCK.auraList = { { spellId = FS_MakeSecret("sid", "number"), name = "비밀", sourceUnit = "party1" } }
__FS_FIRE_EVENT("UNIT_AURA", "player")
assert(ag.state.seenAuras[21562] == true, "Secret aura must preserve prior seenAuras")
-- Returning to normal buff 21562 does NOT re-trigger /thank!
_G.__FS_MOCK.auraList = { { spellId = 21562, name = "신의 권능: 인내", sourceUnit = "party1" } }
__FS_FIRE_EVENT("UNIT_AURA", "player")
assert(#_G.__FS_MOCK.sentEmotes == 0, "Pre-existing buff must not trigger duplicate /thank")

-- Buff thank defaults OFF check & secret caster Fail-Closed
ns.Api.ProfileStore:Set("social", "autoThankBuff", false)
local okBuffOff, rBuffOff = ag:OnExternalBuffReceived("사제", "신의 권능: 인내")
assert(okBuffOff == false and rBuffOff == "DISABLED")
ns.Api.ProfileStore:Set("social", "autoThankBuff", true)
local okBuffSec, rBuffSec = ag:OnExternalBuffReceived(FS_MakeSecret("caster", "string"), "인내")
assert(okBuffSec == false and rBuffSec == "SECRET")

-- 4. ChatTools: Secret message dropped (zero storage/alert), ring buffer capped, URL & pipe-escape sanitized
local chat = ns.Features.ChatToolsModule
chat:SetKeywords("죽폐,통곡")
local okSecMsg, rSecMsg = chat:OnChatEvent("CHAT_MSG_SAY", FS_MakeSecret("secret_msg", "string"), "누군가")
assert(okSecMsg == false and rSecMsg == "SECRET" and #chat.history == 0)

local okNormal, matchedKw = chat:OnChatEvent("CHAT_MSG_CHANNEL", "죽폐 탱 구함 |Hitem:1|h https://wowf.io/guide", "파티장")
assert(okNormal == true and matchedKw == "죽폐" and chat.alertsTriggered == 1)
assert(string.find(chat.history[1].text, "||Hitem", 1, true), "Pipe characters must be escaped")
assert(chat.history[1].urls[1] == "https://wowf.io/guide")

-- Ring buffer cap at 100
for i = 1, 120 do
    ns.Domain.ChatToolsModel.AppendHistory(chat.history, { channel = "일반", sender = "유저", text = "msg " .. tostring(i) }, 100)
end
assert(#chat.history == 100, "Chat ring buffer must cap at 100 entries")

-- 5. GDKP: exact integer copper conservation & invalid input rejections
local sales = {}
assert(ns.Domain.GdkpModel.AddSale(sales, "용의 송곳니", "전사", 1000001) == true)
assert(ns.Domain.GdkpModel.AddSale(sales, "잘못된소수", "전사", 12.5) == false)
assert(ns.Domain.GdkpModel.AddSale(sales, "음수", "전사", -100) == false)
local split, sOk = ns.Domain.GdkpModel.ComputeSplit(sales, 7, 10)
assert(sOk == "OK" and split.balanced == true)
assert(split.organizerCut + split.perMember * split.memberCount + split.remainder == split.totalPot)
local bad0, b0Err = ns.Domain.GdkpModel.ComputeSplit(sales, 0, 0)
assert(bad0 == nil and b0Err == "INVALID_MEMBERS")

-- F6: Multi-word GDKP item name succeeds; fractional members/cut rejected
assert(ns.Features.UtilitiesPage:HandleGdkpCommand("add 용암 망토 홍길동 500") == true)
assert(ns.Features.UtilitiesPage:HandleGdkpCommand("members 10.5") == false)
assert(ns.Features.UtilitiesPage:HandleGdkpCommand("cut 2.7") == false)

-- F7: Keyword alert toast auto-hides when timer flushes
__FS_FLUSH_AFTER_TIMERS()

-- 6. AltInventory (F2: nil money must preserve prior recorded gold instead of overwriting with 0) & Talent Reminder
_G.__FS_MOCK.unspentTalents = 3
local rem = ns.Features.CharacterAssistModule:CheckTalents(true)
assert(rem ~= nil and rem.points == 3)
assert(ns.Features.UtilitiesPage:RecordCurrentCharacter() == true)
local prevMoney = _G.__FS_MOCK.money
_G.__FS_MOCK.money = nil
assert(ns.Features.UtilitiesPage:RecordCurrentCharacter() == true)
_G.__FS_MOCK.money = prevMoney
local altSum = ns.Domain.AltInventoryModel.Summarize(ns.Api.ProfileStore:GetState("altLedger"), "")
assert(altSum.charCount >= 1 and altSum.totalGold == prevMoney, "Nil money must preserve prior gold, never overwrite with 0")

-- 7. M4 FontsPage (F1: atomic 5/5 rollback, nil GetFont rejected, missing Media objects rejected, ZERO global writes)
assert(_G.STANDARD_TEXT_FONT == nil and _G.UNIT_NAME_FONT == nil, "Must never pollute Blizzard global font variables")
ns.Api.ProfileStore:Set("ui", "fontPreset", "bold_kr")
local okFont, stFont = ns.Features.FontsPage:ApplySavedFonts()
assert(okFont == true and stFont == "APPLIED")
assert(_G.FS_Font_Body:GetFont() == "Fonts\\2002B.TTF")

-- Partial/full SetFont failure must roll back ALL 5 fonts cleanly
_G.__FS_MOCK.fontSetShouldFail["Fonts\\K_Pagetext.TTF"] = true
ns.Api.ProfileStore:Set("ui", "fontPreset", "pagetext_kr")
local okFail, stFail = ns.Features.FontsPage:ApplySavedFonts()
assert(okFail == false and stFail == "ROLLED_BACK")
assert(_G.FS_Font_Body:GetFont() == "Fonts\\2002B.TTF", "Failed SetFont must preserve previous font")
assert(_G.FS_Font_Mono:GetFont() == "Fonts\\2002B.TTF", "All 5 fonts must roll back atomically")

-- Missing Media font object must return false, NO_FONT_OBJECTS (never fake APPLIED)
local savedSmall = _G.FS_Font_Small
_G.FS_Font_Small = nil
local okMissing, stMissing = ns.Features.FontsPage:ApplySavedFonts()
_G.FS_Font_Small = savedSmall
assert(okMissing == false and stMissing == "NO_FONT_OBJECTS")
assert(_G.STANDARD_TEXT_FONT == nil and _G.UNIT_NAME_FONT == nil)

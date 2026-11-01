local _, ns = ...

local type = type
local string_format = string.format

local Economy = {
    title = "경매장 공존 및 골드 원장 (Economy)",
    priority = "P2",
    description = "Auctionator 공존, PLAYER_MONEY 델타 정합성 검증 세션 골드 수지 원장",
    yieldTo = { "Auctionator" },
    initializedBaseline = false,
    secretGap = false,
    settingObserverBound = false,
    baselineMoney = 0,
    lastMoney = 0,
    ledger = {
        vendorSell = 0,
        repair = 0,
        quest = 0,
        other = 0,
    },
}

function Economy:SyncCursorToCurrentMoney()
    if not _G.GetMoney then
        return false
    end
    local current = _G.GetMoney()
    if type(current) == "number" and not ns.IsSecret(current) then
        self.lastMoney = current
        self.secretGap = false
        return true
    end
    self.secretGap = true
    return false
end

function Economy:ResetSessionBaseline()
    local current = (_G.GetMoney and _G.GetMoney()) or 0
    if type(current) ~= "number" or ns.IsSecret(current) then
        current = 0
        self.secretGap = true
    else
        self.secretGap = false
    end
    self.baselineMoney = current
    self.lastMoney = current
    self.ledger.vendorSell = 0
    self.ledger.repair = 0
    self.ledger.quest = 0
    self.ledger.other = 0
    self.initializedBaseline = true
end

function Economy:OnInitialize()
    if not self.settingObserverBound and ns.ProfileManager and ns.ProfileManager.OnSettingChanged then
        self.settingObserverBound = true
        ns.ProfileManager:OnSettingChanged(function(section, key, value)
            if section == "economy" and key == "trackSessionGold" and value then
                Economy:SyncCursorToCurrentMoney()
            end
        end)
    end
end

function Economy:OnPlayerMoney()
    if not ns.ProfileManager:Get("economy", "trackSessionGold") then
        return
    end
    if not _G.GetMoney then
        return
    end
    local current = _G.GetMoney()
    if type(current) ~= "number" or ns.IsSecret(current) then
        self.secretGap = true
        return
    end
    if not self.initializedBaseline then
        self:ResetSessionBaseline()
        return
    end
    if self.secretGap then
        self.lastMoney = current
        self.secretGap = false
        return
    end

    local delta = current - self.lastMoney
    self.lastMoney = current
    if delta == 0 then
        return
    end

    local reason = ns.ConsumePendingMoneyReason(delta)

    if reason == "VENDOR_SELL" and delta > 0 then
        self.ledger.vendorSell = self.ledger.vendorSell + delta
    elseif reason == "REPAIR" and delta < 0 then
        self.ledger.repair = self.ledger.repair + delta
    elseif reason == "QUEST" and delta > 0 then
        self.ledger.quest = self.ledger.quest + delta
    else
        -- Unclassified changes are strictly recorded as 'other' to preserve exact delta invariant (AC-6)
        self.ledger.other = self.ledger.other + delta
    end
end

function Economy:GetNetDelta()
    return self.ledger.vendorSell + self.ledger.repair + self.ledger.quest + self.ledger.other
end

function Economy:PrintLedgerSummary()
    local net = self:GetNetDelta()
    ns.Print(string_format(
        "세션 골드 원장 — 순증감: %s (상점판매: %s | 수리: %s | 퀘스트: %s | 기타: %s)",
        ns.FormatMoney(net),
        ns.FormatMoney(self.ledger.vendorSell),
        ns.FormatMoney(self.ledger.repair),
        ns.FormatMoney(self.ledger.quest),
        ns.FormatMoney(self.ledger.other)
    ))
end

function Economy:OnEnable(ctx)
    if not self.initializedBaseline then
        self:ResetSessionBaseline()
    else
        self:SyncCursorToCurrentMoney()
    end
    ctx:RegisterEvent("PLAYER_MONEY", Economy.OnPlayerMoney)
    ctx:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not Economy.initializedBaseline then
            Economy:ResetSessionBaseline()
        end
    end)
end

ns.ModuleManager:Register("Economy", Economy)

-- Module: Domain/LedgerModel.lua
-- Responsibility: Pure gold ledger computation and tabular currency formatting.
-- Layer: Domain (100% pure Lua 5.1; zero WoW API, zero _G).
local _, ns = ...
ns.Domain = ns.Domain or {}

local type = type
local math_floor = math.floor
local math_abs = math.abs
local string_format = string.format

local LedgerModel = {}
ns.Domain.LedgerModel = LedgerModel

function LedgerModel.FormatCopper(copper)
    if type(copper) ~= "number" then
        return "—"
    end
    local sign = copper < 0 and "-" or ""
    local absVal = math_floor(math_abs(copper) + 0.5)
    local g = math_floor(absVal / 10000)
    local s = math_floor((absVal % 10000) / 100)
    local c = absVal % 100
    if g > 0 then
        return string_format("%s%dg %02ds %02dc", sign, g, s, c)
    elseif s > 0 then
        return string_format("%s%ds %02dc", sign, s, c)
    end
    return string_format("%s%dc", sign, c)
end

function LedgerModel.Summarize(entries)
    local income = 0
    local expense = 0
    local count = 0
    for i = 1, #(entries or {}) do
        local e = entries[i]
        if type(e) == "table" and type(e.delta) == "number" then
            count = count + 1
            if e.delta >= 0 then
                income = income + e.delta
            else
                expense = expense + math_abs(e.delta)
            end
        end
    end
    return {
        count = count,
        income = income,
        expense = expense,
        net = income - expense,
    }
end

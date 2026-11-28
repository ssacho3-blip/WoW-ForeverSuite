-- Module: UI/VirtualList.lua
-- Responsibility: ForeverSuite v6.1.0 Unified Virtual List Adapter (Wave 3):
--                 Uses WoW Forever 1.60.1 native ScrollBox (CreateScrollBoxListLinearView +
--                 ScrollUtil.InitScrollBoxListWithScrollBar) when available, with automatic
--                 zero-taint fixed-pool fallback (<= visible+2 frames for 1,000+ rows),
--                 row-level OnMouseWheel forwarding, non-mutating index wrappers, and
--                 strict element recycle hygiene (clears & refreshes hovered tooltips/callbacks).
-- Layer: UI (L3; depends on UI/Widgets & injected/global ScrollBox port).
local _, ns = ...
ns.UI = ns.UI or {}

local W = ns.UI.Widgets
local math_max = math.max
local math_min = math.min
local math_floor = math.floor
local type = type
local pcall = pcall

local VirtualList = {}
ns.UI.VirtualList = VirtualList

local function HideTooltipIfOwned(row)
    local tt = _G.GameTooltip
    if not (row and tt and type(tt.Hide) == "function") then return end
    if type(tt.IsOwned) == "function" then
        local ok, owned = pcall(tt.IsOwned, tt, row)
        if ok and owned then
            pcall(tt.Hide, tt)
        end
    elseif tt._owner == row then
        pcall(tt.Hide, tt)
    end
end

local function RefreshTooltipIfHovered(row)
    if not row then return end
    if type(row.IsMouseOver) == "function" then
        local ok, over = pcall(row.IsMouseOver, row)
        if ok and over then
            HideTooltipIfOwned(row)
            if type(row._onTooltipEnter) == "function" then
                pcall(row._onTooltipEnter, row)
            end
        end
    end
end

local function DefaultResetRow(row)
    if not row then return end
    HideTooltipIfOwned(row)
    row._payload = nil
    row._rec = nil
    row._entry = nil
    row._boundId = nil
    row._onTooltipEnter = nil
    row._onTooltipLeave = nil
    if type(row.SetScript) == "function" then
        row:SetScript("OnClick", nil)
    end
end

local function ResolveNativePort(opts)
    if type(opts.nativePort) == "table" then
        return opts.nativePort
    end
    if type(_G.CreateScrollBoxListLinearView) == "function"
        and type(_G.CreateDataProvider) == "function"
        and type(_G.ScrollUtil) == "table"
        and type(_G.ScrollUtil.InitScrollBoxListWithScrollBar) == "function"
    then
        return {
            CreateScrollBoxListLinearView = _G.CreateScrollBoxListLinearView,
            CreateDataProvider = _G.CreateDataProvider,
            InitScrollBoxListWithScrollBar = _G.ScrollUtil.InitScrollBoxListWithScrollBar,
        }
    end
    return nil
end

function VirtualList.Create(parent, opts)
    opts = type(opts) == "table" and opts or {}
    local rowHeight = opts.rowHeight or 32
    local rowGap = opts.rowGap or 2
    local stepH = rowHeight + rowGap
    local visibleCount = opts.visibleCount or 12
    local createRow = opts.createRow
    local bindRow = opts.bindRow
    local userResetRow = opts.resetRow

    local function CleanReset(row)
        HideTooltipIfOwned(row)
        if type(userResetRow) == "function" then
            userResetRow(row)
        else
            DefaultResetRow(row)
        end
    end

    local port = ResolveNativePort(opts)
    local backend = (port ~= nil) and "native" or "pool"

    local listObj = {
        parent = parent,
        _backend = backend,
        _data = {},
        _offset = 0,
        _visibleCount = visibleCount,
        _rowHeight = rowHeight,
        _stepH = stepH,
        _rows = {},
        _scrollBar = nil,
        _scrollBox = nil,
        _onScroll = opts.onScroll,
    }

    local function HandleWheelDelta(delta)
        if not delta or delta == 0 then return end
        listObj:SetScrollOffset(listObj._offset + (delta > 0 and -3 or 3))
    end

    if backend == "native" then
        local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
        box:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.padLeft or 4, -(opts.padTop or 6))
        box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(opts.padRight or 14), opts.padBottom or 6)

        local sb = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
        sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -3, -(opts.padTop or 6))
        sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -3, opts.padBottom or 6)

        local view = port.CreateScrollBoxListLinearView()
        if type(view.SetElementExtent) == "function" then
            pcall(view.SetElementExtent, view, rowHeight)
        end
        if type(view.SetPadding) == "function" then
            pcall(view.SetPadding, view, 0, 0, 0, 0, rowGap)
        end
        view:SetElementInitializer("Frame", function(row, wrapped)
            if type(wrapped) ~= "table" or type(wrapped.__fsVlIndex) ~= "number" then
                error("VirtualList native initializer requires wrapped { item, __fsVlIndex } element")
            end
            if not row._fsVlInitialized then
                row._fsVlInitialized = true
                if type(createRow) == "function" then
                    local inner = createRow(row)
                    if inner and inner ~= row then
                        inner:SetAllPoints(row)
                        row._fsInner = inner
                    end
                end
            end
            local target = row._fsInner or row
            CleanReset(target)
            if type(bindRow) == "function" then
                bindRow(target, wrapped.item, wrapped.__fsVlIndex)
            end
            RefreshTooltipIfHovered(target)
        end)
        port.InitScrollBoxListWithScrollBar(box, sb, view)
        listObj._scrollBox = box
        listObj._scrollBar = sb
        listObj._nativePort = port
    else
        -- Zero-Taint fixed pool (<= visibleCount frames total) with row-level OnMouseWheel forwarding
        for i = 1, visibleCount do
            local row = createRow(parent)
            local y = (opts.padTop or 6) + (i - 1) * stepH
            row:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.padLeft or 4, -y)
            row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(opts.padRight or 14), -y)
            if opts.hookWheel ~= false and not row._fsVlWheelHooked then
                row._fsVlWheelHooked = true
                if type(row.EnableMouseWheel) == "function" then
                    row:EnableMouseWheel(true)
                end
                if type(row.HookScript) == "function" then
                    pcall(row.HookScript, row, "OnMouseWheel", function(_, delta)
                        HandleWheelDelta(delta)
                    end)
                end
            end
            row:Hide()
            listObj._rows[i] = row
        end
        if W and type(W.ScrollBar) == "function" and opts.noScrollBar ~= true then
            local sb = W.ScrollBar(parent, visibleCount * stepH, function(newOff)
                listObj:SetScrollOffset(newOff)
            end)
            sb:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -3, -(opts.padTop or 6))
            sb:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -3, opts.padBottom or 6)
            listObj._scrollBar = sb
        end
        if type(parent.EnableMouseWheel) == "function" and opts.hookWheel ~= false then
            parent:EnableMouseWheel(true)
            parent:SetScript("OnMouseWheel", function(_, delta)
                HandleWheelDelta(delta)
            end)
        end
    end

    function listObj:GetBackend()
        return self._backend
    end

    function listObj:GetVisibleRow(idx)
        return self._rows[idx]
    end

    function listObj:GetScrollOffset()
        return self._offset
    end

    function listObj:Refresh()
        local total = #self._data
        if self._backend == "native" and self._scrollBox and self._nativePort then
            local wrappedList = {}
            for i = 1, total do
                wrappedList[i] = { item = self._data[i], __fsVlIndex = i }
            end
            local dp = self._nativePort.CreateDataProvider(wrappedList)
            if type(self._scrollBox.SetDataProvider) == "function" then
                local okSet, errSet = pcall(self._scrollBox.SetDataProvider, self._scrollBox, dp)
                if not okSet then
                    return 0, tostring(errSet)
                end
            else
                return 0, "NO_SET_DATA_PROVIDER"
            end
            return total
        end
        local maxOff = math_max(0, total - self._visibleCount)
        self._offset = math_max(0, math_min(maxOff, math_floor(self._offset or 0)))
        for i = 1, self._visibleCount do
            local row = self._rows[i]
            local idx = self._offset + i
            local item = self._data[idx]
            CleanReset(row)
            if item ~= nil then
                bindRow(row, item, idx)
                row:Show()
                RefreshTooltipIfHovered(row)
            else
                row:Hide()
            end
        end
        if self._scrollBar and type(self._scrollBar.SetMetrics) == "function" then
            self._scrollBar:SetMetrics(self._offset, self._visibleCount, total)
        end
        return total
    end

    function listObj:SetData(items, setOpts)
        self._data = type(items) == "table" and items or {}
        if type(setOpts) == "table" and type(setOpts.offset) == "number" then
            self._offset = math_max(0, math_floor(setOpts.offset))
        end
        local maxOff = math_max(0, #self._data - self._visibleCount)
        if self._offset > maxOff then
            self._offset = maxOff
        end
        return self:Refresh()
    end

    function listObj:SetScrollOffset(off, silent)
        local total = #self._data
        local maxOff = math_max(0, total - self._visibleCount)
        local clamped = math_max(0, math_min(maxOff, math_floor(tonumber(off) or 0)))
        self._offset = clamped
        self:Refresh()
        if (not silent) and type(self._onScroll) == "function" then
            self._onScroll(clamped)
        end
        return clamped
    end

    return listObj
end

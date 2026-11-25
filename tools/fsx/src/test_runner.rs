use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use mlua::{Lua, MetaMethod, UserData, UserDataMethods, Value};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct TestSummary {
    pub total: usize,
    pub passed: usize,
}

/// C_Secrets proxy userdata: preserves underlying Lua type via overridden `type()`
/// and raises an error on arithmetic/relational/same-type equality/concat/len/tostring ops.
#[derive(Clone, Debug)]
struct SecretProxy {
    tag: String,
    underlying_type: String,
}

impl UserData for SecretProxy {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        macro_rules! deny_binop {
            ($mm:expr, $op:literal) => {
                methods.add_meta_method($mm, |_, this: &SecretProxy, _: Value| -> mlua::Result<Value> {
                    Err(mlua::Error::RuntimeError(format!(
                        "C_Secrets violation: illegal '{}' on secret value '{}'",
                        $op, this.tag
                    )))
                });
            };
        }
        deny_binop!(MetaMethod::Add, "add");
        deny_binop!(MetaMethod::Sub, "sub");
        deny_binop!(MetaMethod::Mul, "mul");
        deny_binop!(MetaMethod::Div, "div");
        deny_binop!(MetaMethod::Mod, "mod");
        deny_binop!(MetaMethod::Pow, "pow");
        deny_binop!(MetaMethod::Lt, "lt");
        deny_binop!(MetaMethod::Le, "le");
        deny_binop!(MetaMethod::Concat, "concat");
        methods.add_meta_method(MetaMethod::Unm, |_, this: &SecretProxy, ()| -> mlua::Result<Value> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'unm' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::Len, |_, this: &SecretProxy, ()| -> mlua::Result<usize> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'len' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::Eq, |_, this: &SecretProxy, _: Value| -> mlua::Result<bool> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'eq' on secret value '{}'",
                this.tag
            )))
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this: &SecretProxy, ()| -> mlua::Result<String> {
            Err(mlua::Error::RuntimeError(format!(
                "C_Secrets violation: illegal 'tostring' on secret value '{}'",
                this.tag
            )))
        });
    }
}

fn lua_err<T>(res: mlua::Result<T>) -> Result<T> {
    res.map_err(|e| anyhow::anyhow!("{e}"))
}

const WOW_MOCK_PRELUDE: &str = r#"
_G.__FS_ASSERT_COUNT = 0
local _raw_assert = assert
function assert(cond, msg)
    _G.__FS_ASSERT_COUNT = _G.__FS_ASSERT_COUNT + 1
    return _raw_assert(cond, msg)
end

local _raw_type = type
function type(v)
    local st = __FS_SECRET_TYPE(v)
    if st then return st end
    return _raw_type(v)
end

_G.__FS_MOCK = {
    inCombat = false,
    realm = "",
    realmFallback = "ForeverKR",
    worldMapShown = false,
    superTrackedQuestID = 0,
    userWaypoint = nil,
    loadedAddOns = {},
    frames = {},
    printed = {},
    events = {},
    now = 1000,
    money = 50000,
    bagFreeSlots = 12,
    questEntries = {},
    questComplete = {},
    questSpecialItems = {},
    errorsForwarded = {},
    objTrackerTouches = 0,
}

function geterrorhandler()
    return function(err)
        table.insert(_G.__FS_MOCK.errorsForwarded, tostring(err))
    end
end

function GetQuestLogSpecialItemInfo(idx)
    local item = (_G.__FS_MOCK.questSpecialItems or {})[idx]
    if item then return item[1], item[2] end
    return nil, nil
end

function GetMoney()
    return _G.__FS_MOCK.money
end

function InCombatLockdown()
    return _G.__FS_MOCK.inCombat
end

function GetNormalizedRealmName()
    return _G.__FS_MOCK.realm
end

function GetRealmName()
    return _G.__FS_MOCK.realmFallback
end

function GetTime()
    return _G.__FS_MOCK.now
end

function time()
    return _G.__FS_MOCK.now
end

function GetBuildInfo()
    return "1.60.1", "71037", "Nov 2026", 16001
end

DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, msg)
        table.insert(_G.__FS_MOCK.printed, tostring(msg))
    end,
}

SlashCmdList = {}

local function MakeMockRegion(kind, parent)
    local r = {
        _kind = kind,
        _parent = parent,
        _shown = true,
        _alpha = 1.0,
        _text = "",
        _points = {},
        _color = nil,
        _width = 0,
        _height = 0,
    }
    function r:SetAllPoints(target) self._allPoints = target or self._parent end
    function r:ClearAllPoints() self._points = {} end
    function r:SetPoint(...) table.insert(self._points, { ... }) end
    function r:GetPoint(idx)
        local p = self._points[idx or 1]
        if p then return p[1], p[2], p[3], p[4], p[5] end
        return "CENTER", UIParent, "CENTER", 0, 0
    end
    function r:SetSize(w, h) self._width = w; self._height = h end
    function r:SetWidth(w) self._width = w end
    function r:SetHeight(h) self._height = h end
    function r:GetWidth() return self._width end
    function r:GetHeight() return self._height end
    function r:SetColorTexture(r1, g1, b1, a1) self._color = { r1, g1, b1, a1 } end
    function r:SetTexture(path) self._texture = path end
    function r:SetTexCoord(...) self._texCoord = { ... } end
    function r:SetText(t) self._text = tostring(t or "") end
    function r:GetText() return self._text end
    function r:SetTextColor(r1, g1, b1, a1) self._textColor = { r1, g1, b1, a1 } end
    function r:SetJustifyH(j) self._justifyH = j end
    function r:SetJustifyV(j) self._justifyV = j end
    function r:SetWordWrap(w) self._wordWrap = w end
    function r:SetFontObject(f) self._fontObject = f end
    function r:Show() self._shown = true end
    function r:Hide() self._shown = false end
    function r:IsShown() return self._shown end
    function r:SetAlpha(a) self._alpha = a end
    function r:GetAlpha() return self._alpha end
    return r
end

local function MakeMockFrame(frameType, name, parent, template)
    local f = MakeMockRegion(frameType or "Frame", parent)
    f._name = name
    f._template = template
    f._scripts = {}
    f._hooks = {}
    f._events = {}
    f._attrs = {}
    f._clicks = {}
    f._strata = "MEDIUM"
    f._level = 1
    f._scale = 1.0
    f._movable = false
    f._mouse = true
    function f:GetObjectType() return self._kind end
    function f:GetName() return self._name end
    function f:GetParent() return self._parent end
    function f:SetFrameStrata(s) self._strata = s end
    function f:SetFrameLevel(l) self._level = l end
    function f:GetEffectiveScale() return self._scale end
    function f:SetClampedToScreen(v) self._clamped = v end
    function f:SetMovable(v) self._movable = v end
    function f:EnableMouse(v) self._mouse = v end
    function f:RegisterForDrag(...) self._dragButtons = { ... } end
    function f:StartMoving() self._moving = true end
    function f:StopMovingOrSizing() self._moving = false end
    function f:RegisterForClicks(...) self._clicks = { ... } end
    function f:SetAttribute(k, v)
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: SetAttribute in combat")
        end
        self._attrs[k] = v
    end
    function f:GetAttribute(k) return self._attrs[k] end
    function f:RegisterEvent(ev)
        self._events[ev] = true
        _G.__FS_MOCK.events[ev] = _G.__FS_MOCK.events[ev] or {}
        table.insert(_G.__FS_MOCK.events[ev], self)
    end
    function f:UnregisterEvent(ev) self._events[ev] = nil end
    function f:SetScript(ev, fn) self._scripts[ev] = fn end
    function f:HookScript(ev, fn)
        self._hooks[ev] = self._hooks[ev] or {}
        table.insert(self._hooks[ev], fn)
    end
    function f:FireScript(ev, ...)
        if self._scripts[ev] then self._scripts[ev](self, ...) end
        if self._hooks[ev] then
            for _, h in ipairs(self._hooks[ev]) do h(self, ...) end
        end
    end
    function f:CreateTexture(_, layer)
        local t = MakeMockRegion("Texture", self)
        t._layer = layer
        return t
    end
    function f:CreateFontString(_, layer, fontObj)
        local fs = MakeMockRegion("FontString", self)
        fs._layer = layer
        fs._fontObject = fontObj
        return fs
    end
    function f:SetAutoFocus(v) self._autoFocus = v end
    function f:SetTextInsets(...) self._insets = { ... } end
    function f:ClearFocus() self._focused = false end
    function f:SetMinMaxValues(a, b) self._min, self._max = a, b end
    function f:SetValueStep(s) self._step = s end
    function f:SetObeyStepOnDrag(v) self._obeyStep = v end
    function f:SetValue(v) self._value = v end
    function f:GetValue() return self._value or 0 end
    function f:SetOrientation(o) self._orientation = o end
    function f:Show()
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: Show secure frame in combat")
        end
        self._shown = true
        self:FireScript("OnShow")
    end
    function f:Hide()
        if _G.__FS_MOCK.inCombat and self._template and string.find(self._template, "Secure") then
            error("ADDON_ACTION_BLOCKED: Hide secure frame in combat")
        end
        self._shown = false
        self:FireScript("OnHide")
    end
    if name then _G[name] = f end
    table.insert(_G.__FS_MOCK.frames, f)
    return f
end

function CreateFrame(frameType, name, parent, template)
    return MakeMockFrame(frameType, name, parent, template)
end

UIParent = MakeMockFrame("Frame", "UIParent", nil, nil)
UIParent:SetSize(1920, 1080)
UISpecialFrames = {}

ObjectiveTrackerFrame = MakeMockFrame("Frame", "ObjectiveTrackerFrame", UIParent, nil)
local _origObjShow = ObjectiveTrackerFrame.Show
local _origObjAlpha = ObjectiveTrackerFrame.SetAlpha
ObjectiveTrackerFrame.Show = function(self)
    _G.__FS_MOCK.objTrackerTouches = _G.__FS_MOCK.objTrackerTouches + 1
    return _origObjShow(self)
end
ObjectiveTrackerFrame.SetAlpha = function(self, a)
    _G.__FS_MOCK.objTrackerTouches = _G.__FS_MOCK.objTrackerTouches + 1
    return _origObjAlpha(self, a)
end

WorldMapFrame = MakeMockFrame("Frame", "WorldMapFrame", UIParent, nil)
WorldMapFrame:Hide()
WorldMapFrame.IsShown = function() return _G.__FS_MOCK.worldMapShown end

function CreateFont(name)
    local f = { _name = name }
    function f:SetFont(path, size, flags) self._path, self._size, self._flags = path, size, flags end
    _G[name] = f
    return f
end

C_AddOns = {
    GetAddOnMetadata = function(_, field)
        if field == "Version" then return "2.0.0-alpha.1" end
        if field == "Interface" then return "16001, 120105" end
        return nil
    end,
    IsAddOnLoaded = function(name) return _G.__FS_MOCK.loadedAddOns[name] == true end,
    LoadAddOn = function(name)
        _G.__FS_MOCK.loadedAddOns[name] = true
        return true, nil
    end,
}

C_SuperTrack = {
    GetSuperTrackedQuestID = function() return _G.__FS_MOCK.superTrackedQuestID end,
    SetSuperTrackedQuestID = function(qid)
        if _G.__FS_MOCK.inCombat then error("ADDON_ACTION_BLOCKED: SetSuperTrackedQuestID in combat") end
        _G.__FS_MOCK.superTrackedQuestID = qid
    end,
    SetSuperTrackedUserWaypoint = function(flag)
        _G.__FS_MOCK.superTrackedWaypoint = flag
    end,
}

C_Map = {
    GetBestMapForUnit = function() return 1411 end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(wp)
        if _G.__FS_MOCK.inCombat then error("ADDON_ACTION_BLOCKED: SetUserWaypoint in combat") end
        _G.__FS_MOCK.userWaypoint = wp
    end,
    ClearUserWaypoint = function() _G.__FS_MOCK.userWaypoint = nil end,
}

C_QuestLog = {
    GetLogIndexForQuestID = function(qid)
        return (_G.__FS_MOCK.questLogSet and _G.__FS_MOCK.questLogSet[qid]) or nil
    end,
    GetNumQuestLogEntries = function()
        return #(_G.__FS_MOCK.questEntries or {})
    end,
    GetInfo = function(idx)
        return (_G.__FS_MOCK.questEntries or {})[idx]
    end,
    GetQuestObjectives = function() return {} end,
    GetQuestExpansion = function() return 0 end,
    IsComplete = function(qid) return (_G.__FS_MOCK.questComplete or {})[qid] == true end,
}

C_Container = {
    GetContainerNumFreeSlots = function() return _G.__FS_MOCK.bagFreeSlots, 0 end,
    GetContainerNumSlots = function() return 20 end,
}

function __FS_FIRE_EVENT(ev, ...)
    local list = _G.__FS_MOCK.events[ev]
    if not list then return end
    for _, frame in ipairs(list) do
        if frame._events[ev] and frame._scripts["OnEvent"] then
            frame._scripts["OnEvent"](frame, ev, ...)
        end
    end
end
"#;

fn setup_vm(v2_root: &Path) -> Result<Lua> {
    let lua = Lua::new();
    let globals = lua.globals();

    let make_secret = lua_err(lua.create_function(
        |_, (tag, utype): (String, Option<String>)| {
            Ok(SecretProxy {
                tag,
                underlying_type: utype.unwrap_or_else(|| "number".to_string()),
            })
        },
    ))?;
    lua_err(globals.set("FS_MakeSecret", make_secret))?;

    let secret_type = lua_err(lua.create_function(|_, val: Value| match val {
        Value::UserData(ud) => {
            if let Ok(sp) = ud.borrow::<SecretProxy>() {
                Ok(Some(sp.underlying_type.clone()))
            } else {
                Ok(None)
            }
        }
        _ => Ok(None),
    }))?;
    lua_err(globals.set("__FS_SECRET_TYPE", secret_type))?;

    let is_secret = lua_err(lua.create_function(|_, val: Value| match val {
        Value::UserData(ud) => Ok(ud.is::<SecretProxy>()),
        _ => Ok(false),
    }))?;
    lua_err(globals.set("issecretvalue", is_secret))?;

    lua_err(lua.load(WOW_MOCK_PRELUDE).set_name("wow_mock_prelude").exec())?;

    let media_dir = v2_root.join("ForeverSuite_Media");
    if media_dir.is_dir() {
        load_addon_into_vm(&lua, &media_dir)?;
    }

    let addon_dir = v2_root.join("ForeverSuiteV2");
    if addon_dir.is_dir() {
        load_addon_into_vm(&lua, &addon_dir)?;
    }

    let data_dir = v2_root.join("ForeverSuite_Data");
    let data_dir_str = data_dir.to_string_lossy().to_string();
    let loader_fn = lua_err(lua.create_function(move |lua_ctx, ()| {
        let p = PathBuf::from(&data_dir_str);
        if p.is_dir() {
            load_addon_into_vm(lua_ctx, &p)
                .map_err(|e| mlua::Error::RuntimeError(e.to_string()))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }))?;
    lua_err(globals.set("__FS_LOAD_DATA_ADDON", loader_fn))?;

    Ok(lua)
}

fn load_addon_into_vm(lua: &Lua, addon_dir: &Path) -> Result<()> {
    let toc = parse_toc(addon_dir)?;
    let ns = lua_err(lua.create_table())?;
    for rel in &toc.files {
        if rel.extension().and_then(|s| s.to_str()) != Some("lua") {
            continue;
        }
        let full = addon_dir.join(rel);
        let src = fs::read_to_string(&full)
            .with_context(|| format!("Failed to read {}", full.display()))?;
        let chunk = lua.load(&src).set_name(full.to_string_lossy().as_ref());
        let func = lua_err(chunk.into_function())?;
        lua_err(func.call::<()>((toc.addon_name.as_str(), ns.clone())))
            .with_context(|| format!("Error executing {}", full.display()))?;
    }
    Ok(())
}

pub fn run_tests(v2_root: &Path) -> Result<TestSummary> {
    let tests_dir = v2_root.join("tests");
    if !tests_dir.is_dir() {
        bail!("Tests directory not found: {}", tests_dir.display());
    }

    let mut test_files: Vec<PathBuf> = fs::read_dir(&tests_dir)?
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("lua"))
        .collect();
    test_files.sort();

    if test_files.is_empty() {
        bail!("No .lua test files found in {}", tests_dir.display());
    }

    let mut total = 0usize;
    let mut passed = 0usize;
    let mut failures = Vec::new();

    for tf in &test_files {
        total += 1;
        let label = tf
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("unknown.lua");
        let lua = setup_vm(v2_root)?;
        let src = fs::read_to_string(tf)?;
        match lua.load(&src).set_name(label).exec() {
            Ok(()) => {
                let asserts: usize = lua_err(lua.globals().get("__FS_ASSERT_COUNT"))?;
                if asserts == 0 {
                    let msg = format!("{label}: test file executed 0 assertions (fail-closed)");
                    println!("  [FAIL] {msg}");
                    failures.push(msg);
                } else {
                    passed += 1;
                    println!("  [PASS] {label} ({asserts} assertions)");
                }
            }
            Err(err) => {
                println!("  [FAIL] {label}: {err}");
                failures.push(format!("{label}: {err}"));
            }
        }
    }

    if !failures.is_empty() {
        bail!(
            "fsx test FAILED ({}/{} passed):\n{}",
            passed,
            total,
            failures.join("\n")
        );
    }

    Ok(TestSummary { total, passed })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secret_proxy_preserves_underlying_type_and_panics_on_ops() -> Result<()> {
        let lua = Lua::new();
        let make_secret = lua_err(lua.create_function(
            |_, (tag, utype): (String, Option<String>)| {
                Ok(SecretProxy {
                    tag,
                    underlying_type: utype.unwrap_or_else(|| "number".to_string()),
                })
            },
        ))?;
        lua_err(lua.globals().set("FS_MakeSecret", make_secret))?;
        let secret_type = lua_err(lua.create_function(|_, val: Value| match val {
            Value::UserData(ud) => Ok(ud.borrow::<SecretProxy>().ok().map(|s| s.underlying_type.clone())),
            _ => Ok(None),
        }))?;
        lua_err(lua.globals().set("__FS_SECRET_TYPE", secret_type))?;
        let is_secret = lua_err(lua.create_function(|_, val: Value| match val {
            Value::UserData(ud) => Ok(ud.is::<SecretProxy>()),
            _ => Ok(false),
        }))?;
        lua_err(lua.globals().set("issecretvalue", is_secret))?;
        lua_err(lua.load(WOW_MOCK_PRELUDE).exec())?;

        let ok: bool = lua_err(
            lua.load(
                r#"
                local s = FS_MakeSecret("hp", "number")
                local s2 = FS_MakeSecret("hp2", "number")
                assert(issecretvalue(s) == true)
                assert(type(s) == "number")
                local okTypeGuard = pcall(function() return type(s) == "number" and s > 0 end)
                local okMod = pcall(function() return s % 2 end)
                local okUnm = pcall(function() return -s end)
                local okEq = pcall(function() return s == s2 end)
                local okCat = pcall(function() return "x" .. s end)
                return (not okTypeGuard) and (not okMod) and (not okUnm) and (not okEq) and (not okCat)
                "#,
            )
            .eval(),
        )?;
        assert!(ok);
        Ok(())
    }
}

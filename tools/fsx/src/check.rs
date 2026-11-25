use crate::manifest::{
    forbidden_combat_apis, forbidden_legacy_apis, parse_toc, verified_c_apis,
};
use anyhow::{bail, Context, Result};
use full_moon::ast::{
    Assignment, Block, Call, Expression, FunctionArgs, FunctionBody, FunctionCall, Index,
    LocalAssignment, Prefix, Suffix, Var,
};
use full_moon::visitors::{Visit, Visitor};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

const DOMAIN_ALLOWED_GLOBALS: &[&str] = &[
    "assert", "error", "ipairs", "math", "next", "pairs", "pcall", "select", "string", "table",
    "tonumber", "tostring", "type", "unpack", "xpcall", "true", "false", "nil",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Layer {
    Domain,
    Api,
    Blizzard,
    Secure,
    Ui,
    Features,
    Other,
}

impl Layer {
    fn from_rel_path(rel: &Path) -> Self {
        let first = rel
            .components()
            .next()
            .and_then(|c| c.as_os_str().to_str())
            .unwrap_or("");
        match first {
            "Domain" => Layer::Domain,
            "Api" => Layer::Api,
            "Blizzard" => Layer::Blizzard,
            "Secure" => Layer::Secure,
            "UI" => Layer::Ui,
            "Features" => Layer::Features,
            _ => Layer::Other,
        }
    }
}

#[derive(Debug)]
pub struct CheckReport {
    pub files_checked: usize,
}

struct AstRuleChecker {
    file_label: String,
    layer: Layer,
    scope_stack: Vec<HashSet<String>>,
    aliases: HashMap<String, String>,
    violations: Vec<String>,
}

impl AstRuleChecker {
    fn new(file_label: String, layer: Layer) -> Self {
        Self {
            file_label,
            layer,
            scope_stack: vec![HashSet::new()],
            aliases: HashMap::new(),
            violations: Vec::new(),
        }
    }

    fn define_local(&mut self, name: String) {
        if let Some(top) = self.scope_stack.last_mut() {
            top.insert(name);
        }
    }

    fn is_local(&self, name: &str) -> bool {
        self.scope_stack.iter().rev().any(|s| s.contains(name))
    }

    fn push_violation(&mut self, msg: impl Into<String>) {
        self.violations
            .push(format!("[{}] {}", self.file_label, msg.into()));
    }

    fn strip_quotes(raw: &str) -> Option<String> {
        let s = raw.trim();
        if (s.starts_with('"') && s.ends_with('"') && s.len() >= 2)
            || (s.starts_with('\'') && s.ends_with('\'') && s.len() >= 2)
        {
            return Some(s[1..s.len() - 1].to_string());
        }
        None
    }

    fn extract_suffix_key(suf: &Suffix) -> Option<String> {
        if let Suffix::Index(idx) = suf {
            match idx {
                Index::Dot { name, .. } => return Some(name.token().to_string()),
                Index::Brackets { expression, .. } => {
                    return Self::strip_quotes(&expression.to_string());
                }
                _ => {}
            }
        }
        None
    }

    fn prefix_ident(prefix: &Prefix) -> String {
        match prefix {
            Prefix::Name(tok) => tok.token().to_string(),
            other => other.to_string().trim().to_string(),
        }
    }

    fn canonical_path(&self, head: &str, keys: &[String]) -> Vec<String> {
        let mut parts = Vec::new();
        let resolved_head = self.aliases.get(head).map(String::as_str).unwrap_or(head);
        for seg in resolved_head.split('.') {
            if !seg.is_empty() {
                parts.push(seg.to_string());
            }
        }
        parts.extend(keys.iter().cloned());
        if parts.first().map(String::as_str) == Some("_G") && parts.len() > 1 {
            parts.remove(0);
        }
        parts
    }

    fn check_c_api(&mut self, ns: &str, method: &str) {
        let full = format!("{ns}.{method}");
        if self.layer == Layer::Domain {
            self.push_violation(format!(
                "Domain layer must be pure (zero WoW I/O): forbidden call '{full}'"
            ));
            return;
        }
        if !verified_c_apis().contains(full.as_str()) {
            self.push_violation(format!("Unverified WoW Forever 1.60.1 C_* API: '{full}'"));
        }
        if full == "C_QuestLog.SetSelectedQuest" {
            self.push_violation(
                "C_QuestLog.SetSelectedQuest is banned in v2 (triggers WorldMap pin taint in 1.60.1)"
                    .to_string(),
            );
        }
        if matches!(self.layer, Layer::Features | Layer::Ui)
            && (ns == "C_SuperTrack" || full == "C_Map.SetUserWaypoint")
        {
            self.push_violation(format!(
                "Layer {:?} must route '{full}' through Api/SafeAPI NavPort (single write path)",
                self.layer
            ));
        }
    }

    fn check_canonical_symbol(&mut self, parts: &[String], raw_head: &str) {
        if raw_head == "_G" && self.layer == Layer::Domain {
            self.push_violation("Domain layer must not access _G".to_string());
        }
        if parts.is_empty() {
            return;
        }
        let first = parts[0].as_str();

        if self.layer == Layer::Domain
            && raw_head != "_G"
            && !self.is_local(raw_head)
            && !DOMAIN_ALLOWED_GLOBALS.contains(&first)
        {
            self.push_violation(format!(
                "Domain layer must be pure (allow-listed Lua 5.1 globals only): forbidden global '{first}'"
            ));
        }

        if forbidden_legacy_apis().contains(&first) {
            self.push_violation(format!("Forbidden legacy WoW API: '{first}'"));
        }
        if forbidden_combat_apis().contains(&first) {
            self.push_violation(format!("Forbidden combat automation API: '{first}'"));
        }
        if first == "CreateFrame" {
            match self.layer {
                Layer::Domain => {
                    self.push_violation("Domain layer must not call CreateFrame".to_string())
                }
                Layer::Features => self.push_violation(
                    "Features layer must use UI/Widgets instead of raw CreateFrame".to_string(),
                ),
                _ => {}
            }
        }
        if first == "EditModeManagerFrame" {
            self.push_violation(
                "Blizzard EditModeManagerFrame coupling is forbidden in v2 (use UI/HudLayout)"
                    .to_string(),
            );
        }
        if self.layer == Layer::Blizzard && parts.iter().any(|p| p == "SetScript") {
            self.push_violation(
                "Blizzard/ layer must NEVER reference or call SetScript (use HookScript only)"
                    .to_string(),
            );
        }
        if first.starts_with("C_") && parts.len() >= 2 {
            self.check_c_api(first, &parts[1]);
        }
    }

    fn check_call(&mut self, call: &FunctionCall) {
        let raw_head = Self::prefix_ident(call.prefix());
        let suffixes: Vec<&Suffix> = call.suffixes().collect();
        let mut keys = Vec::new();
        for suf in &suffixes {
            if let Some(k) = Self::extract_suffix_key(suf) {
                keys.push(k);
            } else {
                break;
            }
        }
        let parts = self.canonical_path(&raw_head, &keys);
        self.check_canonical_symbol(&parts, &raw_head);

        let is_create_frame = parts.first().map(String::as_str) == Some("CreateFrame");
        if is_create_frame {
            for suf in &suffixes {
                if let Suffix::Call(Call::AnonymousCall(FunctionArgs::Parentheses {
                    arguments,
                    ..
                })) = suf
                {
                    let args: Vec<String> = arguments
                        .iter()
                        .map(|e| e.to_string().trim().to_string())
                        .collect();
                    if let Some(tpl) = args.get(3) {
                        let resolved_tpl = self.aliases.get(tpl).map(String::as_str).unwrap_or(tpl);
                        if resolved_tpl.contains("SecureActionButtonTemplate")
                            || resolved_tpl.contains("Secure")
                        {
                            if self.layer != Layer::Secure {
                                self.push_violation(format!(
                                    "SecureActionButtonTemplate only allowed in Secure/ layer (found in {:?})",
                                    self.layer
                                ));
                            }
                            let parent_ok = args
                                .get(2)
                                .map(|p| p == "UIParent" || p == "_G.UIParent")
                                .unwrap_or(false);
                            if !parent_ok {
                                self.push_violation(
                                    "SecureActionButtonTemplate parent MUST be UIParent or _G.UIParent"
                                        .to_string(),
                                );
                            }
                        }
                    }
                }
            }
        }

        for suf in &suffixes {
            if let Suffix::Call(Call::MethodCall(mc)) = suf {
                let method = mc.name().token().to_string();
                if self.layer == Layer::Blizzard && method == "SetScript" {
                    self.push_violation(
                        "Blizzard/ layer must NEVER call :SetScript (use :HookScript only)"
                            .to_string(),
                    );
                }
                if self.layer == Layer::Domain
                    && matches!(method.as_str(), "SetScript" | "HookScript" | "RegisterEvent")
                {
                    self.push_violation(format!(
                        "Domain/ layer must not call frame method ':{method}'"
                    ));
                }
            }
        }
    }
}

impl Visitor for AstRuleChecker {
    fn visit_block(&mut self, _node: &Block) {
        self.scope_stack.push(HashSet::new());
    }

    fn visit_block_end(&mut self, _node: &Block) {
        if self.scope_stack.len() > 1 {
            self.scope_stack.pop();
        }
    }

    fn visit_function_body(&mut self, body: &FunctionBody) {
        self.scope_stack.push(HashSet::new());
        self.define_local("self".to_string());
        for p in body.parameters() {
            let p_str = p.to_string().trim().to_string();
            if p_str != "..." {
                self.define_local(p_str);
            }
        }
    }

    fn visit_function_body_end(&mut self, _body: &FunctionBody) {
        if self.scope_stack.len() > 1 {
            self.scope_stack.pop();
        }
    }

    fn visit_local_function(&mut self, node: &full_moon::ast::LocalFunction) {
        self.define_local(node.name().token().to_string());
    }

    fn visit_generic_for(&mut self, node: &full_moon::ast::GenericFor) {
        self.scope_stack.push(HashSet::new());
        for n in node.names() {
            self.define_local(n.token().to_string());
        }
    }

    fn visit_generic_for_end(&mut self, _node: &full_moon::ast::GenericFor) {
        if self.scope_stack.len() > 1 {
            self.scope_stack.pop();
        }
    }

    fn visit_numeric_for(&mut self, node: &full_moon::ast::NumericFor) {
        self.scope_stack.push(HashSet::new());
        self.define_local(node.index_variable().token().to_string());
    }

    fn visit_numeric_for_end(&mut self, _node: &full_moon::ast::NumericFor) {
        if self.scope_stack.len() > 1 {
            self.scope_stack.pop();
        }
    }

    fn visit_local_assignment(&mut self, node: &LocalAssignment) {
        // Evaluate ALL RHS expressions in the PRE-declaration lexical scope BEFORE registering LHS names!
        // Catches `local UnitName = UnitName("player")`, `local GetTime = GetTime or f`, `local x = (UnitName)`, etc.
        let mut rhs_checker = AstRuleChecker {
            file_label: self.file_label.clone(),
            layer: self.layer,
            scope_stack: self.scope_stack.clone(),
            aliases: self.aliases.clone(),
            violations: Vec::new(),
        };
        for rhs_expr in node.expressions() {
            rhs_expr.visit(&mut rhs_checker);
        }
        self.violations.extend(rhs_checker.violations);

        let names: Vec<String> = node.names().iter().map(|n| n.token().to_string()).collect();
        let exprs: Vec<String> = node
            .expressions()
            .iter()
            .map(|e| e.to_string().trim().to_string())
            .collect();
        for (i, name) in names.iter().enumerate() {
            self.define_local(name.clone());
            if let Some(rhs) = exprs.get(i) {
                let clean = rhs.trim_start_matches("_G.").to_string();
                if clean
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic() || c == '_')
                    .unwrap_or(false)
                    && clean.chars().all(|c| c.is_alphanumeric() || c == '_' || c == '.')
                    || Self::strip_quotes(rhs).is_some()
                {
                    self.aliases.insert(name.clone(), rhs.clone());
                }
            }
        }
    }

    fn visit_assignment(&mut self, node: &Assignment) {
        for var in node.variables() {
            if let Var::Expression(ve) = var {
                let raw_head = Self::prefix_ident(ve.prefix());
                let mut keys = Vec::new();
                for suf in ve.suffixes() {
                    if let Some(k) = Self::extract_suffix_key(suf) {
                        keys.push(k);
                    }
                }
                let parts = self.canonical_path(&raw_head, &keys);
                if let Some(first) = parts.first() {
                    if matches!(first.as_str(), "ObjectiveTrackerFrame" | "WorldMapFrame")
                        && parts.len() >= 2
                    {
                        self.push_violation(format!(
                            "Direct field write onto Blizzard frame '{}' is forbidden: '{}'",
                            first,
                            var.to_string().trim()
                        ));
                    }
                }
            }
        }
    }

    fn visit_function_call(&mut self, call: &FunctionCall) {
        self.check_call(call);
    }

    fn visit_expression(&mut self, expr: &Expression) {
        if let Expression::Var(var) = expr {
            match var {
                Var::Name(tok) => {
                    let name = tok.token().to_string();
                    let parts = self.canonical_path(&name, &[]);
                    self.check_canonical_symbol(&parts, &name);
                }
                Var::Expression(ve) => {
                    let raw_head = Self::prefix_ident(ve.prefix());
                    let mut keys = Vec::new();
                    for suf in ve.suffixes() {
                        if let Some(k) = Self::extract_suffix_key(suf) {
                            keys.push(k);
                        }
                    }
                    let parts = self.canonical_path(&raw_head, &keys);
                    self.check_canonical_symbol(&parts, &raw_head);
                }
                _ => {}
            }
        }
    }

    fn visit_prefix(&mut self, prefix: &Prefix) {
        if let Prefix::Name(tok) = prefix {
            let name = tok.token().to_string();
            let parts = self.canonical_path(&name, &[]);
            self.check_canonical_symbol(&parts, &name);
        }
    }
}

pub fn check_lua_source(rel_path: &Path, source: &str) -> Vec<String> {
    let label = rel_path.to_string_lossy().to_string();
    let ast = match full_moon::parse(source) {
        Ok(ast) => ast,
        Err(errs) => {
            return errs
                .into_iter()
                .map(|e| format!("[{label}] Lua 5.1 syntax error: {e}"))
                .collect();
        }
    };

    let mut checker = AstRuleChecker::new(label, Layer::from_rel_path(rel_path));
    checker.visit_ast(&ast);
    checker.violations.sort();
    checker.violations.dedup();
    checker.violations
}

pub fn run_check(addon_dir: &Path) -> Result<CheckReport> {
    let toc = parse_toc(addon_dir)?;
    let mut violations = Vec::new();

    if !toc.interfaces.iter().any(|i| i == "16001") {
        violations.push(format!(
            "[TOC] {} missing Interface 16001 (found: {:?})",
            toc.addon_name, toc.interfaces
        ));
    }
    if toc.addon_name == "ForeverSuite_Data" && !toc.load_on_demand {
        violations.push(
            "[TOC] ForeverSuite_Data MUST declare '## LoadOnDemand: 1' (zero login RAM invariant)"
                .to_string(),
        );
    }

    let mut toc_lua_set: HashSet<PathBuf> = HashSet::new();
    for rel in &toc.files {
        let full = addon_dir.join(rel);
        if !full.is_file() {
            violations.push(format!("[TOC] Missing file listed in TOC: {}", rel.display()));
            continue;
        }
        if rel.extension().and_then(|s| s.to_str()) == Some("lua") {
            toc_lua_set.insert(rel.clone());
        }
    }

    let mut disk_lua_set: HashSet<PathBuf> = HashSet::new();
    for entry in WalkDir::new(addon_dir) {
        let entry = entry.with_context(|| format!("Walk error in {}", addon_dir.display()))?;
        if entry.path_is_symlink() {
            violations.push(format!("[FS] Symlink rejected: {}", entry.path().display()));
            continue;
        }
        if !entry.file_type().is_file() {
            continue;
        }
        if entry.path().extension().and_then(|s| s.to_str()) != Some("lua") {
            continue;
        }
        let rel = entry
            .path()
            .strip_prefix(addon_dir)
            .context("Failed to strip addon prefix")?
            .to_path_buf();
        disk_lua_set.insert(rel);
    }

    for orphan in disk_lua_set.difference(&toc_lua_set) {
        violations.push(format!(
            "[TOC] Orphan .lua file not registered in {}.toc: {}",
            toc.addon_name,
            orphan.display()
        ));
    }

    let mut files_checked = 0usize;
    for rel in &toc.files {
        if rel.extension().and_then(|s| s.to_str()) != Some("lua") {
            continue;
        }
        let full = addon_dir.join(rel);
        if !full.is_file() {
            continue;
        }
        let src = fs::read_to_string(&full)
            .with_context(|| format!("Failed to read {}", full.display()))?;
        files_checked += 1;
        violations.extend(check_lua_source(rel, &src));
    }

    if !violations.is_empty() {
        violations.sort();
        violations.dedup();
        let mut msg = format!(
            "fsx check FAILED with {} violation(s) in {}:\n",
            violations.len(),
            addon_dir.display()
        );
        for v in &violations {
            msg.push_str("  - ");
            msg.push_str(v);
            msg.push('\n');
        }
        bail!(msg);
    }

    Ok(CheckReport { files_checked })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_layer_enforces_strict_lexical_global_allowlist() {
        // Upvalues, calls, fallback OR, parenthesized RHS, and parameter-name escape across functions
        let src = r#"
local UnitName = UnitName("player")
local GetTime = GetTime or function() return 0 end
local InCombatLockdown = (InCombatLockdown)
local function helper(GetRealmName) return GetRealmName end
local leaked = GetRealmName()
local okFloat = 0.5
"#;
        let errs = check_lua_source(Path::new("Domain/BadModel.lua"), src);
        assert!(errs.iter().any(|e| e.contains("UnitName")), "missed UnitName: {errs:?}");
        assert!(errs.iter().any(|e| e.contains("GetTime")), "missed GetTime: {errs:?}");
        assert!(
            errs.iter().any(|e| e.contains("InCombatLockdown")),
            "missed InCombatLockdown: {errs:?}"
        );
        assert!(
            errs.iter().any(|e| e.contains("GetRealmName")),
            "parameter scope leaked across function: {errs:?}"
        );
        assert!(
            !errs.iter().any(|e| e.contains("'0'")),
            "float 0.5 should not trigger false positive: {errs:?}"
        );
    }

    #[test]
    fn blocks_dot_g_bracket_and_alias_bypasses() {
        let src = r#"
_G.CastSpellByName("Fireball")
_G["TargetUnit"]("target")
_G.C_QuestLog.SetSelectedQuest(101)
local Q = C_QuestLog
Q.SetSelectedQuest(101)
"#;
        let errs = check_lua_source(Path::new("Api/Bypass.lua"), src);
        assert!(errs.iter().any(|e| e.contains("CastSpellByName")));
        assert!(errs.iter().any(|e| e.contains("TargetUnit")));
        assert!(errs.iter().any(|e| e.contains("SetSelectedQuest")));
    }

    #[test]
    fn blizzard_layer_forbids_pcall_setscript_and_all_frame_field_writes() {
        let bad = check_lua_source(
            Path::new("Blizzard/Obj.lua"),
            "pcall(ObjectiveTrackerFrame.SetScript, ObjectiveTrackerFrame, 'OnShow', function() end)\n\
_G.ObjectiveTrackerFrame.flag = true\n\
_G['WorldMapFrame'].x = 1\n\
local f = _G.ObjectiveTrackerFrame\n\
f['myFlag'] = true\n",
        );
        assert!(bad.iter().any(|e| e.contains("SetScript")));
        assert!(bad.iter().any(|e| e.contains("ObjectiveTrackerFrame")));
        assert!(bad.iter().any(|e| e.contains("WorldMapFrame")));

        let good = check_lua_source(
            Path::new("Blizzard/Obj.lua"),
            "ObjectiveTrackerFrame:HookScript('OnShow', function() end)\n",
        );
        assert!(good.is_empty(), "unexpected errors: {good:?}");
    }

    #[test]
    fn secure_button_requires_uiparent_and_catches_aliased_template() {
        let bad = check_lua_source(
            Path::new("Secure/Dock.lua"),
            "local tpl = 'SecureActionButtonTemplate'\nlocal b = CreateFrame('Button', 'B1', myPanel, tpl)\n",
        );
        assert!(bad.iter().any(|e| e.contains("UIParent")));
    }
}

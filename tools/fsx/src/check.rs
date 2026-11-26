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
    let mut prod_sources = String::new();
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
        prod_sources.push_str(&src);
        prod_sources.push('\n');
        violations.extend(check_lua_source(rel, &src));
    }

    // A0 Anti-Fake Static Wiring Gate: verify zero dead packs, zero unwired feature methods, and zero synthetic placeholder data
    if toc.addon_name == "ForeverSuite" {
        if let Some(v2_root) = addon_dir.parent() {
            let global_fonts = v2_root.join("ForeverSuite_Fonts_Global/GlobalFonts.lua");
            if let Ok(gf_src) = fs::read_to_string(&global_fonts) {
                prod_sources.push_str(&gf_src);
                prod_sources.push('\n');
            }
            violations.extend(check_unwired_feature_methods(addon_dir, &prod_sources));
            if v2_root.join("ForeverSuite_Data/gj_lod_manifest.json").is_file() {
                violations.extend(check_dead_packs(v2_root, &prod_sources));
                violations.extend(check_fabricated_pack_data(v2_root));
            }
        }
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

fn is_ident_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

fn count_member_refs(haystack: &str, method: &str) -> usize {
    let bytes = haystack.as_bytes();
    let mbytes = method.as_bytes();
    if mbytes.is_empty() || bytes.len() <= mbytes.len() {
        return 0;
    }
    let mut count = 0usize;
    let mut i = 1usize;
    while i + mbytes.len() <= bytes.len() {
        if (bytes[i - 1] == b':' || bytes[i - 1] == b'.')
            && &bytes[i..i + mbytes.len()] == mbytes
        {
            let after_ok = i + mbytes.len() == bytes.len()
                || !is_ident_char(bytes[i + mbytes.len()]);
            if after_ok {
                count += 1;
                i += mbytes.len();
                continue;
            }
        }
        i += 1;
    }
    count
}

fn contains_whole_ident(haystack: &str, ident: &str) -> bool {
    let bytes = haystack.as_bytes();
    let ibytes = ident.as_bytes();
    if ibytes.is_empty() || bytes.len() < ibytes.len() {
        return false;
    }
    for i in 0..=bytes.len() - ibytes.len() {
        if &bytes[i..i + ibytes.len()] == ibytes {
            let before_ok = i == 0 || !is_ident_char(bytes[i - 1]);
            let after_ok =
                i + ibytes.len() == bytes.len() || !is_ident_char(bytes[i + ibytes.len()]);
            if before_ok && after_ok {
                return true;
            }
        }
    }
    false
}

pub fn check_unwired_feature_methods(addon_dir: &Path, prod_sources: &str) -> Vec<String> {
    let mut violations = Vec::new();
    let features_dir = addon_dir.join("Features");
    if !features_dir.is_dir() {
        return violations;
    }
    let Ok(entries) = fs::read_dir(&features_dir) else {
        return violations;
    };
    let lifecycle_allow: HashSet<&str> = HashSet::from([
        "Init", "Build", "OnShow", "OnSearch", "Refresh", "Show", "Hide", "Toggle", "Render",
    ]);
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|s| s.to_str()) != Some("lua") {
            continue;
        }
        let Ok(src) = fs::read_to_string(&path) else {
            continue;
        };
        let fname = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("Features.lua");
        for line in src.lines() {
            let trimmed = line.trim_start();
            let Some(rest) = trimmed.strip_prefix("function ") else {
                continue;
            };
            let Some((sig, _)) = rest.split_once('(') else {
                continue;
            };
            let sig = sig.trim();
            let method = sig
                .rsplit_once(':')
                .or_else(|| sig.rsplit_once('.'))
                .map(|(_, m)| m.trim());
            let Some(m) = method else {
                continue;
            };
            if m.is_empty()
                || lifecycle_allow.contains(m)
                || m.starts_with("Ensure")
                || !m.bytes().all(is_ident_char)
            {
                continue;
            }
            if count_member_refs(prod_sources, m) <= 1 {
                violations.push(format!(
                    "[A0-WIRING] Features/{fname}: method '{sig}' has 0 production callers (dead/test-only method)"
                ));
            }
        }
    }
    violations
}

pub fn check_dead_packs(v2_root: &Path, prod_sources: &str) -> Vec<String> {
    let mut violations = Vec::new();
    let manifest_path = v2_root.join("ForeverSuite_Data/gj_lod_manifest.json");
    let Ok(raw) = fs::read_to_string(&manifest_path) else {
        return violations;
    };
    let Ok(val) = serde_json::from_str::<serde_json::Value>(&raw) else {
        violations.push("[A0-PACK] Failed to parse ForeverSuite_Data/gj_lod_manifest.json".into());
        return violations;
    };
    let Some(packs) = val.get("packs").and_then(|p| p.as_array()) else {
        return violations;
    };
    for p in packs {
        let pack_id = p.get("pack_id").and_then(|v| v.as_str()).unwrap_or("");
        let addon_name = p.get("addon_name").and_then(|v| v.as_str()).unwrap_or("");
        if pack_id.is_empty() {
            continue;
        }
        if addon_name == "ForeverSuite_Media_Assets" {
            if !contains_whole_ident(prod_sources, "ForeverSuiteMediaAssets") {
                violations.push(
                    "[A0-PACK] ForeverSuite_Media_Assets manifest global 'ForeverSuiteMediaAssets' has 0 production references"
                        .into(),
                );
            }
        } else if !contains_whole_ident(prod_sources, pack_id) {
            violations.push(format!(
                "[A0-PACK] Compiled LoD pack '{pack_id}' ({addon_name}) has 0 production Lua references"
            ));
        }
    }
    violations
}

pub fn check_fabricated_pack_data(v2_root: &Path) -> Vec<String> {
    let mut violations = Vec::new();
    let Ok(dirs) = fs::read_dir(v2_root) else {
        return violations;
    };
    for dir_entry in dirs.flatten() {
        let dpath = dir_entry.path();
        let dname = dpath.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !dpath.is_dir() || !dname.starts_with("ForeverSuite_Data_") {
            continue;
        }
        let Ok(files) = fs::read_dir(&dpath) else {
            continue;
        };
        for fentry in files.flatten() {
            let fpath = fentry.path();
            let fname = fpath.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if !fname.starts_with("Pack_") || !fname.ends_with(".lua") {
                continue;
            }
            let Ok(src) = fs::read_to_string(&fpath) else {
                continue;
            };
            if src.contains("title=\"호위 퀘스트 #") {
                violations.push(format!(
                    "[A0-DATA] {dname}/{fname}: synthetic placeholder title '호위 퀘스트 #...' detected"
                ));
            }
            if fname.starts_with("Pack_quest_tips_") {
                let mut note_counts: HashMap<String, usize> = HashMap::new();
                let mut total_notes = 0usize;
                for line in src.lines() {
                    if let Some(pos) = line.find("note=\"") {
                        let rest = &line[pos + 6..];
                        if let Some(end) = rest.find('"') {
                            let note = &rest[..end];
                            if !note.is_empty() {
                                total_notes += 1;
                                *note_counts.entry(note.to_string()).or_insert(0) += 1;
                            }
                        }
                    }
                }
                if total_notes >= 10 {
                    if let Some((top_note, max_cnt)) =
                        note_counts.iter().max_by_key(|(_, c)| **c)
                    {
                        if max_cnt * 2 > total_notes {
                            violations.push(format!(
                                "[A0-DATA] {dname}/{fname}: mass-duplicated generic note ({max_cnt}/{total_notes} identical): '{}'",
                                top_note.chars().take(40).collect::<String>()
                            ));
                        }
                    }
                }
            }
        }
    }
    violations
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

    #[test]
    fn a0_gate_catches_unwired_methods_dead_packs_and_placeholder_data() {
        let dir = tempfile::tempdir().unwrap();
        let v2 = dir.path();
        let addon = v2.join("ForeverSuite");
        fs::create_dir_all(addon.join("Features")).unwrap();
        fs::create_dir_all(v2.join("ForeverSuite_Data")).unwrap();
        fs::create_dir_all(v2.join("ForeverSuite_Data_QuestExtra")).unwrap();

        let feat_src = "function Mod:WiredFn() return 1 end\nfunction Mod:DeadFn() return 2 end\nfunction Mod:Init() self:WiredFn() end\n";
        fs::write(addon.join("Features/Mod.lua"), feat_src).unwrap();
        let unwired = check_unwired_feature_methods(&addon, feat_src);
        assert!(unwired.iter().any(|e| e.contains("DeadFn")), "missed DeadFn: {unwired:?}");
        assert!(!unwired.iter().any(|e| e.contains("WiredFn")), "false positive WiredFn: {unwired:?}");

        fs::write(
            v2.join("ForeverSuite_Data/gj_lod_manifest.json"),
            r#"{"packs":[{"addon_name":"ForeverSuite_Data_QuestExtra","pack_id":"quest_collection"}]}"#,
        )
        .unwrap();
        let dead = check_dead_packs(v2, "local x = 1");
        assert!(dead.iter().any(|e| e.contains("quest_collection")), "missed dead pack: {dead:?}");

        fs::write(
            v2.join("ForeverSuite_Data_QuestExtra/Pack_quest_tips_01.lua"),
            "{title=\"호위 퀘스트 #155\",note=\"same\"}\n",
        )
        .unwrap();
        let fake = check_fabricated_pack_data(v2);
        assert!(fake.iter().any(|e| e.contains("placeholder")), "missed placeholder: {fake:?}");

        // DDT boundary: exactly 50% (5/10) identical passes, 60% (6/10) fails, 9 entries below threshold passes
        let mut exact_half = String::new();
        for i in 0..5 { exact_half.push_str(&format!("{{title=\"T{i}\",note=\"dup\"}}\n")); }
        for i in 5..10 { exact_half.push_str(&format!("{{title=\"T{i}\",note=\"uniq{i}\"}}\n")); }
        fs::write(v2.join("ForeverSuite_Data_QuestExtra/Pack_quest_tips_01.lua"), &exact_half).unwrap();
        assert!(check_fabricated_pack_data(v2).is_empty(), "50% boundary should pass");

        exact_half.push_str("{title=\"T10\",note=\"dup\"}\n");
        fs::write(v2.join("ForeverSuite_Data_QuestExtra/Pack_quest_tips_01.lua"), &exact_half).unwrap();
        let over_half = check_fabricated_pack_data(v2);
        assert!(over_half.iter().any(|e| e.contains("mass-duplicated")), "54.5% (6/11) must fail: {over_half:?}");
    }
}

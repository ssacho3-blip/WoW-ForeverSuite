use anyhow::{bail, Context, Result};
use regex::Regex;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Default)]
pub struct TaintReportData {
    pub taint_log_hits: BTreeMap<String, usize>,
    pub canary_counts: BTreeMap<String, usize>,
    pub gj_usage: BTreeMap<String, usize>,
}

pub fn parse_taint_log(content: &str) -> BTreeMap<String, usize> {
    let mut counts = BTreeMap::new();
    let re_retail = Regex::new(
        r"An action was blocked in combat because of taint from\s+([A-Za-z0-9_]+)\s*-\s*([A-Za-z0-9_.:()]+)",
    )
    .expect("valid regex");
    let re_blocked = Regex::new(
        r"(?:ADDON_ACTION_BLOCKED|ADDON_ACTION_FORBIDDEN|Action\[.*?\]\s+(?:blocked|forbidden)).*?([A-Za-z0-9_]+:[A-Za-z0-9_():]+)",
    )
    .expect("valid regex");
    let re_tainted = Regex::new(r"Execution tainted by\s+([A-Za-z0-9_]+)").expect("valid regex");

    for line in content.lines() {
        if let Some(cap) = re_retail.captures(line) {
            *counts
                .entry(format!("{}:{}", &cap[1], &cap[2]))
                .or_insert(0) += 1;
        } else if let Some(cap) = re_blocked.captures(line) {
            *counts.entry(cap[1].to_string()).or_insert(0) += 1;
        } else if let Some(cap) = re_tainted.captures(line) {
            *counts
                .entry(format!("TaintedBy:{}", &cap[1]))
                .or_insert(0) += 1;
        }
    }
    counts
}

pub fn parse_saved_vars_diagnostics(
    content: &str,
) -> (BTreeMap<String, usize>, BTreeMap<String, usize>) {
    let mut taint_counts = BTreeMap::new();
    let mut gj_usage = BTreeMap::new();

    let re_taint_block =
        Regex::new(r#"(?s)\["taintCounts"\]\s*=\s*\{(.*?)\}"#).expect("valid regex");
    let re_kv = Regex::new(r#"\["([^"]+)"\]\s*=\s*(\d+)"#).expect("valid regex");
    for cap in re_taint_block.captures_iter(content) {
        for kv in re_kv.captures_iter(&cap[1]) {
            if let Ok(n) = kv[2].parse::<usize>() {
                *taint_counts.entry(kv[1].to_string()).or_insert(0) += n;
            }
        }
    }

    let re_gj_entry =
        Regex::new(r#"(?s)\["((?:GodJohnson|GJ)[^"]+)"\]\s*=\s*\{[^}]*\["count"\]\s*=\s*(\d+)"#)
            .expect("valid regex");
    for cap in re_gj_entry.captures_iter(content) {
        if let Ok(n) = cap[2].parse::<usize>() {
            *gj_usage.entry(cap[1].to_string()).or_insert(0) += n;
        }
    }

    (taint_counts, gj_usage)
}

pub fn run_report(taint_log: Option<&Path>, saved_vars: Option<&Path>) -> Result<()> {
    if taint_log.is_none() && saved_vars.is_none() {
        bail!("Provide at least one of --taint-log or --saved-vars");
    }

    let mut report = TaintReportData::default();
    if let Some(p) = taint_log {
        let text = fs::read_to_string(p)
            .with_context(|| format!("Failed to read taint log: {}", p.display()))?;
        report.taint_log_hits = parse_taint_log(&text);
    }
    if let Some(p) = saved_vars {
        let text = fs::read_to_string(p)
            .with_context(|| format!("Failed to read SavedVariables: {}", p.display()))?;
        let (tc, gj) = parse_saved_vars_diagnostics(&text);
        report.canary_counts = tc;
        report.gj_usage = gj;
    }

    println!("=== ForeverSuite fsx taint-report ===");
    println!(
        "[taint.log offenders: {} unique]",
        report.taint_log_hits.len()
    );
    print_sorted(&report.taint_log_hits);
    println!(
        "[SavedVariables Taint Canary: {} unique]",
        report.canary_counts.len()
    );
    print_sorted(&report.canary_counts);
    println!(
        "[GodJohnson Panel OnShow Usage: {} panels]",
        report.gj_usage.len()
    );
    print_sorted(&report.gj_usage);
    Ok(())
}

fn print_sorted(map: &BTreeMap<String, usize>) {
    let mut rows: Vec<(&String, &usize)> = map.iter().collect();
    rows.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    for (k, v) in rows {
        println!("  {:>6}x  {}", v, k);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_blocked_forbidden_retail_format_and_multiple_taint_blocks() {
        let log = "11/25 12:00 Execution tainted by ForeverSuite\n\
11/25 12:01 An action was blocked in combat because of taint from ForeverSuite - Button:SetPassThroughButtons()\n\
11/25 12:02 ADDON_ACTION_FORBIDDEN GodJohnsonGoldBorder:Show()\n";
        let hits = parse_taint_log(log);
        assert_eq!(hits.get("TaintedBy:ForeverSuite"), Some(&1));
        assert_eq!(hits.get("ForeverSuite:Button:SetPassThroughButtons()"), Some(&1));
        assert_eq!(hits.get("GodJohnsonGoldBorder:Show()"), Some(&1));

        let sv = r#"
ForeverSuiteDB = {
    ["_diagnostics"] = {
        ["taintCounts"] = { ["ForeverSuite:A"] = 2 },
        ["gjUsage"] = {
            ["GodJohnsonAtlasPanel"] = { ["count"] = 12, ["lastSeen"] = 1000 },
        },
    },
    ["v2"] = {
        ["diagnostics"] = {
            ["taintCounts"] = { ["ForeverSuite:A"] = 3, ["ForeverSuite:B"] = 1 },
        },
    },
}
"#;
        let (tc, gj) = parse_saved_vars_diagnostics(sv);
        assert_eq!(tc.get("ForeverSuite:A"), Some(&5));
        assert_eq!(tc.get("ForeverSuite:B"), Some(&1));
        assert_eq!(gj.get("GodJohnsonAtlasPanel"), Some(&12));
    }
}

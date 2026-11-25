use anyhow::{bail, Context, Result};
use mlua::Lua;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::Path;
use zip::ZipArchive;

#[derive(Debug, Serialize, Deserialize)]
pub struct PackSource {
    pub pack: PackMeta,
    #[serde(default)]
    pub entries: Vec<toml::Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PackMeta {
    pub id: String,
    pub title: String,
    pub category: String,
    pub license: String,
    pub source: String,
    #[serde(default)]
    pub source_sha256: String,
}

#[derive(Debug, Serialize)]
struct ProvenanceManifest {
    generator: String,
    packs: Vec<ProvenanceEntry>,
}

#[derive(Debug, Serialize)]
struct ProvenanceEntry {
    id: String,
    category: String,
    license: String,
    source: String,
    source_sha256: String,
    entry_count: usize,
    output_file: String,
    output_sha256: String,
}

fn sha256_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn is_valid_pack_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.is_empty() || bytes.len() > 32 {
        return false;
    }
    if !bytes[0].is_ascii_lowercase() {
        return false;
    }
    bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

fn sanitize_comment(s: &str) -> String {
    s.replace(['\r', '\n'], " ")
}

fn write_file_atomic(target: &Path, content: &[u8]) -> Result<()> {
    let parent = target.parent().context("Missing parent directory")?;
    fs::create_dir_all(parent)?;
    let name = target
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid target filename")?;
    let tmp = parent.join(format!(".{name}.{}.tmp", std::process::id()));
    fs::write(&tmp, content)?;
    fs::rename(&tmp, target)?;
    Ok(())
}

fn lua_escape_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for ch in s.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn toml_to_lua(val: &toml::Value, indent: usize) -> String {
    let pad = "    ".repeat(indent);
    let inner_pad = "    ".repeat(indent + 1);
    match val {
        toml::Value::String(s) => lua_escape_string(s),
        toml::Value::Integer(i) => i.to_string(),
        toml::Value::Float(f) => format!("{f}"),
        toml::Value::Boolean(b) => if *b { "true" } else { "false" }.to_string(),
        toml::Value::Datetime(dt) => lua_escape_string(&dt.to_string()),
        toml::Value::Array(arr) => {
            if arr.is_empty() {
                return "{}".to_string();
            }
            let mut lines = vec!["{".to_string()];
            for item in arr {
                lines.push(format!("{inner_pad}{},", toml_to_lua(item, indent + 1)));
            }
            lines.push(format!("{pad}}}"));
            lines.join("\n")
        }
        toml::Value::Table(tbl) => {
            if tbl.is_empty() {
                return "{}".to_string();
            }
            let mut lines = vec!["{".to_string()];
            for (k, v) in tbl {
                let key_repr = if k
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic() || c == '_')
                    .unwrap_or(false)
                    && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    k.clone()
                } else {
                    format!("[{}]", lua_escape_string(k))
                };
                lines.push(format!(
                    "{inner_pad}{key_repr} = {},",
                    toml_to_lua(v, indent + 1)
                ));
            }
            lines.push(format!("{pad}}}"));
            lines.join("\n")
        }
    }
}

pub fn inspect_gj_zip(zip_path: &Path) -> Result<()> {
    let file = File::open(zip_path)
        .with_context(|| format!("Failed to open ZIP: {}", zip_path.display()))?;
    let mut archive = ZipArchive::new(file)?;
    let mut by_ext: BTreeMap<String, (usize, u64)> = BTreeMap::new();
    let mut total_bytes = 0u64;

    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        if entry.is_dir() {
            continue;
        }
        let sz = entry.size();
        total_bytes += sz;
        let ext = Path::new(entry.name())
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("(none)")
            .to_ascii_lowercase();
        let slot = by_ext.entry(ext).or_insert((0, 0));
        slot.0 += 1;
        slot.1 += sz;
    }

    println!(
        "GodJohnson ZIP inspection: {} ({} files, {:.2} MB uncompressed)",
        zip_path.display(),
        archive.len(),
        total_bytes as f64 / (1024.0 * 1024.0)
    );
    let mut rows: Vec<(String, usize, u64)> = by_ext
        .into_iter()
        .map(|(k, (c, b))| (k, c, b))
        .collect();
    rows.sort_by(|a, b| b.2.cmp(&a.2));
    for (ext, count, bytes) in rows.iter().take(12) {
        println!(
            "  .{:<8} {:>5} files  {:>8.2} MB",
            ext,
            count,
            *bytes as f64 / (1024.0 * 1024.0)
        );
    }
    Ok(())
}

pub fn compile_toml_to_lod(src_dir: &Path, out_dir: &Path) -> Result<()> {
    if !src_dir.is_dir() {
        bail!("TOML source directory does not exist: {}", src_dir.display());
    }
    let out_base = out_dir
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid output directory path")?;
    if out_base != "ForeverSuite_Data" {
        bail!(
            "Safety guard: --out basename MUST be 'ForeverSuite_Data' (got '{}')",
            out_base
        );
    }
    let canon_src = fs::canonicalize(src_dir)?;
    if out_dir.exists() {
        let canon_out = fs::canonicalize(out_dir)?;
        if canon_out == canon_src || canon_src.starts_with(&canon_out) || canon_out.starts_with(&canon_src) {
            bail!("Safety guard: --out must not overlap with --src");
        }
        let is_empty = fs::read_dir(out_dir)?.next().is_none();
        if !is_empty && !out_dir.join("ForeverSuite_Data.toc").is_file() {
            bail!(
                "Safety guard: refusing to replace non-empty directory without ForeverSuite_Data.toc: {}",
                out_dir.display()
            );
        }
    }

    let mut toml_files: Vec<_> = Vec::new();
    for entry in fs::read_dir(src_dir)
        .with_context(|| format!("Failed to read TOML dir {}", src_dir.display()))?
    {
        let entry = entry.with_context(|| format!("Dir entry error in {}", src_dir.display()))?;
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("toml") {
            toml_files.push(p);
        }
    }
    toml_files.sort();

    if toml_files.is_empty() {
        bail!("No .toml data files found in {}", src_dir.display());
    }

    let mut seen_ids = HashSet::new();
    let mut staged_outputs: Vec<(String, Vec<u8>)> = Vec::new();
    let mut lua_files = Vec::new();
    let mut provenance = Vec::new();

    let bootstrap_lua = "-- Auto-generated by fsx data compile (LoadOnDemand: 1)\n\
_G.ForeverSuiteData = _G.ForeverSuiteData or { version = \"2.0.0-alpha.1\", packs = {} }\n";
    staged_outputs.push(("DataBootstrap.lua".to_string(), bootstrap_lua.as_bytes().to_vec()));
    lua_files.push("DataBootstrap.lua".to_string());

    for path in &toml_files {
        let raw_bytes = fs::read(path)
            .with_context(|| format!("Failed to read {}", path.display()))?;
        let raw = String::from_utf8(raw_bytes.clone())
            .with_context(|| format!("Non-UTF-8 TOML file: {}", path.display()))?;
        let pack: PackSource = toml::from_str(&raw)
            .with_context(|| format!("Invalid TOML pack schema in {}", path.display()))?;

        if !is_valid_pack_id(&pack.pack.id) {
            bail!(
                "Invalid pack.id '{}' in {} (must match ^[a-z][a-z0-9_]{{0,31}}$)",
                pack.pack.id,
                path.display()
            );
        }
        if pack.pack.license.trim().is_empty() {
            bail!("Pack {} must declare non-empty pack.license", path.display());
        }
        if !seen_ids.insert(pack.pack.id.clone()) {
            bail!("Duplicate pack.id '{}' detected in {}", pack.pack.id, path.display());
        }

        let entries_val = toml::Value::Array(pack.entries.clone());
        let out_name = format!("Pack_{}.lua", pack.pack.id);
        let safe_source = sanitize_comment(&pack.pack.source);
        let safe_license = sanitize_comment(&pack.pack.license);
        let lua_out = format!(
            "-- Auto-generated by fsx data compile (Source: {} | License: {})\n\
local root = _G.ForeverSuiteData\n\
root.packs[{}] = {{\n\
    id = {},\n\
    title = {},\n\
    category = {},\n\
    license = {},\n\
    source = {},\n\
    entries = {},\n\
}}\n",
            safe_source,
            safe_license,
            lua_escape_string(&pack.pack.id),
            lua_escape_string(&pack.pack.id),
            lua_escape_string(&pack.pack.title),
            lua_escape_string(&pack.pack.category),
            lua_escape_string(&pack.pack.license),
            lua_escape_string(&pack.pack.source),
            toml_to_lua(&entries_val, 1),
        );

        full_moon::parse(&lua_out).map_err(|errs| {
            anyhow::anyhow!("Generated Lua syntax error for {}: {:?}", out_name, errs)
        })?;

        staged_outputs.push((out_name.clone(), lua_out.as_bytes().to_vec()));
        lua_files.push(out_name.clone());

        provenance.push(ProvenanceEntry {
            id: pack.pack.id,
            category: pack.pack.category,
            license: pack.pack.license,
            source: pack.pack.source,
            source_sha256: sha256_bytes(&raw_bytes),
            entry_count: pack.entries.len(),
            output_file: out_name,
            output_sha256: sha256_bytes(lua_out.as_bytes()),
        });
    }

    let mut toc = String::from(
        "## Interface: 16001, 120105\n\
## Title: |cffd4af37Forever|rSuite · Data (LoD)\n\
## Notes: ForeverSuite v2 LoadOnDemand 도감 데이터팩 (도감 열람 시에만 RAM 적재)\n\
## Author: Youngseo Cho\n\
## Version: 2.0.0-alpha.1\n\
## LoadOnDemand: 1\n\
## Dependencies: ForeverSuiteV2\n\n",
    );
    for f in &lua_files {
        toc.push_str(f);
        toc.push('\n');
    }
    staged_outputs.push(("ForeverSuite_Data.toc".to_string(), toc.into_bytes()));

    let manifest = ProvenanceManifest {
        generator: format!("fsx {}", env!("CARGO_PKG_VERSION")),
        packs: provenance,
    };
    let manifest_json = serde_json::to_string_pretty(&manifest)? + "\n";
    staged_outputs.push(("provenance.json".to_string(), manifest_json.into_bytes()));

    // Bundle-atomic directory swap: stage entire output dir, then swap atomically
    let parent = out_dir.parent().context("Invalid output directory path")?;
    fs::create_dir_all(parent)?;
    let base_name = out_dir
        .file_name()
        .and_then(|s| s.to_str())
        .context("Invalid output directory name")?;
    let pid = std::process::id();
    let stage_dir = parent.join(format!(".{base_name}.stage.{pid}"));
    let prev_dir = parent.join(format!(".{base_name}.prev.{pid}"));
    if stage_dir.exists() {
        fs::remove_dir_all(&stage_dir)?;
    }
    fs::create_dir_all(&stage_dir)?;

    let write_res: Result<()> = (|| {
        for (name, bytes) in &staged_outputs {
            fs::write(stage_dir.join(name), bytes)?;
        }
        Ok(())
    })();
    if let Err(err) = write_res {
        let _ = fs::remove_dir_all(&stage_dir);
        return Err(err);
    }

    let had_prev = out_dir.exists();
    if prev_dir.exists() {
        fs::remove_dir_all(&prev_dir)?;
    }
    if had_prev {
        fs::rename(out_dir, &prev_dir)?;
    }
    if let Err(err) = fs::rename(&stage_dir, out_dir) {
        if had_prev {
            let _ = fs::rename(&prev_dir, out_dir);
        }
        let _ = fs::remove_dir_all(&stage_dir);
        return Err(err.into());
    }
    if had_prev {
        let _ = fs::remove_dir_all(&prev_dir);
    }

    println!(
        "[OK] fsx data compile: {} LoD pack(s) generated atomically in {}",
        toml_files.len(),
        out_dir.display()
    );
    Ok(())
}

pub fn extract_gj_to_toml(zip_path: &Path, out_dir: &Path) -> Result<()> {
    let raw_zip = fs::read(zip_path)
        .with_context(|| format!("Failed to read ZIP: {}", zip_path.display()))?;
    let zip_sha = sha256_bytes(&raw_zip);

    let file = File::open(zip_path)?;
    let mut archive = ZipArchive::new(file)?;
    fs::create_dir_all(out_dir)?;

    let mut data_modules = Vec::new();
    let mut valid_count = 0usize;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let name = entry.name().to_string();
        if name.ends_with(".lua")
            && (name.starts_with("GodJohnsonBiSData/")
                || name.starts_with("GodJohnsonProfessionData/")
                || name.starts_with("GodJohnsonRewardData/")
                || name.starts_with("GodJohnsonAtlasData/"))
        {
            let mut raw = Vec::new();
            entry
                .read_to_end(&mut raw)
                .with_context(|| format!("Failed to read ZIP entry '{name}'"))?;
            let text = String::from_utf8(raw)
                .with_context(|| format!("ZIP entry '{name}' is not valid UTF-8"))?;
            let lua = Lua::new();
            let parse_ok = lua.load(&text).into_function().is_ok();
            if parse_ok {
                valid_count += 1;
            }
            let mut tbl = toml::map::Map::new();
            tbl.insert("source_path".to_string(), toml::Value::String(name));
            tbl.insert("bytes".to_string(), toml::Value::Integer(text.len() as i64));
            tbl.insert("lua51_valid".to_string(), toml::Value::Boolean(parse_ok));
            data_modules.push(toml::Value::Table(tbl));
        }
    }

    let catalog = PackSource {
        pack: PackMeta {
            id: "gj_catalog".to_string(),
            title: "GodJohnson Build-Time Extracted Inventory".to_string(),
            category: "provenance".to_string(),
            license: "GPL-3.0-personal-local-only".to_string(),
            source: zip_path
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("GodJohnson.zip")
                .to_string(),
            source_sha256: zip_sha,
        },
        entries: data_modules,
    };

    let toml_text = toml::to_string_pretty(&catalog)?;
    let out_file = out_dir.join("gj_catalog.toml");
    write_file_atomic(&out_file, toml_text.as_bytes())?;
    println!(
        "[OK] fsx data extract-gj: wrote {} ({}/{} Lua 5.1 valid GJ data modules)",
        out_file.display(),
        valid_count,
        catalog.entries.len()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn compiles_toml_pack_and_blocks_bad_id_or_comment_injection() -> Result<()> {
        let dir = tempdir()?;
        let src = dir.path().join("src");
        let out = dir.path().join("ForeverSuite_Data");
        fs::create_dir_all(&src)?;

        fs::write(
            src.join("fishing.toml"),
            r#"
[pack]
id = "fishing"
title = "낚시 대상어 가이드"
category = "profession"
license = "MIT-Personal\nprint('pwned')"
source = "ForeverSuite Curated"

[[entries]]
title = "돌비늘 뱀장어"
zone = "불모의 땅"
minSkill = 75
"#,
        )?;

        compile_toml_to_lod(&src, &out)?;
        let lua_txt = fs::read_to_string(out.join("Pack_fishing.lua"))?;
        assert!(!lua_txt.lines().any(|l| l.trim_start().starts_with("print(")));

        // Path-traversal pack.id must fail closed
        fs::write(
            src.join("bad.toml"),
            "[pack]\nid = \"../escape\"\ntitle = \"x\"\ncategory = \"x\"\nlicense = \"MIT\"\nsource = \"x\"\n",
        )?;
        assert!(compile_toml_to_lod(&src, &out).is_err());
        fs::remove_file(src.join("bad.toml"))?;

        // Duplicate pack.id must fail closed
        fs::write(
            src.join("dup.toml"),
            "[pack]\nid = \"fishing\"\ntitle = \"dup\"\ncategory = \"x\"\nlicense = \"MIT\"\nsource = \"x\"\n",
        )?;
        assert!(compile_toml_to_lod(&src, &out).is_err());
        Ok(())
    }
}

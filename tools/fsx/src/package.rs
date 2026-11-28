use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::Path;
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

const CURATED_FONTS: &[&str] = &[
    "GmarketSansTTFBold.ttf",
    "GothicA1-Black.ttf",
    "font03.ttf",
    "font10.ttf",
];

const CURATED_NOTIFICATIONS: &[&str] = &[
    "dingdong_75.ogg",
    "oishii_high_75.ogg",
    "victory_75.ogg",
    "cash_75.wav",
];

const EXTENDED_DATA_SUBADDONS: &[&str] = &[
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
];

fn is_forbidden_rel_path(rel: &str) -> bool {
    let lower = rel.to_ascii_lowercase();
    for seg in lower.split('/') {
        if matches!(
            seg,
            "private" | "foreversuite_dev" | ".git" | ".ds_store" | "thumbs.db"
        ) {
            return true;
        }
    }
    false
}

fn collect_tree(
    src_dir: &Path,
    archive_prefix: &str,
    entries: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    for entry in WalkDir::new(src_dir) {
        let entry = entry.with_context(|| format!("Walk error in {}", src_dir.display()))?;
        if entry.path_is_symlink() {
            bail!(
                "Symlink rejected during packaging: {}",
                entry.path().display()
            );
        }
        let rel = entry
            .path()
            .strip_prefix(src_dir)?
            .to_string_lossy()
            .replace('\\', "/");
        if !rel.is_empty() && is_forbidden_rel_path(&rel) {
            bail!(
                "Forbidden Private/Dev artifact detected in source tree: {}/{}",
                archive_prefix,
                rel
            );
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let key = format!("{archive_prefix}/{rel}");
        entries.insert(key, fs::read(entry.path())?);
    }
    Ok(())
}

fn build_base_data_entries(
    source_root: &Path,
    version: &str,
    entries: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    let base_data = source_root.join("ForeverSuite_Data");
    if !base_data.is_dir() {
        bail!("Missing ForeverSuite_Data in {}", source_root.display());
    }
    let mut toc_files: Vec<String> = Vec::new();
    let base_toc = parse_toc(&base_data)?;
    for rel in &base_toc.files {
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        if is_forbidden_rel_path(&rel_str) {
            bail!("Forbidden path in ForeverSuite_Data: {rel_str}");
        }
        let full = base_data.join(rel);
        if full.is_symlink() || !full.is_file() {
            bail!("Missing or symlinked ForeverSuite_Data file: {rel_str}");
        }
        entries.insert(format!("ForeverSuite_Data/{rel_str}"), fs::read(&full)?);
        toc_files.push(rel_str);
    }

    let mut toc_content = format!(
        "## Interface: 16001, 120105\n\
         ## Title: |cffd4af37Forever|rSuite · Base Data (LoD)\n\
         ## Notes: ForeverSuite 기본 LoadOnDemand 데이터팩 (확장 도감은 ForeverSuite-DataPack 별도 설치)\n\
         ## Author: Youngseo Cho\n\
         ## Version: {version}\n\
         ## LoadOnDemand: 1\n\
         ## Dependencies: ForeverSuite\n\n"
    );
    for f in toc_files {
        toc_content.push_str(&f);
        toc_content.push('\n');
    }
    entries.insert(
        "ForeverSuite_Data/ForeverSuite_Data.toc".to_string(),
        toc_content.into_bytes(),
    );
    Ok(())
}

fn stamp_toc_version(raw_toc: &str, version: &str) -> String {
    let clean = raw_toc.strip_prefix('\u{feff}').unwrap_or(raw_toc);
    let mut stamped_lines: Vec<String> = Vec::new();
    let mut had_version = false;
    let mut header_end_idx = 0usize;
    let mut in_header = true;
    for line in clean.lines() {
        let trimmed = line.trim_start();
        let is_directive = trimmed.starts_with("##");
        if in_header && is_directive {
            header_end_idx = stamped_lines.len() + 1;
        } else if in_header && !trimmed.is_empty() {
            in_header = false;
        }
        let is_version = trimmed
            .strip_prefix("##")
            .map(|rest| rest.trim_start().to_ascii_lowercase().starts_with("version:"))
            .unwrap_or(false);
        if is_version {
            if !had_version {
                stamped_lines.push(format!("## Version: {version}"));
                had_version = true;
            }
        } else {
            stamped_lines.push(line.to_string());
        }
    }
    if !had_version {
        stamped_lines.insert(header_end_idx, format!("## Version: {version}"));
    }
    let mut stamped = stamped_lines.join("\n");
    stamped.push('\n');
    stamped
}

fn build_datapack_addon_entries(
    source_root: &Path,
    version: &str,
    entries: &mut BTreeMap<String, Vec<u8>>,
) -> Result<usize> {
    let mut pack_count = 0usize;
    for sub in EXTENDED_DATA_SUBADDONS {
        let sub_dir = source_root.join(sub);
        if !sub_dir.is_dir() {
            continue;
        }
        let toc_path = sub_dir.join(format!("{sub}.toc"));
        if toc_path.is_symlink() || !toc_path.is_file() {
            bail!("Missing or symlinked DataPack TOC: {sub}/{sub}.toc");
        }
        let sub_toc = parse_toc(&sub_dir)?;
        for rel in &sub_toc.files {
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            if is_forbidden_rel_path(&rel_str) {
                bail!("Forbidden path in {sub}: {rel_str}");
            }
            let full = sub_dir.join(rel);
            if full.is_symlink() || !full.is_file() {
                bail!("Missing or symlinked DataPack file: {sub}/{rel_str}");
            }
            entries.insert(format!("{sub}/{rel_str}"), fs::read(&full)?);
        }
        let raw_toc = fs::read_to_string(&toc_path)
            .with_context(|| format!("Failed reading {sub}.toc"))?;
        let stamped = stamp_toc_version(&raw_toc, version);
        entries.insert(format!("{sub}/{sub}.toc"), stamped.into_bytes());
        pack_count += 1;
    }
    Ok(pack_count)
}

fn build_consolidated_media_entries(
    source_root: &Path,
    entries: &mut BTreeMap<String, Vec<u8>>,
) -> Result<()> {
    let base_media = source_root.join("ForeverSuite_Media");
    if !base_media.is_dir() {
        bail!("Missing ForeverSuite_Media in {}", source_root.display());
    }
    collect_tree(&base_media, "ForeverSuite_Media", entries)?;

    let assets = source_root.join("ForeverSuite_Media_Assets");
    if assets.is_symlink() {
        bail!(
            "Symlinked ForeverSuite_Media_Assets directory is forbidden in {}",
            source_root.display()
        );
    }
    if assets.is_dir() {
        // 1. Essential UI, Bespoke RPG Icons & 3D Arrow TGA art kit
        for sub in ["UI", "Icons", "Arrows"] {
            let sub_path = assets.join(sub);
            if sub_path.is_dir() {
                collect_tree(&sub_path, &format!("ForeverSuite_Media/{sub}"), entries)?;
            }
        }
        // 2. Curated 4 Korean/Mono fonts (<= 6MB instead of 61MB)
        let fonts_dir = assets.join("Fonts");
        if fonts_dir.is_dir() {
            for font in CURATED_FONTS {
                let fp = fonts_dir.join(font);
                if fp.is_file() && !fp.is_symlink() {
                    entries.insert(format!("ForeverSuite_Media/Fonts/{font}"), fs::read(&fp)?);
                }
            }
        }
        // 3. Curated UI-selectable notification sounds (fail-closed exact match to Bootstrap alertSoundKey options)
        let notif_dir = assets.join("Notifications");
        if !notif_dir.is_dir() || notif_dir.is_symlink() {
            bail!(
                "Missing or symlinked ForeverSuite_Media_Assets/Notifications directory in {}",
                source_root.display()
            );
        }
        for name in CURATED_NOTIFICATIONS {
            let p = notif_dir.join(name);
            if p.is_symlink() || !p.is_file() {
                bail!("Missing or symlinked curated notification sound: {name}");
            }
            entries.insert(
                format!("ForeverSuite_Media/Notifications/{name}"),
                fs::read(&p)?,
            );
        }
    }
    // Final source-agnostic fail-closed guarantee: all 4 curated notification sounds MUST be present
    for name in CURATED_NOTIFICATIONS {
        if !entries.contains_key(&format!("ForeverSuite_Media/Notifications/{name}")) {
            bail!("Curated notification sound missing from final Core package: {name}");
        }
    }
    Ok(())
}

fn write_verified_zip(
    out_dir: &Path,
    zip_name: &str,
    label: &str,
    entries: &BTreeMap<String, Vec<u8>>,
    max_mb: u64,
) -> Result<()> {
    let total_uncompressed: u64 = entries.values().map(|b| b.len() as u64).sum();
    let max_bytes = max_mb * 1024 * 1024;
    if total_uncompressed > max_bytes {
        bail!(
            "{label} hard cap exceeded: {:.2} MB uncompressed > {} MB limit",
            total_uncompressed as f64 / (1024.0 * 1024.0),
            max_mb
        );
    }

    fs::create_dir_all(out_dir)?;
    let zip_path = out_dir.join(zip_name);
    let tmp_zip = out_dir.join(format!(".{zip_name}.tmp"));

    {
        let file = File::create(&tmp_zip)?;
        let mut zw = ZipWriter::new(file);
        let deflate_opts =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        let stored_opts =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (rel, bytes) in entries {
            let opts = if rel.to_ascii_lowercase().ends_with(".ogg") {
                stored_opts
            } else {
                deflate_opts
            };
            zw.start_file(rel, opts)?;
            zw.write_all(bytes)?;
        }
        zw.finish()?;
    }

    // Re-open & verify ZIP integrity, exact entry count, and CRC32 decompression of EVERY entry
    let verify_file = File::open(&tmp_zip)?;
    let mut archive = zip::ZipArchive::new(verify_file)?;
    if archive.len() != entries.len() {
        let _ = fs::remove_file(&tmp_zip);
        bail!(
            "{label} ZIP entry count mismatch: expected {}, verified {}",
            entries.len(),
            archive.len()
        );
    }
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        std::io::copy(&mut entry, &mut std::io::sink()).with_context(|| {
            format!("{label} ZIP CRC/decompression verification failed for entry #{i}")
        })?;
    }

    let zip_bytes = fs::read(&tmp_zip)?;
    let mut hasher = Sha256::new();
    hasher.update(&zip_bytes);
    let sha_hex = format!("{:x}", hasher.finalize());

    fs::rename(&tmp_zip, &zip_path)?;
    let sha_path = out_dir.join(format!("{zip_name}.sha256"));
    let tmp_sha = out_dir.join(format!(".{zip_name}.sha256.tmp"));
    fs::write(&tmp_sha, format!("{sha_hex}  {zip_name}\n"))?;
    fs::rename(&tmp_sha, &sha_path)?;

    println!(
        "[OK] fsx package built {label}: {} ({} files, {:.2} MB raw / {:.2} MB zip, sha256={})",
        zip_path.display(),
        entries.len(),
        total_uncompressed as f64 / (1024.0 * 1024.0),
        zip_bytes.len() as f64 / (1024.0 * 1024.0),
        &sha_hex[..16]
    );
    Ok(())
}

pub fn run_package(
    source_root: &Path,
    out_dir: &Path,
    tag: Option<&str>,
    max_mb: u64,
    datapack_max_mb: u64,
) -> Result<()> {
    let core_dir = source_root.join("ForeverSuite");
    if !core_dir.is_dir() {
        bail!(
            "Core ForeverSuite addon directory not found in {}",
            source_root.display()
        );
    }
    // Fail-closed check: reject any Private/ folder inside source_root
    if source_root.join("Private").exists() || core_dir.join("Private").exists() {
        bail!("Forbidden Private/ directory detected inside package source");
    }

    let core_toc = parse_toc(&core_dir)?;
    if !core_toc.interfaces.iter().any(|i| i == "16001") {
        bail!(
            "Core ForeverSuite.toc missing required Interface 16001 (found: {:?})",
            core_toc.interfaces
        );
    }
    let version = core_toc
        .version
        .clone()
        .context("Core ForeverSuite.toc missing '## Version:' header")?;

    if let Some(raw_tag) = tag {
        let stripped = raw_tag.strip_prefix('v').unwrap_or(raw_tag);
        if stripped != version {
            bail!(
                "Release tag mismatch: tag='{}' (ver='{}') != ForeverSuite.toc Version='{}'",
                raw_tag,
                stripped,
                version
            );
        }
    }

    // 1. Core 3-folder archive (ForeverSuite + self-authored base ForeverSuite_Data + ForeverSuite_Media)
    let mut core_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    collect_tree(&core_dir, "ForeverSuite", &mut core_entries)?;
    build_base_data_entries(source_root, &version, &mut core_entries)?;
    build_consolidated_media_entries(source_root, &mut core_entries)?;
    write_verified_zip(
        out_dir,
        &format!("ForeverSuite-v{version}.zip"),
        "Core 3-folder archive",
        &core_entries,
        max_mb,
    )?;

    // 2. Separate optional Extended DataPack archive (10 LoD ForeverSuite_Data_* addon folders)
    let mut datapack_entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    let pack_count = build_datapack_addon_entries(source_root, &version, &mut datapack_entries)?;
    if pack_count > 0 {
        write_verified_zip(
            out_dir,
            &format!("ForeverSuite-DataPack-v{version}.zip"),
            &format!("DataPack {pack_count}-folder archive"),
            &datapack_entries,
            datapack_max_mb,
        )?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;
    use tempfile::tempdir;

    fn seed_minimal_v2(root: &Path, ver: &str) -> Result<()> {
        fs::create_dir_all(root.join("ForeverSuite"))?;
        fs::write(
            root.join("ForeverSuite/ForeverSuite.toc"),
            format!("## Interface: 16001\n## Version: {ver}\nInit.lua\n"),
        )?;
        fs::write(root.join("ForeverSuite/Init.lua"), "local x = 1\n")?;

        fs::create_dir_all(root.join("ForeverSuite_Data"))?;
        fs::write(
            root.join("ForeverSuite_Data/ForeverSuite_Data.toc"),
            "## Interface: 16001\n## LoadOnDemand: 1\nmanifest.lua\n",
        )?;
        fs::write(root.join("ForeverSuite_Data/manifest.lua"), "return {}\n")?;

        fs::create_dir_all(root.join("ForeverSuite_Data_Dungeon"))?;
        fs::write(
            root.join("ForeverSuite_Data_Dungeon/ForeverSuite_Data_Dungeon.toc"),
            "## Interface: 16001\n## LoadOnDemand: 1\nPack_d.lua\n",
        )?;
        fs::write(
            root.join("ForeverSuite_Data_Dungeon/Pack_d.lua"),
            "-- shard\n",
        )?;

        fs::create_dir_all(root.join("ForeverSuite_Media"))?;
        fs::write(
            root.join("ForeverSuite_Media/ForeverSuite_Media.toc"),
            "## Interface: 16001\nMedia.lua\n",
        )?;
        fs::write(root.join("ForeverSuite_Media/Media.lua"), "return {}\n")?;

        fs::create_dir_all(root.join("ForeverSuite_Media_Assets/Icons"))?;
        fs::write(
            root.join("ForeverSuite_Media_Assets/Icons/FS-Icon-Fallback.tga"),
            vec![0u8; 32],
        )?;
        fs::create_dir_all(root.join("ForeverSuite_Media_Assets/Notifications"))?;
        for snd in CURATED_NOTIFICATIONS {
            fs::write(
                root.join(format!("ForeverSuite_Media_Assets/Notifications/{snd}")),
                vec![1u8; 16],
            )?;
        }
        Ok(())
    }

    #[test]
    fn package_builds_3_folder_zip_and_enforces_tag_cap_and_private_guards() -> Result<()> {
        let dir = tempdir()?;
        let src = dir.path().join("v2");
        let out = dir.path().join("dist");
        seed_minimal_v2(&src, "6.2.0")?;

        // 1. Tag mismatch rejected fail-closed
        assert!(run_package(&src, &out, Some("v5.0.0"), 18, 30).is_err());

        // 2. Matching tag builds BOTH Core 3-folder ZIP + separate DataPack ZIP (+ SHA-256)
        run_package(&src, &out, Some("v6.2.0"), 18, 30)?;
        let zip_path = out.join("ForeverSuite-v6.2.0.zip");
        let sha_path = out.join("ForeverSuite-v6.2.0.zip.sha256");
        let dp_zip_path = out.join("ForeverSuite-DataPack-v6.2.0.zip");
        let dp_sha_path = out.join("ForeverSuite-DataPack-v6.2.0.zip.sha256");
        assert!(zip_path.is_file());
        assert!(sha_path.is_file());
        assert!(dp_zip_path.is_file());
        assert!(dp_sha_path.is_file());

        let f = File::open(&zip_path)?;
        let mut ar = zip::ZipArchive::new(f)?;
        let mut top_dirs = HashSet::new();
        let mut has_shard_in_core = false;
        let mut has_icon = false;
        let mut notif_count = 0usize;
        for i in 0..ar.len() {
            let name = ar.by_index(i)?.name().to_string();
            if let Some(first) = name.split('/').next() {
                top_dirs.insert(first.to_string());
            }
            if name.contains("Shards/") {
                has_shard_in_core = true;
            }
            if name == "ForeverSuite_Media/Icons/FS-Icon-Fallback.tga" {
                has_icon = true;
            }
            if name.starts_with("ForeverSuite_Media/Notifications/") {
                notif_count += 1;
            }
        }
        assert_eq!(top_dirs.len(), 3, "Core ZIP must emit exactly 3 top-level folders: {top_dirs:?}");
        assert!(top_dirs.contains("ForeverSuite"));
        assert!(top_dirs.contains("ForeverSuite_Data"));
        assert!(top_dirs.contains("ForeverSuite_Media"));
        assert!(!has_shard_in_core, "Core ZIP must stay lightweight without split DataPack shards");
        assert!(has_icon, "bespoke RPG icons must be consolidated into ForeverSuite_Media/Icons/");
        assert_eq!(notif_count, CURATED_NOTIFICATIONS.len(), "All 4 UI notification sounds must be included");

        let df = File::open(&dp_zip_path)?;
        let mut dar = zip::ZipArchive::new(df)?;
        let mut has_dp_shard = false;
        let mut dp_toc_text = String::new();
        for i in 0..dar.len() {
            let mut entry = dar.by_index(i)?;
            let name = entry.name().to_string();
            if name == "ForeverSuite_Data_Dungeon/Pack_d.lua" {
                has_dp_shard = true;
            }
            if name == "ForeverSuite_Data_Dungeon/ForeverSuite_Data_Dungeon.toc" {
                std::io::Read::read_to_string(&mut entry, &mut dp_toc_text)?;
            }
        }
        assert!(has_dp_shard && !dp_toc_text.is_empty(), "DataPack ZIP must include LoD ForeverSuite_Data_* folders with .toc");
        let ver_pos = dp_toc_text.find("## Version: 6.2.0").expect("DataPack TOC must be version-stamped");
        let file_pos = dp_toc_text.find("Pack_d.lua").expect("DataPack TOC must list Pack_d.lua");
        assert!(ver_pos < file_pos, "Stamped ## Version header must appear before file entries");

        // 3. Missing curated notification sound OR absent Media_Assets rejected fail-closed
        let missing_snd = src.join("ForeverSuite_Media_Assets/Notifications/victory_75.ogg");
        fs::remove_file(&missing_snd)?;
        assert!(run_package(&src, &out, Some("v6.2.0"), 18, 30).is_err());
        fs::write(&missing_snd, vec![1u8; 16])?;

        let assets_dir = src.join("ForeverSuite_Media_Assets");
        let assets_backup = dir.path().join("assets_backup");
        fs::rename(&assets_dir, &assets_backup)?;
        assert!(run_package(&src, &out, Some("v6.2.0"), 18, 30).is_err());
        fs::rename(&assets_backup, &assets_dir)?;

        // 4. Core hard cap overflow rejected fail-closed (differential: passes at 18MB, fails at 1MB)
        let core_big = src.join("ForeverSuite_Media/big.bin");
        fs::write(&core_big, vec![0u8; 2 * 1024 * 1024])?;
        assert!(run_package(&src, &out, Some("v6.2.0"), 18, 30).is_ok());
        assert!(run_package(&src, &out, Some("v6.2.0"), 1, 30).is_err());
        fs::remove_file(&core_big)?;

        // 5. DataPack hard cap overflow rejected fail-closed
        fs::write(
            src.join("ForeverSuite_Data_Dungeon/Pack_d.lua"),
            vec![b'a'; 2 * 1024 * 1024],
        )?;
        assert!(run_package(&src, &out, Some("v6.2.0"), 18, 1).is_err());

        // 6. Private/ leak rejected fail-closed
        fs::create_dir_all(src.join("ForeverSuite/Private"))?;
        fs::write(src.join("ForeverSuite/Private/secret.txt"), "leak")?;
        assert!(run_package(&src, &out, Some("v6.2.0"), 18, 30).is_err());
        Ok(())
    }
}

use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

const CURATED_FONTS: &[&str] = &[
    "GmarketSansTTFBold.ttf",
    "GothicA1-Black.ttf",
    "font03.ttf",
    "font10.ttf",
];

const CONSOLIDATED_DATA_SUBADDONS: &[&str] = &[
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

fn build_consolidated_data_entries(
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
        let full = base_data.join(rel);
        if full.is_symlink() || !full.is_file() {
            bail!("Missing or symlinked ForeverSuite_Data file: {rel_str}");
        }
        entries.insert(format!("ForeverSuite_Data/{rel_str}"), fs::read(&full)?);
        toc_files.push(rel_str);
    }

    // Consolidate split ForeverSuite_Data_* shard Lua files into unified ForeverSuite_Data/Shards/
    for sub in CONSOLIDATED_DATA_SUBADDONS {
        let sub_dir = source_root.join(sub);
        if !sub_dir.is_dir() {
            continue;
        }
        let sub_toc = parse_toc(&sub_dir)?;
        for rel in &sub_toc.files {
            let rel_str = rel.to_string_lossy().replace('\\', "/");
            if is_forbidden_rel_path(&rel_str) {
                bail!("Forbidden path in {sub}: {rel_str}");
            }
            let full = sub_dir.join(rel);
            if full.is_symlink() || !full.is_file() {
                bail!("Missing or symlinked shard file: {sub}/{rel_str}");
            }
            let dst_rel = format!("Shards/{sub}_{rel_str}");
            entries.insert(format!("ForeverSuite_Data/{dst_rel}"), fs::read(&full)?);
            toc_files.push(dst_rel);
        }
    }

    let mut toc_content = format!(
        "## Interface: 16001, 120105\n\
         ## Title: |cffd4af37Forever|rSuite · Data (LoD)\n\
         ## Notes: ForeverSuite v6 통합 LoadOnDemand 도감 데이터팩 (0팩 삭제 시에도 코어 100% 기동)\n\
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
    if assets.is_dir() {
        // 1. Essential RLE-compressed UI & 3D Arrow TGA art kit
        for sub in ["UI", "Arrows"] {
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
        // 3. Up to 6 core .ogg notification sounds (built-in SoundKitID handles the rest at 0KB)
        let notif_dir = assets.join("Notifications");
        if notif_dir.is_dir() {
            let mut oggs: Vec<PathBuf> = fs::read_dir(&notif_dir)?
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.is_file()
                        && !p.is_symlink()
                        && p.extension().and_then(|s| s.to_str()) == Some("ogg")
                        && p.file_name()
                            .and_then(|s| s.to_str())
                            .map(|n| n.ends_with("_75.ogg"))
                            .unwrap_or(false)
                })
                .collect();
            oggs.sort();
            for p in oggs.into_iter().take(6) {
                if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                    entries.insert(
                        format!("ForeverSuite_Media/Notifications/{name}"),
                        fs::read(&p)?,
                    );
                }
            }
        }
    }
    Ok(())
}

pub fn run_package(
    source_root: &Path,
    out_dir: &Path,
    tag: Option<&str>,
    max_mb: u64,
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

    let mut entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    collect_tree(&core_dir, "ForeverSuite", &mut entries)?;
    build_consolidated_data_entries(source_root, &version, &mut entries)?;
    build_consolidated_media_entries(source_root, &mut entries)?;

    let total_uncompressed: u64 = entries.values().map(|b| b.len() as u64).sum();
    let max_bytes = max_mb * 1024 * 1024;
    if total_uncompressed > max_bytes {
        bail!(
            "Package hard cap exceeded: {:.2} MB uncompressed > {} MB limit",
            total_uncompressed as f64 / (1024.0 * 1024.0),
            max_mb
        );
    }

    fs::create_dir_all(out_dir)?;
    let zip_name = format!("ForeverSuite-v{version}.zip");
    let zip_path = out_dir.join(&zip_name);
    let tmp_zip = out_dir.join(format!(".{zip_name}.tmp"));

    {
        let file = File::create(&tmp_zip)?;
        let mut zw = ZipWriter::new(file);
        let deflate_opts =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        let stored_opts =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (rel, bytes) in &entries {
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
            "Package ZIP entry count mismatch: expected {}, verified {}",
            entries.len(),
            archive.len()
        );
    }
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        std::io::copy(&mut entry, &mut std::io::sink()).with_context(|| {
            format!("Package ZIP CRC/decompression verification failed for entry #{i}")
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
        "[OK] fsx package built 3-folder archive: {} ({} files, {:.2} MB raw / {:.2} MB zip, sha256={})",
        zip_path.display(),
        entries.len(),
        total_uncompressed as f64 / (1024.0 * 1024.0),
        zip_bytes.len() as f64 / (1024.0 * 1024.0),
        &sha_hex[..16]
    );
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
        Ok(())
    }

    #[test]
    fn package_builds_3_folder_zip_and_enforces_tag_cap_and_private_guards() -> Result<()> {
        let dir = tempdir()?;
        let src = dir.path().join("v2");
        let out = dir.path().join("dist");
        seed_minimal_v2(&src, "6.0.0")?;

        // 1. Tag mismatch rejected fail-closed
        assert!(run_package(&src, &out, Some("v5.0.0"), 18).is_err());

        // 2. Matching tag builds verified 3-folder ZIP + SHA-256
        run_package(&src, &out, Some("v6.0.0"), 18)?;
        let zip_path = out.join("ForeverSuite-v6.0.0.zip");
        let sha_path = out.join("ForeverSuite-v6.0.0.zip.sha256");
        assert!(zip_path.is_file());
        assert!(sha_path.is_file());

        let f = File::open(&zip_path)?;
        let mut ar = zip::ZipArchive::new(f)?;
        let mut top_dirs = HashSet::new();
        let mut has_shard = false;
        for i in 0..ar.len() {
            let name = ar.by_index(i)?.name().to_string();
            if let Some(first) = name.split('/').next() {
                top_dirs.insert(first.to_string());
            }
            if name.contains("Shards/ForeverSuite_Data_Dungeon_Pack_d.lua") {
                has_shard = true;
            }
        }
        assert_eq!(top_dirs.len(), 3, "must emit exactly 3 top-level folders: {top_dirs:?}");
        assert!(top_dirs.contains("ForeverSuite"));
        assert!(top_dirs.contains("ForeverSuite_Data"));
        assert!(top_dirs.contains("ForeverSuite_Media"));
        assert!(has_shard, "split data shard must be consolidated into ForeverSuite_Data/Shards/");

        // 3. Hard cap overflow rejected fail-closed
        fs::write(src.join("ForeverSuite_Media/big.bin"), vec![0u8; 2 * 1024 * 1024])?;
        assert!(run_package(&src, &out, Some("v6.0.0"), 1).is_err());

        // 4. Private/ leak rejected fail-closed
        fs::create_dir_all(src.join("ForeverSuite/Private"))?;
        fs::write(src.join("ForeverSuite/Private/secret.txt"), "leak")?;
        assert!(run_package(&src, &out, Some("v6.0.0"), 18).is_err());
        Ok(())
    }
}

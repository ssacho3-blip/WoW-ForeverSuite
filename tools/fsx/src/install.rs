use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static INSTALL_SEQ: AtomicU64 = AtomicU64::new(1);
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

const V2_ADDON_FOLDERS: &[&str] = &["ForeverSuite", "ForeverSuite_Media", "ForeverSuite_Data"];
const OPTIONAL_LOD_DATA_FOLDERS: &[&str] = &[
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
    "ForeverSuite_Media_Assets",
    "ForeverSuite_Fonts_Global",
];

fn is_legacy_addon_folder(name: &str) -> bool {
    name == "ForeverSuiteV2" || name == "ForeverSuite_GJBridge" || name.starts_with("GodJohnson")
}

fn find_legacy_folders(addons_dir: &Path) -> Result<Vec<String>> {
    let mut found = Vec::new();
    for entry in fs::read_dir(addons_dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        if let Some(name) = entry.file_name().to_str() {
            if is_legacy_addon_folder(name) {
                found.push(name.to_string());
            }
        }
    }
    found.sort();
    Ok(found)
}

fn archive_legacy_folders(
    addons_dir: &Path,
    legacy_names: &[String],
    backup_parent: &Path,
    ts: u64,
) -> Result<PathBuf> {
    fs::create_dir_all(backup_parent)?;
    let zip_path = backup_parent.join(format!("Legacy_addons_backup_{ts}.zip"));
    let tmp_zip = backup_parent.join(format!(".Legacy_addons_backup_{ts}.tmp.zip"));
    let file = File::create(&tmp_zip)?;
    let mut zw = ZipWriter::new(file);
    let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    let mut archived_files: usize = 0;
    for name in legacy_names {
        let dir = addons_dir.join(name);
        for entry in WalkDir::new(&dir) {
            let entry = entry
                .with_context(|| format!("Walk error archiving legacy addon {}", dir.display()))?;
            if entry.path_is_symlink() {
                bail!("Symlink rejected in legacy archive: {}", entry.path().display());
            }
            if !entry.file_type().is_file() {
                continue;
            }
            let rel = entry
                .path()
                .strip_prefix(addons_dir)?
                .to_string_lossy()
                .replace('\\', "/");
            zw.start_file(rel, opts)?;
            zw.write_all(&fs::read(entry.path())?)?;
            archived_files += 1;
        }
    }
    zw.finish()?;
    fs::rename(&tmp_zip, &zip_path)?;

    // N1: Verify archive integrity and exact file count before caller deletes any legacy folder
    let verify_file = File::open(&zip_path)
        .with_context(|| format!("Failed to reopen archive for verification: {}", zip_path.display()))?;
    let archive = zip::ZipArchive::new(verify_file)
        .with_context(|| format!("Corrupt legacy backup archive: {}", zip_path.display()))?;
    if archive.len() != archived_files {
        bail!(
            "Legacy archive entry count mismatch: expected {}, verified {}",
            archived_files,
            archive.len()
        );
    }
    Ok(zip_path)
}

/// Idempotently merges ForeverSuiteV2.lua into ForeverSuite.lua across all account/character
/// SavedVariables directories under WTF so preview settings, ledger, and protected items survive
/// the ForeverSuiteV2 -> ForeverSuite promotion while preserving legacy ForeverSuiteDB.
fn migrate_saved_variables(wtf_dir: &Path) -> Result<usize> {
    let mut migrated_count = 0usize;
    for entry in WalkDir::new(wtf_dir) {
        let entry = entry.with_context(|| format!("Walk error scanning WTF {}", wtf_dir.display()))?;
        if entry.path_is_symlink() || !entry.file_type().is_file() {
            continue;
        }
        if entry.file_name().to_str() != Some("ForeverSuiteV2.lua") {
            continue;
        }
        let Some(parent) = entry.path().parent() else {
            continue;
        };
        if parent.file_name().and_then(|s| s.to_str()) != Some("SavedVariables") {
            continue;
        }
        let v2_src = fs::read_to_string(entry.path())
            .with_context(|| format!("Failed to read {}", entry.path().display()))?;
        if v2_src.trim().is_empty() {
            continue;
        }
        let target = parent.join("ForeverSuite.lua");
        let tmp_target = parent.join(".ForeverSuite.lua.fsx.tmp");
        let merged = if target.is_file() {
            let existing = fs::read_to_string(&target)
                .with_context(|| format!("Failed to read {}", target.display()))?;
            if existing.contains("ForeverSuiteV2DB") || existing.contains("ForeverSuiteV2CharDB") {
                continue;
            }
            format!(
                "{}\n\n-- Migrated from ForeverSuiteV2.lua by fsx\n{}\n",
                existing.trim_end(),
                v2_src.trim()
            )
        } else {
            v2_src
        };
        fs::write(&tmp_target, merged.as_bytes())?;
        fs::rename(&tmp_target, &target)?;
        migrated_count += 1;
    }
    Ok(migrated_count)
}

fn compute_dir_sha256(dir: &Path) -> Result<String> {
    let mut entries: BTreeMap<String, Vec<u8>> = BTreeMap::new();
    for item in WalkDir::new(dir) {
        let item = item.with_context(|| format!("Walk error hashing {}", dir.display()))?;
        if item.path_is_symlink() {
            bail!(
                "Symlink rejected during SHA-256 verification: {}",
                item.path().display()
            );
        }
        if !item.file_type().is_file() {
            continue;
        }
        let rel = item
            .path()
            .strip_prefix(dir)?
            .to_string_lossy()
            .replace('\\', "/");
        entries.insert(rel, fs::read(item.path())?);
    }
    let mut hasher = Sha256::new();
    for (rel, bytes) in entries {
        hasher.update(rel.as_bytes());
        hasher.update([0u8]);
        hasher.update(&bytes);
        hasher.update([0u8]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> Result<()> {
    fs::create_dir_all(dst)?;
    for entry in WalkDir::new(src) {
        let entry = entry.with_context(|| format!("Walk error copying {}", src.display()))?;
        if entry.path_is_symlink() {
            bail!(
                "Symlink rejected during staging copy: {}",
                entry.path().display()
            );
        }
        let rel = entry.path().strip_prefix(src)?;
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(entry.path(), &target)?;
        }
    }
    Ok(())
}

fn backup_wtf_dir(wtf_dir: &Path, backup_parent: &Path, ts: u64) -> Result<PathBuf> {
    if !wtf_dir.is_dir() {
        bail!(
            "WTF directory not found for pre-deploy backup: {}",
            wtf_dir.display()
        );
    }
    fs::create_dir_all(backup_parent)?;
    let zip_path = backup_parent.join(format!("WTF_backup_{ts}.zip"));
    let tmp_zip = backup_parent.join(format!(".WTF_backup_{ts}.tmp.zip"));
    let file = File::create(&tmp_zip)?;
    let mut zw = ZipWriter::new(file);
    let opts = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    for entry in WalkDir::new(wtf_dir) {
        let entry =
            entry.with_context(|| format!("Walk error backing up WTF: {}", wtf_dir.display()))?;
        if entry.path_is_symlink() {
            bail!("Symlink rejected in WTF backup: {}", entry.path().display());
        }
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry
            .path()
            .strip_prefix(wtf_dir)?
            .to_string_lossy()
            .replace('\\', "/");
        zw.start_file(rel, opts)?;
        zw.write_all(&fs::read(entry.path())?)?;
    }
    zw.finish()?;
    fs::rename(&tmp_zip, &zip_path)?;
    Ok(zip_path)
}

fn default_backup_root() -> Result<PathBuf> {
    if let Ok(home) = std::env::var("HOME") {
        if !home.trim().is_empty() {
            return Ok(PathBuf::from(home).join(".foreversuite").join("backups"));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        if !profile.trim().is_empty() {
            return Ok(PathBuf::from(profile).join(".foreversuite").join("backups"));
        }
    }
    bail!("Cannot resolve default external backup root (~/.foreversuite/backups); pass --backup-dir")
}

fn resolve_backup_root(explicit: Option<&Path>) -> Result<PathBuf> {
    match explicit {
        Some(p) => Ok(p.to_path_buf()),
        None => default_backup_root(),
    }
}

fn move_dir_with_fallback(src: &Path, dst: &Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    if fs::rename(src, dst).is_ok() {
        return Ok(());
    }
    let expected_sha = compute_dir_sha256(src)?;
    copy_dir_recursive(src, dst)?;
    let actual_sha = compute_dir_sha256(dst)?;
    if actual_sha != expected_sha {
        let _ = fs::remove_dir_all(dst);
        bail!(
            "Cross-device move SHA-256 mismatch from {} to {}",
            src.display(),
            dst.display()
        );
    }
    fs::remove_dir_all(src)?;
    Ok(())
}

fn parse_numeric_suffix_key(name: &str, prefix: &str) -> (u64, u64, String) {
    let rest = name
        .strip_prefix(prefix)
        .unwrap_or(name)
        .trim_end_matches(".zip");
    let mut parts = rest.split('_');
    let ts = parts
        .next()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    let pid = parts
        .next()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);
    (ts, pid, name.to_string())
}

fn list_prefixed_entries(dir: &Path, prefix: &str, dirs_only: bool) -> Result<Vec<PathBuf>> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut items: Vec<((u64, u64, String), PathBuf)> = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let ft = entry.file_type()?;
        if dirs_only && !ft.is_dir() {
            continue;
        }
        if !dirs_only && !ft.is_file() {
            continue;
        }
        if let Some(name) = entry.file_name().to_str() {
            if name.starts_with(prefix) {
                items.push((parse_numeric_suffix_key(name, prefix), entry.path()));
            }
        }
    }
    // Numeric descending on (timestamp, pid, name) so prev_backup_10 always outranks prev_backup_2
    items.sort_by(|a, b| b.0.cmp(&a.0));
    Ok(items.into_iter().map(|(_, p)| p).collect())
}

fn rotate_prefixed_entries(dir: &Path, prefix: &str, keep: usize, dirs_only: bool) -> Result<usize> {
    let entries = list_prefixed_entries(dir, prefix, dirs_only)?;
    let mut removed = 0usize;
    for stale in entries.into_iter().skip(keep) {
        if dirs_only {
            fs::remove_dir_all(&stale)?;
        } else {
            fs::remove_file(&stale)?;
        }
        removed += 1;
    }
    Ok(removed)
}

fn prune_internal_addons_backups(addons_dir: &Path) -> Result<usize> {
    let stale_dirs = list_prefixed_entries(addons_dir, ".fsx_prev_backup_", true)?;
    let mut removed = 0usize;
    for dir in stale_dirs {
        fs::remove_dir_all(&dir)
            .with_context(|| format!("Failed to prune internal backup {}", dir.display()))?;
        removed += 1;
    }
    Ok(removed)
}

#[derive(Debug, Serialize, Deserialize)]
struct BackupManifest {
    status: String,
    addons_dir: String,
    deployed_folders: Vec<String>,
    backed_up_folders: Vec<String>,
    #[serde(default)]
    folder_hashes: BTreeMap<String, String>,
}

fn write_backup_manifest(backup_dir: &Path, manifest: &BackupManifest) -> Result<()> {
    let tmp = backup_dir.join(".manifest.json.tmp");
    let dst = backup_dir.join("manifest.json");
    fs::write(&tmp, serde_json::to_vec_pretty(manifest)?)?;
    fs::rename(&tmp, &dst)?;
    Ok(())
}

fn read_complete_manifest(backup_dir: &Path) -> Option<BackupManifest> {
    let raw = fs::read_to_string(backup_dir.join("manifest.json")).ok()?;
    let m: BackupManifest = serde_json::from_str(&raw).ok()?;
    if m.status == "COMPLETE" {
        Some(m)
    } else {
        None
    }
}

pub fn run_rollback(addons_dir: &Path, backup_dir: Option<&Path>) -> Result<()> {
    if !addons_dir.is_dir() {
        bail!("Target AddOns directory does not exist: {}", addons_dir.display());
    }
    let canon_addons = fs::canonicalize(addons_dir)
        .unwrap_or_else(|_| addons_dir.to_path_buf())
        .to_string_lossy()
        .to_string();
    let backup_root = resolve_backup_root(backup_dir)?;
    let generations = list_prefixed_entries(&backup_root, "prev_backup_", true)?;
    let (latest, manifest) = generations
        .into_iter()
        .find_map(|gen| {
            let m = read_complete_manifest(&gen)?;
            if !m.addons_dir.is_empty() && m.addons_dir != canon_addons {
                return None;
            }
            Some((gen, m))
        })
        .with_context(|| {
            format!(
                "No COMPLETE rollback backup generations matching {} found in {}",
                canon_addons,
                backup_root.display()
            )
        })?;

    let mut folders = Vec::new();
    for name in &manifest.backed_up_folders {
        let p = latest.join(name);
        if !p.is_dir() {
            bail!(
                "Manifest-declared backup folder missing in {}: {}",
                latest.display(),
                name
            );
        }
        let sha = compute_dir_sha256(&p)?;
        if let Some(expected_manifest_sha) = manifest.folder_hashes.get(name) {
            if &sha != expected_manifest_sha {
                bail!(
                    "Backup integrity mismatch for '{name}' in {}: expected={expected_manifest_sha} actual={sha}",
                    latest.display()
                );
            }
        }
        folders.push((name.clone(), p, sha));
    }
    let newly_added: Vec<String> = manifest
        .deployed_folders
        .iter()
        .filter(|f| !manifest.backed_up_folders.contains(f))
        .cloned()
        .collect();
    if folders.is_empty() && newly_added.is_empty() {
        bail!("Latest backup generation {} has nothing to restore", latest.display());
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let pid = std::process::id();
    let stage_root = addons_dir.join(format!(".fsx_rollback_stage_{ts}_{pid}"));
    fs::create_dir_all(&stage_root)?;

    let stage_res: Result<()> = (|| {
        for (name, src, expected_sha) in &folders {
            let staged = stage_root.join(name);
            copy_dir_recursive(src, &staged)?;
            let staged_sha = compute_dir_sha256(&staged)?;
            if staged_sha != *expected_sha {
                bail!("Rollback staging SHA-256 mismatch for {name}");
            }
        }
        Ok(())
    })();
    if let Err(err) = stage_res {
        let _ = fs::remove_dir_all(&stage_root);
        return Err(err);
    }

    // Preserve current installed folders in a reversible pre_rollback backup before swapping,
    // and roll back atomically if any folder swap fails mid-way.
    let pre_rollback_backup = backup_root.join(format!("pre_rollback_{ts}_{pid}"));
    fs::create_dir_all(&pre_rollback_backup)?;

    let mut swapped: Vec<(String, bool)> = Vec::new();
    let mut unrecovered_current: Option<String> = None;
    let swap_res: Result<()> = (|| {
        for (name, _, expected_sha) in &folders {
            let target = addons_dir.join(name);
            let staged = stage_root.join(name);
            let had_prev = target.exists();
            if had_prev {
                if let Err(e) = move_dir_with_fallback(&target, &pre_rollback_backup.join(name)) {
                    if pre_rollback_backup.join(name).is_dir() {
                        swapped.push((name.clone(), true));
                    } else {
                        unrecovered_current = Some(format!("{name}: {e}"));
                    }
                    return Err(e);
                }
            }
            if let Err(e) = fs::rename(&staged, &target) {
                if had_prev {
                    if let Err(re) =
                        move_dir_with_fallback(&pre_rollback_backup.join(name), &target)
                    {
                        unrecovered_current = Some(format!("{name}: {re}"));
                        return Err(e).with_context(|| {
                            format!(
                                "CRITICAL: rollback swap failed AND failed to restore '{name}' from {}",
                                pre_rollback_backup.display()
                            )
                        });
                    }
                }
                return Err(e.into());
            }
            swapped.push((name.clone(), had_prev));
            let actual_sha = compute_dir_sha256(&target)?;
            if actual_sha != *expected_sha {
                bail!("Post-rollback SHA-256 mismatch for {name}");
            }
        }
        // Remove folders that were newly added by the rolled-back install (preserving them in pre_rollback_backup)
        for name in &newly_added {
            let target = addons_dir.join(name);
            if target.exists() {
                if let Err(e) = move_dir_with_fallback(&target, &pre_rollback_backup.join(name)) {
                    if pre_rollback_backup.join(name).is_dir() {
                        swapped.push((name.clone(), true));
                    } else {
                        unrecovered_current = Some(format!("{name}: {e}"));
                    }
                    return Err(e);
                }
                swapped.push((name.clone(), true));
            }
        }
        Ok(())
    })();

    if let Err(err) = swap_res {
        let mut recovery_errs = Vec::new();
        if let Some(unrec) = unrecovered_current {
            recovery_errs.push(unrec);
        }
        for (name, had_prev) in swapped.into_iter().rev() {
            let target = addons_dir.join(&name);
            if target.exists() {
                if let Err(e) = fs::remove_dir_all(&target) {
                    recovery_errs.push(format!("remove {name}: {e}"));
                    continue;
                }
            }
            if had_prev {
                if let Err(e) = move_dir_with_fallback(&pre_rollback_backup.join(&name), &target) {
                    recovery_errs.push(format!("restore {name}: {e}"));
                }
            }
        }
        let _ = fs::remove_dir_all(&stage_root);
        if !recovery_errs.is_empty() {
            bail!(
                "Rollback failed ({err}); incomplete recovery (pre-rollback state in {}): {:?}",
                pre_rollback_backup.display(),
                recovery_errs
            );
        }
        return Err(err).with_context(|| {
            format!(
                "Rollback failed; cleanly restored pre-rollback state (backup: {})",
                pre_rollback_backup.display()
            )
        });
    }

    let _ = fs::remove_dir_all(&stage_root);
    println!(
        "[OK] fsx rollback complete: restored {} folder(s) from {} (previous state preserved in {})",
        folders.len(),
        latest.display(),
        pre_rollback_backup.display()
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn run_install_with_options(
    source_root: &Path,
    addons_dir: &Path,
    wtf_dir: Option<&Path>,
    no_wtf_backup: bool,
    prune_legacy: bool,
    backup_dir: Option<&Path>,
    keep: usize,
    prune_internal_backups: bool,
    dry_run: bool,
) -> Result<()> {
    run_install_inner(
        source_root,
        addons_dir,
        wtf_dir,
        no_wtf_backup,
        prune_legacy,
        backup_dir,
        keep,
        prune_internal_backups,
        dry_run,
        None,
    )
}

#[allow(clippy::too_many_arguments)]
fn run_install_inner(
    source_root: &Path,
    addons_dir: &Path,
    wtf_dir: Option<&Path>,
    no_wtf_backup: bool,
    prune_legacy: bool,
    backup_dir: Option<&Path>,
    keep: usize,
    prune_internal_backups: bool,
    dry_run: bool,
    fail_on_swap_folder: Option<&str>,
) -> Result<()> {
    if !addons_dir.is_dir() {
        bail!(
            "Target AddOns directory does not exist: {}",
            addons_dir.display()
        );
    }
    if !dry_run && wtf_dir.is_none() && !no_wtf_backup {
        bail!("Backup-First invariant: pass --wtf-dir <path> or explicit --no-wtf-backup");
    }
    if !dry_run && prune_legacy && addons_dir.join("ForeverSuiteV2").is_dir() && wtf_dir.is_none() {
        bail!(
            "SavedVariables migration invariant: ForeverSuiteV2 exists in AddOns — pass --wtf-dir <path> so ForeverSuiteV2.lua is migrated before pruning"
        );
    }

    let mut folders_to_deploy: Vec<(String, PathBuf, String)> = Vec::new();
    for folder in V2_ADDON_FOLDERS {
        let src = source_root.join(folder);
        if !src.is_dir() {
            bail!(
                "Required v2 addon folder missing from source: {}",
                src.display()
            );
        }
        let toc =
            parse_toc(&src).with_context(|| format!("Invalid addon TOC in {}", src.display()))?;
        for rel in &toc.files {
            let full = src.join(rel);
            if full.is_symlink() || !full.is_file() {
                bail!(
                    "TOC file missing or symlink on disk: {}/{}",
                    folder,
                    rel.display()
                );
            }
        }
        let sha = compute_dir_sha256(&src)?;
        folders_to_deploy.push(((*folder).to_string(), src, sha));
    }
    for folder in OPTIONAL_LOD_DATA_FOLDERS {
        let src = source_root.join(folder);
        if !src.is_dir() {
            continue;
        }
        let toc =
            parse_toc(&src).with_context(|| format!("Invalid LoD addon TOC in {}", src.display()))?;
        for rel in &toc.files {
            let full = src.join(rel);
            if full.is_symlink() || !full.is_file() {
                bail!(
                    "LoD TOC file missing or symlink on disk: {}/{}",
                    folder,
                    rel.display()
                );
            }
        }
        let sha = compute_dir_sha256(&src)?;
        folders_to_deploy.push(((*folder).to_string(), src, sha));
    }

    if dry_run {
        println!(
            "[DRY-RUN] Verified {} addon folder(s):",
            folders_to_deploy.len()
        );
        for (name, _, sha) in &folders_to_deploy {
            println!("  - {name} (sha256={})", &sha[..16]);
        }
        if prune_legacy {
            let legacy = find_legacy_folders(addons_dir)?;
            println!(
                "[DRY-RUN] Legacy folders queued for backup & removal ({}): {:?}",
                legacy.len(),
                legacy
            );
        }
        return Ok(());
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let backup_root = resolve_backup_root(backup_dir)?;
    fs::create_dir_all(&backup_root)?;

    if let Some(wtf) = wtf_dir {
        let wtf_backup_root = backup_root.join("wtf_backups");
        let zip_out = backup_wtf_dir(wtf, &wtf_backup_root, ts)?;
        println!("[OK] Pre-deploy WTF backup created: {}", zip_out.display());
        let migrated = migrate_saved_variables(wtf)?;
        if migrated > 0 {
            println!(
                "[OK] Migrated {} SavedVariables file(s) (ForeverSuiteV2.lua -> ForeverSuite.lua)",
                migrated
            );
        }
    }

    let pid = std::process::id();
    let seq = INSTALL_SEQ.fetch_add(1, Ordering::Relaxed);
    let stage_root = addons_dir.join(format!(".fsx_stage_{ts}_{pid}_{seq}"));
    // Stage backup under hidden .incomplete prefix; publish atomically as prev_backup_* ONLY after swap succeeds
    let prev_backup_staging = backup_root.join(format!(".prev_backup_{ts}_{pid}_{seq}.incomplete"));
    let prev_backup = backup_root.join(format!("prev_backup_{ts}_{pid}_{seq}"));
    let canon_addons = fs::canonicalize(addons_dir)
        .unwrap_or_else(|_| addons_dir.to_path_buf())
        .to_string_lossy()
        .to_string();
    fs::create_dir_all(&stage_root)?;

    // Stage and pre-verify SHA-256 BEFORE swapping anything
    let stage_res: Result<()> = (|| {
        for (name, src, expected_sha) in &folders_to_deploy {
            let staged = stage_root.join(name);
            copy_dir_recursive(src, &staged)?;
            let staged_sha = compute_dir_sha256(&staged)?;
            if staged_sha != *expected_sha {
                bail!(
                    "Staged SHA-256 mismatch for {name}: expected={expected_sha} actual={staged_sha}"
                );
            }
        }
        Ok(())
    })();
    if let Err(err) = stage_res {
        let _ = fs::remove_dir_all(&stage_root);
        return Err(err);
    }

    // Swap + manifest publication inside one rollback boundary so deployment & backup never diverge
    fs::create_dir_all(&prev_backup_staging)?;
    let mut swapped: Vec<(String, bool)> = Vec::new();
    let mut unrecovered_current: Option<String> = None;
    let swap_res: Result<()> = (|| {
        for (name, _, expected_sha) in &folders_to_deploy {
            if fail_on_swap_folder == Some(name.as_str()) {
                bail!("Injected mid-swap failure on folder '{name}'");
            }
            let target = addons_dir.join(name);
            let staged = stage_root.join(name);
            let had_prev = target.exists();
            if had_prev {
                if let Err(e) = move_dir_with_fallback(&target, &prev_backup_staging.join(name)) {
                    if prev_backup_staging.join(name).is_dir() {
                        swapped.push((name.clone(), true));
                    } else {
                        unrecovered_current = Some(format!("{name}: {e}"));
                    }
                    return Err(e);
                }
            }
            if let Err(e) = fs::rename(&staged, &target) {
                if had_prev {
                    if let Err(re) =
                        move_dir_with_fallback(&prev_backup_staging.join(name), &target)
                    {
                        unrecovered_current = Some(format!("{name}: {re}"));
                        return Err(e).with_context(|| {
                            format!(
                                "CRITICAL: failed to restore '{name}' from backup {}",
                                prev_backup_staging.display()
                            )
                        });
                    }
                }
                return Err(e.into());
            }
            swapped.push((name.clone(), had_prev));

            let actual_sha = compute_dir_sha256(&target)?;
            if actual_sha != *expected_sha {
                bail!("Post-deploy SHA-256 mismatch for {name}");
            }
        }
        // Write COMPLETE manifest & atomically publish prev_backup generation inside swap boundary
        let backed_up_folders: Vec<String> = swapped
            .iter()
            .filter(|(_, had_prev)| *had_prev)
            .map(|(n, _)| n.clone())
            .collect();
        let deployed_folders: Vec<String> = folders_to_deploy
            .iter()
            .map(|(n, _, _)| n.clone())
            .collect();
        // Record backup-time SHA-256 hashes & atomically publish COMPLETE prev_backup generation
        let mut folder_hashes: BTreeMap<String, String> = BTreeMap::new();
        for name in &backed_up_folders {
            let h = compute_dir_sha256(&prev_backup_staging.join(name))?;
            folder_hashes.insert(name.clone(), h);
        }
        write_backup_manifest(
            &prev_backup_staging,
            &BackupManifest {
                status: "COMPLETE".to_string(),
                addons_dir: canon_addons.clone(),
                deployed_folders,
                backed_up_folders,
                folder_hashes,
            },
        )?;
        fs::rename(&prev_backup_staging, &prev_backup)?;
        Ok(())
    })();

    if let Err(err) = swap_res {
        let active_backup = if prev_backup.exists() {
            &prev_backup
        } else {
            &prev_backup_staging
        };
        let mut rollback_errors = Vec::new();
        if let Some(unrec) = unrecovered_current {
            rollback_errors.push(unrec);
        }
        for (name, had_prev) in swapped.into_iter().rev() {
            let target = addons_dir.join(&name);
            if target.exists() {
                if let Err(e) = fs::remove_dir_all(&target) {
                    rollback_errors.push(format!("remove {name}: {e}"));
                    continue;
                }
            }
            if had_prev {
                if let Err(e) = move_dir_with_fallback(&active_backup.join(&name), &target) {
                    rollback_errors.push(format!("restore {name}: {e}"));
                }
            }
        }
        let _ = fs::remove_dir_all(&stage_root);
        if !rollback_errors.is_empty() {
            bail!(
                "Swap failed ({err}); INCOMPLETE rollback (manual recovery preserved in {}): {:?}",
                active_backup.display(),
                rollback_errors
            );
        }
        // Only clean up staging backup directory if it has no remaining backed-up addon subfolders
        let has_remaining_dirs = fs::read_dir(active_backup)
            .map(|rd| rd.flatten().any(|e| e.file_type().map(|ft| ft.is_dir()).unwrap_or(false)))
            .unwrap_or(true);
        if !has_remaining_dirs {
            let _ = fs::remove_dir_all(active_backup);
        }
        return Err(err).with_context(|| {
            "Swap failed; rolled back all swapped folders cleanly".to_string()
        });
    }

    let _ = fs::remove_dir_all(&stage_root);

    if prune_legacy {
        let legacy = find_legacy_folders(addons_dir)?;
        if !legacy.is_empty() {
            let legacy_backup_dir = backup_root.join("legacy_backups");
            let archive_path = archive_legacy_folders(addons_dir, &legacy, &legacy_backup_dir, ts)?;
            for name in &legacy {
                let path = addons_dir.join(name);
                if path.is_dir() {
                    fs::remove_dir_all(&path)
                        .with_context(|| format!("Failed to prune legacy folder {}", path.display()))?;
                }
            }
            println!(
                "[OK] Pruned {} legacy folder(s) (rollback archive: {})",
                legacy.len(),
                archive_path.display()
            );
        }
    }

    if keep > 0 {
        let rotated_prev = rotate_prefixed_entries(&backup_root, "prev_backup_", keep, true)?;
        let rotated_wtf = rotate_prefixed_entries(&backup_root.join("wtf_backups"), "WTF_backup_", keep, false)?;
        if rotated_prev > 0 || rotated_wtf > 0 {
            println!(
                "[OK] Rotated stale external backups (keep={keep}): removed {rotated_prev} addon backup(s), {rotated_wtf} WTF backup(s)"
            );
        }
    }

    if prune_internal_backups {
        let pruned = prune_internal_addons_backups(addons_dir)?;
        if pruned > 0 {
            println!(
                "[OK] Pruned {pruned} legacy internal .fsx_prev_backup_* folder(s) inside AddOns"
            );
        }
    }

    println!(
        "[OK] fsx install atomic swap complete: {} folder(s) verified in {} (external backup: {})",
        folders_to_deploy.len(),
        addons_dir.display(),
        prev_backup.display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn seed_v2_tree(root: &Path, marker: &str) -> Result<()> {
        for name in V2_ADDON_FOLDERS {
            fs::create_dir_all(root.join(name))?;
            fs::write(
                root.join(name).join(format!("{name}.toc")),
                "## Interface: 16001\nInit.lua\n",
            )?;
            fs::write(
                root.join(name).join("Init.lua"),
                format!("local ver = '{marker}'\n"),
            )?;
        }
        Ok(())
    }

    #[test]
    fn install_enforces_wtf_backup_preserves_prev_and_rolls_back_on_mid_swap_failure() -> Result<()> {
        let dir = tempdir()?;
        let src_v2 = dir.path().join("v2_new");
        let addons = dir.path().join("AddOns");
        let wtf = dir.path().join("WTF");
        let backups = dir.path().join("ext_backups");
        seed_v2_tree(&src_v2, "v2_new")?;
        seed_v2_tree(&addons, "v1_old")?;
        fs::create_dir_all(wtf.join("Account"))?;
        fs::write(wtf.join("Account/ForeverSuite.lua"), "ForeverSuiteDB = {}\n")?;

        // 1. Fail-closed without --wtf-dir or --no-wtf-backup
        assert!(run_install_with_options(&src_v2, &addons, None, false, false, Some(&backups), 2, false, false).is_err());

        // 2. Mid-swap failure injected on folder #2 MUST roll back folder #1 to v1_old!
        let err = run_install_inner(
            &src_v2,
            &addons,
            Some(&wtf),
            false,
            false,
            Some(&backups),
            2,
            false,
            false,
            Some("ForeverSuite_Media"),
        );
        assert!(err.is_err());
        let restored = fs::read_to_string(addons.join("ForeverSuite/Init.lua"))?;
        assert!(
            restored.contains("v1_old"),
            "Folder #1 must be rolled back to v1_old, got: {restored}"
        );

        // 3. Clean install writes v2_new, stores backups OUTSIDE AddOns, and supports fsx rollback!
        run_install_with_options(&src_v2, &addons, Some(&wtf), false, false, Some(&backups), 2, false, false)?;
        let installed = fs::read_to_string(addons.join("ForeverSuite/Init.lua"))?;
        assert!(installed.contains("v2_new"));
        assert!(backups.join("wtf_backups").is_dir());
        assert!(!addons.join(".fsx_wtf_backups").exists(), "backups must stay outside AddOns");

        // Rollback restores v1_old cleanly
        run_rollback(&addons, Some(&backups))?;
        let rolled = fs::read_to_string(addons.join("ForeverSuite/Init.lua"))?;
        assert!(rolled.contains("v1_old"), "rollback must restore v1_old, got: {rolled}");

        // 4. Symlink inside source folder is rejected fail-closed
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(
                src_v2.join("ForeverSuite/Init.lua"),
                src_v2.join("ForeverSuite/link.lua"),
            )?;
            assert!(run_install_with_options(&src_v2, &addons, None, true, false, Some(&backups), 2, false, false).is_err());
        }
        Ok(())
    }

    #[test]
    fn install_rotates_external_backups_and_prunes_internal_backups() -> Result<()> {
        let dir = tempdir()?;
        let src = dir.path().join("v2_src");
        let addons = dir.path().join("AddOns");
        let backups = dir.path().join("ext_backups");
        seed_v2_tree(&src, "v6_0")?;
        seed_v2_tree(&addons, "v5_0")?;

        // Seed 3 older external backup generations + 2 legacy internal AddOns/.fsx_prev_backup_* dirs
        for old in ["prev_backup_1000_1", "prev_backup_1001_1", "prev_backup_1002_1"] {
            fs::create_dir_all(backups.join(old))?;
        }
        for stale in [".fsx_prev_backup_100_1", ".fsx_prev_backup_200_1"] {
            fs::create_dir_all(addons.join(stale))?;
        }

        run_install_with_options(&src, &addons, None, true, false, Some(&backups), 2, true, false)?;

        let remaining_ext = list_prefixed_entries(&backups, "prev_backup_", true)?;
        assert_eq!(remaining_ext.len(), 2, "keep=2 must retain exactly 2 newest external backup generations");
        let remaining_int = list_prefixed_entries(&addons, ".fsx_prev_backup_", true)?;
        assert_eq!(remaining_int.len(), 0, "prune_internal_backups must clear legacy AddOns backups");

        // B2 regression: numeric ordering must select COMPLETE prev_backup_10_1 over prev_backup_2_1
        // and ignore incomplete generations without COMPLETE manifest!
        let num_dir = tempdir()?;
        let num_addons = num_dir.path().join("AddOns");
        let num_backups = num_dir.path().join("backups");
        seed_v2_tree(&num_addons, "current")?;
        let canon_num = fs::canonicalize(&num_addons)?.to_string_lossy().to_string();
        for (gname, marker) in [("prev_backup_2_1", "gen_2"), ("prev_backup_10_1", "gen_10")] {
            let gd = num_backups.join(gname);
            seed_v2_tree(&gd, marker)?;
            let mut hashes = BTreeMap::new();
            for folder in V2_ADDON_FOLDERS {
                hashes.insert(folder.to_string(), compute_dir_sha256(&gd.join(folder))?);
            }
            write_backup_manifest(
                &gd,
                &BackupManifest {
                    status: "COMPLETE".to_string(),
                    addons_dir: canon_num.clone(),
                    deployed_folders: V2_ADDON_FOLDERS.iter().map(|s| s.to_string()).collect(),
                    backed_up_folders: V2_ADDON_FOLDERS.iter().map(|s| s.to_string()).collect(),
                    folder_hashes: hashes,
                },
            )?;
        }
        // Seed an incomplete newer backup (no manifest) — MUST be ignored!
        seed_v2_tree(&num_backups.join("prev_backup_99_1"), "incomplete_99")?;

        run_rollback(&num_addons, Some(&num_backups))?;
        let restored = fs::read_to_string(num_addons.join("ForeverSuite/Init.lua"))?;
        assert!(
            restored.contains("gen_10"),
            "numeric sort must restore COMPLETE prev_backup_10_1 (ignoring _2 and incomplete _99), got: {restored}"
        );
        Ok(())
    }

    #[test]
    fn install_prune_legacy_archives_and_removes_only_legacy_addons() -> Result<()> {
        let dir = tempdir()?;
        let src = dir.path().join("v2_src");
        let addons = dir.path().join("AddOns");
        let wtf = dir.path().join("WTF");
        let backups = dir.path().join("ext_backups");
        seed_v2_tree(&src, "v2_0_0")?;
        fs::create_dir_all(&addons)?;
        fs::create_dir_all(wtf.join("Account"))?;
        fs::write(wtf.join("Account/test.lua"), "x = 1\n")?;

        // Seed legacy folders AND unrelated dedicated addons
        for legacy in ["ForeverSuiteV2", "ForeverSuite_GJBridge", "GodJohnsonGoldBorder", "GodJohnsonBiSData"] {
            fs::create_dir_all(addons.join(legacy))?;
            fs::write(addons.join(legacy).join("old.lua"), "old = true\n")?;
        }
        for keep in ["Auctionator", "Baganator"] {
            fs::create_dir_all(addons.join(keep))?;
            fs::write(addons.join(keep).join("keep.lua"), "keep = true\n")?;
        }
        // Seed both v1 ForeverSuite.lua AND preview ForeverSuiteV2.lua in account & character SavedVariables
        let acct_sv = wtf.join("Account/TESTACCT/SavedVariables");
        let char_sv = wtf.join("Account/TESTACCT/ForeverKR/Hero/SavedVariables");
        fs::create_dir_all(&acct_sv)?;
        fs::create_dir_all(&char_sv)?;
        fs::write(acct_sv.join("ForeverSuite.lua"), "ForeverSuiteDB = { schemaVersion = 2 }\n")?;
        fs::write(
            acct_sv.join("ForeverSuiteV2.lua"),
            "ForeverSuiteV2DB = { schemaVersion = 3, v2 = { protectedItems = { [1014] = true } } }\n",
        )?;
        fs::write(
            char_sv.join("ForeverSuiteV2.lua"),
            "ForeverSuiteV2CharDB = { realm = \"ForeverKR\" }\n",
        )?;

        // Fail-closed: pruning ForeverSuiteV2 without --wtf-dir is rejected
        assert!(run_install_with_options(&src, &addons, None, true, true, Some(&backups), 2, false, false).is_err());

        run_install_with_options(&src, &addons, Some(&wtf), false, true, Some(&backups), 2, false, false)?;

        // Legacy folders archived (and ZIP verified) & removed; unrelated addons untouched; clean 3 folders installed
        for legacy in ["ForeverSuiteV2", "ForeverSuite_GJBridge", "GodJohnsonGoldBorder", "GodJohnsonBiSData"] {
            assert!(!addons.join(legacy).exists(), "legacy folder '{legacy}' should be pruned");
        }
        for keep in ["Auctionator", "Baganator", "ForeverSuite", "ForeverSuite_Media", "ForeverSuite_Data"] {
            assert!(addons.join(keep).is_dir(), "expected folder '{keep}' to exist");
        }
        assert!(backups.join("legacy_backups").is_dir());

        // Account SavedVariables merged BOTH v1 ForeverSuiteDB and v2 ForeverSuiteV2DB; char copied cleanly
        let merged_acct = fs::read_to_string(acct_sv.join("ForeverSuite.lua"))?;
        assert!(merged_acct.contains("ForeverSuiteDB = { schemaVersion = 2 }"));
        assert!(merged_acct.contains("ForeverSuiteV2DB = { schemaVersion = 3"));
        let merged_char = fs::read_to_string(char_sv.join("ForeverSuite.lua"))?;
        assert!(merged_char.contains("ForeverSuiteV2CharDB"));

        // Second run is strictly idempotent (no duplicate ForeverSuiteV2DB block)
        run_install_with_options(&src, &addons, Some(&wtf), false, true, Some(&backups), 2, false, false)?;
        let merged_again = fs::read_to_string(acct_sv.join("ForeverSuite.lua"))?;
        assert_eq!(merged_again.matches("ForeverSuiteV2DB").count(), 1);
        Ok(())
    }
}

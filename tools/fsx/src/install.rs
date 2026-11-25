use crate::manifest::parse_toc;
use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use walkdir::WalkDir;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

const V2_ADDON_FOLDERS: &[&str] = &["ForeverSuiteV2", "ForeverSuite_Media", "ForeverSuite_Data"];

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

pub fn run_install(
    source_root: &Path,
    addons_dir: &Path,
    wtf_dir: Option<&Path>,
    no_wtf_backup: bool,
    dry_run: bool,
) -> Result<()> {
    run_install_inner(source_root, addons_dir, wtf_dir, no_wtf_backup, dry_run, None)
}

fn run_install_inner(
    source_root: &Path,
    addons_dir: &Path,
    wtf_dir: Option<&Path>,
    no_wtf_backup: bool,
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

    if dry_run {
        println!(
            "[DRY-RUN] Verified {} addon folder(s):",
            folders_to_deploy.len()
        );
        for (name, _, sha) in &folders_to_deploy {
            println!("  - {name} (sha256={})", &sha[..16]);
        }
        return Ok(());
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    if let Some(wtf) = wtf_dir {
        let backup_root = addons_dir.join(".fsx_wtf_backups");
        let zip_out = backup_wtf_dir(wtf, &backup_root, ts)?;
        println!("[OK] Pre-deploy WTF backup created: {}", zip_out.display());
    }

    let pid = std::process::id();
    let stage_root = addons_dir.join(format!(".fsx_stage_{ts}_{pid}"));
    let prev_backup = addons_dir.join(format!(".fsx_prev_backup_{ts}_{pid}"));
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

    // Swap with full verified rollback on any error
    fs::create_dir_all(&prev_backup)?;
    let mut swapped: Vec<(String, bool)> = Vec::new();
    let swap_res: Result<()> = (|| {
        for (name, _, expected_sha) in &folders_to_deploy {
            if fail_on_swap_folder == Some(name.as_str()) {
                bail!("Injected mid-swap failure on folder '{name}'");
            }
            let target = addons_dir.join(name);
            let staged = stage_root.join(name);
            let had_prev = target.exists();
            if had_prev {
                fs::rename(&target, prev_backup.join(name))?;
            }
            if let Err(e) = fs::rename(&staged, &target) {
                if had_prev {
                    fs::rename(prev_backup.join(name), &target).with_context(|| {
                        format!(
                            "CRITICAL: failed to restore '{name}' from backup {}",
                            prev_backup.display()
                        )
                    })?;
                }
                return Err(e.into());
            }
            swapped.push((name.clone(), had_prev));

            let actual_sha = compute_dir_sha256(&target)?;
            if actual_sha != *expected_sha {
                bail!("Post-deploy SHA-256 mismatch for {name}");
            }
        }
        Ok(())
    })();

    if let Err(err) = swap_res {
        let mut rollback_errors = Vec::new();
        for (name, had_prev) in swapped.into_iter().rev() {
            let target = addons_dir.join(&name);
            if target.exists() {
                if let Err(e) = fs::remove_dir_all(&target) {
                    rollback_errors.push(format!("remove {name}: {e}"));
                    continue;
                }
            }
            if had_prev {
                if let Err(e) = fs::rename(prev_backup.join(&name), &target) {
                    rollback_errors.push(format!("restore {name}: {e}"));
                }
            }
        }
        let _ = fs::remove_dir_all(&stage_root);
        if !rollback_errors.is_empty() {
            bail!(
                "Swap failed ({err}); INCOMPLETE rollback (manual recovery from {}): {:?}",
                prev_backup.display(),
                rollback_errors
            );
        }
        return Err(err).with_context(|| {
            format!(
                "Swap failed; rolled back all swapped folders cleanly (backup dir: {})",
                prev_backup.display()
            )
        });
    }

    let _ = fs::remove_dir_all(&stage_root);
    println!(
        "[OK] fsx install atomic swap complete: {} folder(s) verified in {} (backup: {})",
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
        seed_v2_tree(&src_v2, "v2_new")?;
        seed_v2_tree(&addons, "v1_old")?;
        fs::create_dir_all(wtf.join("Account"))?;
        fs::write(wtf.join("Account/ForeverSuite.lua"), "ForeverSuiteDB = {}\n")?;

        // 1. Fail-closed without --wtf-dir or --no-wtf-backup
        assert!(run_install(&src_v2, &addons, None, false, false).is_err());

        // 2. Mid-swap failure injected on folder #2 MUST roll back folder #1 to v1_old!
        let err = run_install_inner(
            &src_v2,
            &addons,
            Some(&wtf),
            false,
            false,
            Some("ForeverSuite_Media"),
        );
        assert!(err.is_err());
        let restored = fs::read_to_string(addons.join("ForeverSuiteV2/Init.lua"))?;
        assert!(
            restored.contains("v1_old"),
            "Folder #1 must be rolled back to v1_old, got: {restored}"
        );

        // 3. Clean install succeeds, writes v2_new, and preserves timestamped backup
        run_install(&src_v2, &addons, Some(&wtf), false, false)?;
        let installed = fs::read_to_string(addons.join("ForeverSuiteV2/Init.lua"))?;
        assert!(installed.contains("v2_new"));
        assert!(addons.join(".fsx_wtf_backups").is_dir());

        // 4. Symlink inside source folder is rejected fail-closed
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(
                src_v2.join("ForeverSuiteV2/Init.lua"),
                src_v2.join("ForeverSuiteV2/link.lua"),
            )?;
            assert!(run_install(&src_v2, &addons, None, true, false).is_err());
        }
        Ok(())
    }
}

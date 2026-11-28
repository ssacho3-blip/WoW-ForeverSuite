mod check;
mod data;
mod gj_compiler;
mod install;
mod manifest;
mod package;
mod taint_report;
mod test_runner;

use anyhow::Result;
use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "fsx",
    version,
    about = "ForeverSuite v2 Rust toolchain (AST check · Lua 5.1 VM test · LoD data · atomic install · taint report)"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Enforce 6-layer directory-as-permission rules, Lua 5.1 syntax, verified WoW 1.60.1 APIs, and TOC integrity
    Check {
        /// Path to addon folder (e.g. v2/ForeverSuite)
        addon_dir: PathBuf,
    },
    /// Execute Lua 5.1 tests inside a vendored mlua VM with strict C_Secrets proxy fuzzing
    Test {
        /// Path to v2 root directory containing ForeverSuite/ and tests/
        v2_root: PathBuf,
    },
    /// Build-time LoD data pack compiler and GodJohnson ZIP inspector/extractor
    Data {
        #[command(subcommand)]
        action: DataAction,
    },
    /// Backup-first atomic deployer with SHA-256 tree verification & external backup rotation (macOS & Windows)
    Install {
        /// Source root containing addon folders (e.g. v2)
        #[arg(long)]
        source: PathBuf,
        /// Target WoW _forever_/Interface/AddOns directory
        #[arg(long)]
        addons_dir: PathBuf,
        /// Optional WTF directory to back up before modifying AddOns
        #[arg(long)]
        wtf_dir: Option<PathBuf>,
        /// Explicit opt-out when WTF backup is intentionally skipped
        #[arg(long)]
        no_wtf_backup: bool,
        /// Archive and remove legacy ForeverSuiteV2, ForeverSuite_GJBridge, and GodJohnson* folders
        #[arg(long)]
        prune_legacy: bool,
        /// External backup root directory (defaults to ~/.foreversuite/backups)
        #[arg(long)]
        backup_dir: Option<PathBuf>,
        /// Number of most recent backup generations to retain (default: 2)
        #[arg(long, default_value_t = 2)]
        keep: usize,
        /// Remove legacy internal .fsx_prev_backup_* directories from AddOns after verified install
        #[arg(long)]
        prune_internal_backups: bool,
        /// Validate and plan deployment without writing to AddOns
        #[arg(long)]
        dry_run: bool,
    },
    /// Restore the newest verified backup generation from ~/.foreversuite/backups into AddOns
    Rollback {
        /// Target WoW _forever_/Interface/AddOns directory
        #[arg(long)]
        addons_dir: PathBuf,
        /// External backup root directory (defaults to ~/.foreversuite/backups)
        #[arg(long)]
        backup_dir: Option<PathBuf>,
    },
    /// Build verified 3-folder release ZIP + SHA-256 with size hard cap & Private/ leak guard
    Package {
        /// Source root containing v2 addon folders (e.g. v2)
        #[arg(long)]
        source: PathBuf,
        /// Output directory for release ZIP and SHA-256
        #[arg(long)]
        out: PathBuf,
        /// Optional release tag (e.g. v6.0.0) enforced against ForeverSuite.toc Version
        #[arg(long)]
        tag: Option<String>,
        /// Maximum allowed uncompressed package size in MiB (default: 18)
        #[arg(long, default_value_t = 18)]
        max_mb: u64,
    },
    /// Parse Blizzard Logs/taint.log and ForeverSuite SavedVariables diagnostics/GJ usage telemetry
    TaintReport {
        /// Path to WoW _forever_/Logs/taint.log
        #[arg(long)]
        taint_log: Option<PathBuf>,
        /// Path to WTF/.../SavedVariables/ForeverSuite.lua
        #[arg(long)]
        saved_vars: Option<PathBuf>,
    },
}

#[derive(Subcommand)]
enum DataAction {
    /// Inspect byte breakdown of a GodJohnson upstream ZIP archive
    InspectGj { zip_path: PathBuf },
    /// Compile validated TOML sources into ForeverSuite_Data (LoadOnDemand: 1) Lua packs + provenance.json
    Compile {
        #[arg(long)]
        src: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Extract selected reference tables from local GodJohnson ZIP into clean TOML + provenance metadata
    ExtractGj {
        #[arg(long)]
        zip: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
    /// Compile all 6 real GodJohnson databases from backup ZIP into sharded LoadOnDemand ForeverSuite_Data_* addons
    CompileGj {
        #[arg(long)]
        zip: PathBuf,
        #[arg(long)]
        v2_root: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Commands::Check { addon_dir } => {
            let report = check::run_check(&addon_dir)?;
            println!(
                "[OK] fsx check passed: {} Lua files verified, 0 violations ({})",
                report.files_checked,
                addon_dir.display()
            );
            Ok(())
        }
        Commands::Test { v2_root } => {
            let summary = test_runner::run_tests(&v2_root)?;
            println!(
                "[OK] fsx test passed: {}/{} tests passed in Lua 5.1 VM (mlua)",
                summary.passed, summary.total
            );
            Ok(())
        }
        Commands::Data { action } => match action {
            DataAction::InspectGj { zip_path } => data::inspect_gj_zip(&zip_path),
            DataAction::Compile { src, out } => data::compile_toml_to_lod(&src, &out),
            DataAction::ExtractGj { zip, out } => data::extract_gj_to_toml(&zip, &out),
            DataAction::CompileGj { zip, v2_root } => {
                gj_compiler::compile_gj_lod_packs(&zip, &v2_root)
            }
        },
        Commands::Install {
            source,
            addons_dir,
            wtf_dir,
            no_wtf_backup,
            prune_legacy,
            backup_dir,
            keep,
            prune_internal_backups,
            dry_run,
        } => install::run_install_with_options(
            &source,
            &addons_dir,
            wtf_dir.as_deref(),
            no_wtf_backup,
            prune_legacy,
            backup_dir.as_deref(),
            keep,
            prune_internal_backups,
            dry_run,
        ),
        Commands::Rollback {
            addons_dir,
            backup_dir,
        } => install::run_rollback(&addons_dir, backup_dir.as_deref()),
        Commands::Package {
            source,
            out,
            tag,
            max_mb,
        } => package::run_package(&source, &out, tag.as_deref(), max_mb),
        Commands::TaintReport {
            taint_log,
            saved_vars,
        } => taint_report::run_report(taint_log.as_deref(), saved_vars.as_deref()),
    }
}

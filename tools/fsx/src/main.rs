mod check;
mod data;
mod install;
mod manifest;
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
    /// Backup-first atomic deployer with SHA-256 tree verification (macOS & Windows)
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
        /// Validate and plan deployment without writing to AddOns
        #[arg(long)]
        dry_run: bool,
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
        },
        Commands::Install {
            source,
            addons_dir,
            wtf_dir,
            no_wtf_backup,
            dry_run,
        } => install::run_install(&source, &addons_dir, wtf_dir.as_deref(), no_wtf_backup, dry_run),
        Commands::TaintReport {
            taint_log,
            saved_vars,
        } => taint_report::run_report(taint_log.as_deref(), saved_vars.as_deref()),
    }
}

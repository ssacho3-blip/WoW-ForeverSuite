#!/usr/bin/env python3
"""One-command ForeverSuite release pipeline: version sync -> test -> build -> deploy -> commit/push/tag -> GitHub Release -> verified auto-mail."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from build_win_exe import read_suite_version  # noqa: E402
from notify_release import DEFAULT_REPO_SLUG, dispatch_release_notification  # noqa: E402

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def compute_next_version(current: str, bump: str | None) -> str:
    """Compute target semver from `--bump patch|minor|major|X.Y.Z` (or return current when None)."""
    if not bump:
        return current
    m = SEMVER_RE.fullmatch(current)
    if not m:
        raise ValueError(f"Current version is not X.Y.Z semver: {current!r}")
    major, minor, patch = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "major":
        return f"{major + 1}.0.0"
    if SEMVER_RE.fullmatch(bump):
        return bump
    raise ValueError(f"Unsupported --bump value: {bump!r}")


def sync_version_strings(repo_root: pathlib.Path, new_version: str) -> list[pathlib.Path]:
    """Update all 6 canonical version declarations in the repository to `new_version`."""
    if not SEMVER_RE.fullmatch(new_version):
        raise ValueError(f"Version must be X.Y.Z semver: {new_version!r}")

    specs: list[tuple[pathlib.Path, str, str]] = [
        (
            repo_root / "ForeverSuite" / "ForeverSuite.toc",
            r"^(##\s*Version:\s*)[\w.\-]+",
            rf"\g<1>{new_version}",
        ),
        (
            repo_root / "ForeverSuite_GJBridge" / "ForeverSuite_GJBridge.toc",
            r"^(##\s*Version:\s*)[\w.\-]+",
            rf"\g<1>{new_version}",
        ),
        (
            repo_root / "ForeverSuite" / "Core" / "Init.lua",
            r'(local\s+ver\s*=\s*")[\w.\-]+(")',
            rf'\g<1>{new_version}\g<2>',
        ),
        (
            repo_root / "ForeverSuite_GJBridge" / "State.lua",
            r'(ns\.VERSION\s*=\s*")[\w.\-]+(")',
            rf'\g<1>{new_version}\g<2>',
        ),
        (
            repo_root / "scripts" / "build_win_exe.py",
            r'(def\s+(?:read_suite_version|build_embedded_ps1_script)\([^)]*?(?:default|suite_version):\s*str\s*=\s*")[\w.\-]+(")',
            rf'\g<1>{new_version}\g<2>',
        ),
    ]
    changed: list[pathlib.Path] = []
    for file_path, pattern, replacement in specs:
        src = file_path.read_text(encoding="utf-8")
        updated, count = re.subn(pattern, replacement, src, flags=re.MULTILINE)
        if count == 0:
            raise RuntimeError(f"Version pattern not found in {file_path}")
        if updated != src:
            file_path.write_text(updated, encoding="utf-8")
            changed.append(file_path)
    return changed


def _run(cmd: list[str], cwd: pathlib.Path = REPO_ROOT, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"+ {' '.join(cmd)}", flush=True)
    return subprocess.run(cmd, cwd=str(cwd), text=True, check=check)


def _gh_release_exists(tag: str, repo_slug: str) -> bool:
    proc = subprocess.run(
        ["gh", "release", "view", tag, "--repo", repo_slug],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode == 0


def read_pinned_upstream_version(repo_root: pathlib.Path) -> str | None:
    """Read and validate upstream GodJohnson version from pinned_upstream.json if present."""
    pin_path = repo_root / "pinned_upstream.json"
    if not pin_path.is_file():
        return None
    data = json.loads(pin_path.read_text(encoding="utf-8"))
    raw_ver = data.get("version")
    if not isinstance(raw_ver, str) or not raw_ver.strip():
        raise ValueError(f"Invalid upstream version in {pin_path}: {raw_ver!r}")
    return raw_ver.strip()


def format_release_title(repo_root: pathlib.Path, tag: str, *, include_auto_suffix: bool = False) -> str:
    """Build consistent GitHub Release title from tag and pinned upstream version."""
    gj_ver = read_pinned_upstream_version(repo_root)
    upstream_label = f" + 갓존슨 v{gj_ver}" if gj_ver else ""
    suffix = " — 자동 릴리스 패키지" if include_auto_suffix else ""
    return f"ForeverSuite {tag}{upstream_label}{suffix}"


def run_release_pipeline(args: argparse.Namespace) -> int:
    current_ver = read_suite_version(REPO_ROOT)
    target_ver = compute_next_version(current_ver, args.bump)
    tag = f"v{target_ver}"

    if target_ver != current_ver and not args.dry_run:
        sync_version_strings(REPO_ROOT, target_ver)

    pytest_bin = args.pytest_bin or shutil.which("pytest") or sys.executable
    if pathlib.Path(pytest_bin).name.startswith("python"):
        pytest_cmd = [pytest_bin, "-m", "pytest", "tests/", "-q", "--strict-markers"]
    else:
        pytest_cmd = [pytest_bin, "tests/", "-q", "--strict-markers"]
    _run(pytest_cmd)

    if args.dry_run:
        print(f"[DRY-RUN] Verified tests. Current={current_ver}, Target={target_ver} ({tag}). Skipping build/push/mail.")
        return 0

    _run([sys.executable, "scripts/package_release.py"])

    wow_addons = pathlib.Path("/Applications/World of Warcraft/_forever_/Interface/AddOns")
    if wow_addons.is_dir() and not args.skip_mac_deploy:
        _run(["bash", "scripts/deploy_mac.sh"])

    if not args.skip_git:
        status_proc = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            check=True,
        )
        if status_proc.stdout.strip():
            commit_msg = args.message or f"release({tag}): build packages, sync metadata, and publish {tag}"
            _run(["git", "add", "-A"])
            _run(["git", "commit", "-m", commit_msg])
        _run(["git", "push", "origin", "main"])

    exe_path = REPO_ROOT / "dist" / "ForeverSuite_Installer.exe"
    zip_path = REPO_ROOT / "dist" / f"ForeverSuite-{tag}.zip"

    if not args.skip_gh_release:
        title = format_release_title(REPO_ROOT, tag, include_auto_suffix=True)
        if _gh_release_exists(tag, args.repo_slug):
            _run(
                [
                    "gh",
                    "release",
                    "upload",
                    tag,
                    str(exe_path),
                    str(zip_path),
                    "--repo",
                    args.repo_slug,
                    "--clobber",
                ]
            )
            _run(["gh", "release", "edit", tag, "--repo", args.repo_slug, "--title", title, "--draft=false", "--latest"])
        else:
            # Draft first -> attach & verify -> publish atomically (prevents partial-asset publish race)
            _run(
                [
                    "gh",
                    "release",
                    "create",
                    tag,
                    str(exe_path),
                    str(zip_path),
                    "--repo",
                    args.repo_slug,
                    "--target",
                    "main",
                    "--title",
                    title,
                    "--generate-notes",
                    "--draft",
                ]
            )
            _run(["gh", "release", "edit", tag, "--repo", args.repo_slug, "--draft=false", "--latest"])
        _run(["git", "fetch", "--tags"])

    if not args.skip_mail:
        mail_res = dispatch_release_notification(
            REPO_ROOT,
            version=target_ver,
            repo_slug=args.repo_slug,
            verify_downloads=not args.skip_gh_release,
            force=args.force_mail,
        )
        print("[MAIL]", mail_res)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="End-to-end ForeverSuite release & mailing pipeline.")
    parser.add_argument("--bump", default=None, help="patch | minor | major | X.Y.Z")
    parser.add_argument("-m", "--message", default=None, help="Commit message override")
    parser.add_argument("--repo-slug", default=DEFAULT_REPO_SLUG, help="GitHub owner/repo slug")
    parser.add_argument("--pytest-bin", default=None, help="Path to pytest binary")
    parser.add_argument("--skip-mac-deploy", action="store_true")
    parser.add_argument("--skip-git", action="store_true")
    parser.add_argument("--skip-gh-release", action="store_true")
    parser.add_argument("--skip-mail", action="store_true")
    parser.add_argument("--force-mail", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    return run_release_pipeline(args)


if __name__ == "__main__":
    raise SystemExit(main())

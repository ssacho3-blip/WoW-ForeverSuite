"""BDD/DDT tests for automated release verification, version bump parity, and idempotent release mailing."""

from __future__ import annotations

import pathlib
import sys

import pytest

try:
    import yaml  # type: ignore
except ImportError:
    yaml = None

TESTS_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from notify_release import (  # noqa: E402
    dispatch_release_notification,
    extract_changelog_section,
    load_recipients,
    parse_recipients,
    read_sent_ledger,
    render_release_email,
    sha256_bytes,
)
from release import compute_next_version, format_release_title, sync_version_strings  # noqa: E402


def _make_dist_repo(tmp_path: pathlib.Path, version: str = "0.3.3") -> pathlib.Path:
    repo = tmp_path / "repo"
    (repo / "ForeverSuite" / "Core").mkdir(parents=True)
    (repo / "ForeverSuite_GJBridge").mkdir(parents=True)
    (repo / "scripts").mkdir(parents=True)
    (repo / "dist").mkdir(parents=True)

    (repo / "ForeverSuite" / "ForeverSuite.toc").write_text(f"## Version: {version}\n", encoding="utf-8")
    (repo / "ForeverSuite_GJBridge" / "ForeverSuite_GJBridge.toc").write_text(
        f"## Version: {version}\n", encoding="utf-8"
    )
    (repo / "ForeverSuite" / "Core" / "Init.lua").write_text(
        f'local function R()\n    local ver = "{version}"\nend\n', encoding="utf-8"
    )
    (repo / "ForeverSuite_GJBridge" / "State.lua").write_text(
        f'ns.VERSION = "{version}"\n', encoding="utf-8"
    )
    (repo / "scripts" / "build_win_exe.py").write_text(
        f'def read_suite_version(repo_root, default: str = "{version}") -> str:\n    return default\n'
        f'def build_embedded_ps1_script(manifest, zip_b64, suite_version: str = "{version}") -> str:\n    return ""\n',
        encoding="utf-8",
    )
    (repo / "CHANGELOG.md").write_text(
        f"# Changelog\n\n## [{version}] - 2026-11-17\n- Automated release test note\n\n## [0.3.2] - 2026-11-16\n- Old\n",
        encoding="utf-8",
    )
    (repo / "dist" / "ForeverSuite_Installer.exe").write_bytes(b"MZ_FAKE_INSTALLER_" + version.encode())
    (repo / "dist" / f"ForeverSuite-v{version}.zip").write_bytes(b"PK_FAKE_ZIP_" + version.encode())
    return repo


def test_parse_and_load_recipients_dedup_and_validation(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert parse_recipients([" Alice@Example.com ", "alice@example.com", "bob@test.org", ""]) == [
        "Alice@Example.com",
        "bob@test.org",
    ]
    with pytest.raises(ValueError, match="Invalid recipient"):
        parse_recipients(["not-an-email"])

    cfg = tmp_path / "recipients.json"
    cfg.write_text('{"recipients": ["one@example.org", "two@example.net"]}', encoding="utf-8")
    monkeypatch.delenv("FOREVERSUITE_RELEASE_RECIPIENTS", raising=False)
    assert load_recipients(recipients_file=cfg) == ["one@example.org", "two@example.net"]

    monkeypatch.setenv("FOREVERSUITE_RELEASE_RECIPIENTS", "env1@example.org, env2@example.net")
    assert load_recipients(recipients_file=cfg) == ["env1@example.org", "env2@example.net"]


def test_extract_changelog_and_email_rendering() -> None:
    md = "## [0.3.3] - 2026-11-17\n- Fix A\n- Fix B\n\n## [0.3.2] - 2026-11-16\n- Old C\n"
    section = extract_changelog_section(md, "0.3.3")
    assert "Fix A" in section and "Old C" not in section

    subject, text, html_body = render_release_email(
        "0.3.3",
        section,
        138241,
        "a" * 64,
        82276,
        "b" * 64,
    )
    assert "v0.3.3" in subject
    assert "https://github.com/ssacho3-blip/WoW-ForeverSuite/releases/download/v0.3.3/ForeverSuite_Installer.exe" in text
    assert "ForeverSuite-v0.3.3.zip" in html_body
    assert "a" * 64 in text and "b" * 64 in html_body


def test_dispatch_fails_closed_on_sha_mismatch_and_prevents_duplicates(tmp_path: pathlib.Path) -> None:
    repo = _make_dist_repo(tmp_path, "0.3.4")
    ledger_path = tmp_path / "sent_releases.json"

    def bad_verifier(url: str, expected_sha: str, expected_size: int | None) -> tuple[int, str, int]:
        raise RuntimeError(f"SHA-256 mismatch for {url}")

    with pytest.raises(RuntimeError, match="SHA-256 mismatch"):
        dispatch_release_notification(
            repo,
            recipients=["user@example.com"],
            sent_ledger_path=ledger_path,
            url_verifier=bad_verifier,
        )
    assert not ledger_path.exists()

    def ok_verifier(url: str, expected_sha: str, expected_size: int | None) -> tuple[int, str, int]:
        return 200, expected_sha, expected_size or 0

    sent_calls: list[tuple[list[str], str]] = []

    def fake_gmail(recipients, subject, text_body, html_body, **_kwargs):
        sent_calls.append((list(recipients), subject))
        return [f"msg-{i}" for i in range(len(recipients))]

    dry = dispatch_release_notification(
        repo,
        recipients=["u1@example.com", "u2@example.com"],
        sent_ledger_path=ledger_path,
        url_verifier=ok_verifier,
        dry_run=True,
        gmail_sender=fake_gmail,
    )
    assert dry["status"] == "dry_run"
    assert sent_calls == []

    monkeypatch_env = pytest.MonkeyPatch()
    monkeypatch_env.setenv("GMAIL_TOKEN_JSON", '{"token":"x"}')
    try:
        res1 = dispatch_release_notification(
            repo,
            recipients=["u1@example.com", "u2@example.com"],
            sent_ledger_path=ledger_path,
            url_verifier=ok_verifier,
            transport="gmail",
            gmail_sender=fake_gmail,
        )
    finally:
        monkeypatch_env.undo()

    assert res1["status"] == "sent"
    assert len(sent_calls) == 2
    assert read_sent_ledger(ledger_path)["v0.3.4"]["exe_sha256"] == sha256_bytes(
        (repo / "dist" / "ForeverSuite_Installer.exe").read_bytes()
    )

    # Re-running without --force must skip duplicate delivery
    res2 = dispatch_release_notification(
        repo,
        recipients=["u1@example.com", "u2@example.com"],
        sent_ledger_path=ledger_path,
        url_verifier=ok_verifier,
        transport="gmail",
        gmail_sender=fake_gmail,
    )
    assert res2["status"] == "skipped_already_sent"
    assert len(sent_calls) == 2


def test_version_bump_and_6point_sync_helper(tmp_path: pathlib.Path) -> None:
    assert compute_next_version("0.3.3", "patch") == "0.3.4"
    assert compute_next_version("0.3.3", "minor") == "0.4.0"
    assert compute_next_version("0.3.3", "major") == "1.0.0"
    assert compute_next_version("0.3.3", "1.2.3") == "1.2.3"

    repo = _make_dist_repo(tmp_path, "0.3.3")
    changed = sync_version_strings(repo, "0.3.4")
    assert len(changed) == 5
    assert "## Version: 0.3.4" in (repo / "ForeverSuite" / "ForeverSuite.toc").read_text(encoding="utf-8")
    assert "## Version: 0.3.4" in (repo / "ForeverSuite_GJBridge" / "ForeverSuite_GJBridge.toc").read_text(encoding="utf-8")
    assert 'ver = "0.3.4"' in (repo / "ForeverSuite" / "Core" / "Init.lua").read_text(encoding="utf-8")
    assert 'ns.VERSION = "0.3.4"' in (repo / "ForeverSuite_GJBridge" / "State.lua").read_text(encoding="utf-8")
    assert 'default: str = "0.3.4"' in (repo / "scripts" / "build_win_exe.py").read_text(encoding="utf-8")

    # Shared release title formatting & fail-closed pinned_upstream validation
    assert format_release_title(repo, "v0.3.4") == "ForeverSuite v0.3.4"
    (repo / "pinned_upstream.json").write_text('{"version": "5.278"}', encoding="utf-8")
    assert format_release_title(repo, "v0.3.4") == "ForeverSuite v0.3.4 + 갓존슨 v5.278"
    assert format_release_title(repo, "v0.3.4", include_auto_suffix=True) == "ForeverSuite v0.3.4 + 갓존슨 v5.278 — 자동 릴리스 패키지"
    (repo / "pinned_upstream.json").write_text('{"version": null}', encoding="utf-8")
    with pytest.raises(ValueError, match="Invalid upstream version"):
        format_release_title(repo, "v0.3.4")


def test_release_workflow_yaml_and_zero_pii_leak() -> None:
    wf_path = REPO_ROOT / ".github" / "workflows" / "release.yml"
    assert wf_path.is_file()
    raw_wf = wf_path.read_text(encoding="utf-8")
    if yaml is not None:
        wf = yaml.safe_load(raw_wf)
        triggers = wf.get("on") or wf.get(True)
        assert "push" in triggers and "workflow_dispatch" in triggers
    assert "tags:" in raw_wf and "workflow_dispatch:" in raw_wf
    assert "scripts/notify_release.py" in raw_wf
    assert '--target "$TAG"' not in raw_wf
    assert '--target "$TARGET_SHA"' in raw_wf
    assert "--verify-tag" in raw_wf
    assert "refs/tags/" in raw_wf
    assert "format_release_title" in raw_wf

    # Zero real email addresses leaked inside public repo automation files
    for rel in (
        ".github/workflows/release.yml",
        "scripts/notify_release.py",
        "scripts/release.py",
    ):
        txt = (REPO_ROOT / rel).read_text(encoding="utf-8").lower()
        assert "illian" not in txt
        assert "ssacho3@" not in txt
        assert "hanmail" not in txt


def test_partial_recipient_failure_checkpoints_ledger_without_duplicating(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    repo = _make_dist_repo(tmp_path, "0.3.5")
    ledger_path = tmp_path / "sent_releases.json"
    monkeypatch.setenv("GMAIL_TOKEN_JSON", '{"token":"x"}')

    def ok_verifier(url: str, expected_sha: str, expected_size: int | None) -> tuple[int, str, int]:
        return 200, expected_sha, expected_size or 0

    calls: list[str] = []

    def flaky_gmail(recipients, *_args, **_kwargs):
        addr = recipients[0]
        calls.append(addr)
        if addr == "second@example.com" and calls.count("second@example.com") == 1:
            raise RuntimeError("transient_smtp_error")
        return [f"id:{addr}"]

    with pytest.raises(RuntimeError, match="transient_smtp_error"):
        dispatch_release_notification(
            repo,
            recipients=["first@example.com", "second@example.com"],
            sent_ledger_path=ledger_path,
            url_verifier=ok_verifier,
            transport="gmail",
            gmail_sender=flaky_gmail,
        )

    # First recipient was already checkpointed; retry must ONLY email second@example.com
    res = dispatch_release_notification(
        repo,
        recipients=["first@example.com", "second@example.com"],
        sent_ledger_path=ledger_path,
        url_verifier=ok_verifier,
        transport="gmail",
        gmail_sender=flaky_gmail,
    )
    assert res["status"] == "sent"
    assert res["recipient_count"] == 1
    assert calls == ["first@example.com", "second@example.com", "second@example.com"]


def test_corrupt_ledger_fails_closed(tmp_path: pathlib.Path) -> None:
    repo = _make_dist_repo(tmp_path, "0.3.6")
    ledger_path = tmp_path / "sent_releases.json"
    ledger_path.write_text('["not-an-object"]', encoding="utf-8")

    with pytest.raises(ValueError, match="Corrupted sent ledger"):
        dispatch_release_notification(
            repo,
            recipients=["a@example.com"],
            sent_ledger_path=ledger_path,
            verify_downloads=False,
        )

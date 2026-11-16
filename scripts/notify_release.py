#!/usr/bin/env python3
"""Verify GitHub Release assets (HTTP 200 + SHA-256) and send ForeverSuite release emails idempotently."""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import os
import pathlib
import re
import smtplib
import ssl
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from typing import Callable, Iterable

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from build_win_exe import read_suite_version  # noqa: E402

DEFAULT_REPO_SLUG = "ssacho3-blip/WoW-ForeverSuite"
DEFAULT_CONFIG_DIR = pathlib.Path.home() / ".config" / "foreversuite"
DEFAULT_RECIPIENTS_FILE = DEFAULT_CONFIG_DIR / "recipients.json"
DEFAULT_SENT_LEDGER = DEFAULT_CONFIG_DIR / "sent_releases.json"
DEFAULT_GMAIL_TOKEN = pathlib.Path.home() / ".hermes" / "google_token.json"
EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def sha256_bytes(data: bytes) -> str:
    """Return lowercase hex SHA-256 digest for raw bytes."""
    return hashlib.sha256(data).hexdigest().lower()


def extract_changelog_section(changelog_text: str, version: str) -> str:
    """Extract the Markdown body for `## [version]` from CHANGELOG.md, or return empty string."""
    pattern = re.compile(
        rf"^##\s*\[{re.escape(version)}\][^\n]*\n(.*?)(?=^##\s*\[|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(changelog_text)
    return match.group(1).strip() if match else ""


def parse_recipients(raw_list: Iterable[str]) -> list[str]:
    """Normalize, deduplicate, and validate a sequence of email addresses."""
    seen: set[str] = set()
    cleaned: list[str] = []
    for item in raw_list:
        addr = item.strip()
        if not addr:
            continue
        if not EMAIL_RE.fullmatch(addr):
            raise ValueError(f"Invalid recipient email address: {addr!r}")
        key = addr.lower()
        if key not in seen:
            seen.add(key)
            cleaned.append(addr)
    return cleaned


def load_recipients(
    cli_recipients: str | None = None,
    recipients_file: pathlib.Path | None = None,
) -> list[str]:
    """Load recipients from CLI flag, `FOREVERSUITE_RELEASE_RECIPIENTS` env, or local config file."""
    if cli_recipients:
        return parse_recipients(cli_recipients.split(","))

    env_raw = os.getenv("FOREVERSUITE_RELEASE_RECIPIENTS", "").strip()
    if env_raw:
        return parse_recipients(env_raw.split(","))

    cfg_path = recipients_file or pathlib.Path(
        os.getenv("FOREVERSUITE_RECIPIENTS_FILE", str(DEFAULT_RECIPIENTS_FILE))
    )
    if cfg_path.is_file():
        payload = json.loads(cfg_path.read_text(encoding="utf-8"))
        raw = payload.get("recipients", []) if isinstance(payload, dict) else payload
        if isinstance(raw, list):
            return parse_recipients(str(x) for x in raw)
    return []


def read_sent_ledger(ledger_path: pathlib.Path) -> dict[str, dict]:
    """Read sent release ledger JSON safely (fail-closed on malformed root or entry types)."""
    if not ledger_path.is_file():
        return {}
    data = json.loads(ledger_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Corrupted sent ledger (expected object): {ledger_path}")
    for tag_key, entry in data.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("recipients", []), list):
            raise ValueError(f"Corrupted sent ledger entry for {tag_key!r}: {ledger_path}")
    return data


def write_json_atomic(path: pathlib.Path, payload: dict) -> None:
    """Atomically write JSON with 0600 permissions inside existing parent dir."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    tmp_path = pathlib.Path(tmp_name)
    try:
        os.chmod(tmp_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
        os.replace(tmp_path, path)
    finally:
        tmp_path.unlink(missing_ok=True)


def fetch_and_verify_url(
    url: str,
    expected_sha256: str,
    expected_size: int | None = None,
    timeout: float = 30.0,
    retries: int = 3,
    retry_delay: float = 2.0,
) -> tuple[int, str, int]:
    """Download release asset over HTTPS (retrying transient 404/5xx propagation) and verify SHA-256."""
    import time

    if not url.startswith("https://"):
        raise ValueError(f"Refusing non-HTTPS asset URL: {url}")

    last_err: Exception | None = None
    for attempt in range(1, max(1, retries) + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ForeverSuite-ReleaseVerifier/1.0"})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = getattr(resp, "status", None) or resp.getcode()
                if int(status) != 200:
                    raise RuntimeError(f"Expected HTTP 200 for {url}, got {status}")
                data = resp.read()
            actual_sha = sha256_bytes(data)
            if actual_sha != expected_sha256.lower():
                raise RuntimeError(f"SHA-256 mismatch for {url}: expected={expected_sha256} actual={actual_sha}")
            if expected_size is not None and len(data) != expected_size:
                raise RuntimeError(f"Size mismatch for {url}: expected={expected_size} actual={len(data)}")
            return int(status), actual_sha, len(data)
        except (urllib.error.HTTPError, urllib.error.URLError) as exc:
            last_err = exc
            if isinstance(exc, urllib.error.HTTPError) and exc.code not in (404, 429, 500, 502, 503, 504):
                raise
            if attempt < retries:
                time.sleep(retry_delay * attempt)
    assert last_err is not None
    raise last_err


def render_release_email(
    version: str,
    changelog_section: str,
    exe_size: int,
    exe_sha256: str,
    zip_size: int,
    zip_sha256: str,
    repo_slug: str = DEFAULT_REPO_SLUG,
) -> tuple[str, str, str]:
    """Render subject, plain-text body, and HTML body for a verified ForeverSuite release."""
    tag = f"v{version}"
    release_url = f"https://github.com/{repo_slug}/releases/tag/{tag}"
    exe_url = f"https://github.com/{repo_slug}/releases/download/{tag}/ForeverSuite_Installer.exe"
    zip_url = f"https://github.com/{repo_slug}/releases/download/{tag}/ForeverSuite-v{version}.zip"
    notes_clean = changelog_section.strip() or f"- ForeverSuite {tag} 공식 업데이트 및 무결성 검증 완료"

    subject = f"[WoW 포에버] ForeverSuite {tag} 업데이트 안내 — Windows 원클릭 설치 파일"

    text_body = f"""안녕하세요! WoW 포에버(1.60.1) 전용 통합 애드온 ForeverSuite {tag} 및 갓존슨 연동 업데이트가 공식 릴리스되었습니다.
공개 다운로드 정상 작동(HTTP 200)과 SHA-256 무결성 검증을 마친 Windows PC 설치 파일을 안내해 드립니다.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[방법 1 · 권장] Windows 원클릭 자동 설치기 (.exe)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
▶ ForeverSuite_Installer.exe 바로 다운로드 ({exe_size // 1024} KB / {exe_size:,} bytes):
{exe_url}

[Windows PC 설치 순서 — 1분 완료]
1단계. 위 링크를 눌러 ForeverSuite_Installer.exe 를 내려받아 실행합니다.
   * 참고(Windows 보안 안내창): 개인 배포 실행 파일이라 브라우저에서 "일반적으로 다운로드되지 않는 파일" 안내가 뜨면 [⋯] → [유지], 파란색 "Windows의 PC 보호(SmartScreen)" 창에서는 [추가 정보] → [실행]을 눌러 주세요.
2단계. 설치 창이 자동으로 _forever_\\Interface\\AddOns 경로를 찾아 갓존슨 통합 애드온(21개 폴더)과 ForeverSuite {tag} + GJBridge(총 23개 폴더)를 설치하고, 로그온 자동 업데이트(ForeverSuite_AutoUpdate)를 등록합니다.
3단계. "설치 완료" 창이 뜨면 끝입니다. 게임 실행 중이었다면 채팅창에 /reload 만 입력해 주세요.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[방법 2] 자동 업데이트 또는 압축본(.zip) 수동 덮어쓰기
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- 이미 이전에 원클릭 설치기를 실행하셨다면, Windows 재부팅(로그온)만 해도 백그라운드에서 최신 패치가 자동 반영됩니다.
- 직접 압축을 풀어 덮어쓰시려면 아래 압축본을 받아 ForeverSuite, ForeverSuite_GJBridge 두 폴더를 _forever_\\Interface\\AddOns 에 덮어써 주세요.

▶ ForeverSuite-{tag}.zip 바로 다운로드 ({zip_size // 1024} KB / {zip_size:,} bytes):
{zip_url}

▶ GitHub 공식 릴리스 페이지:
{release_url}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{tag} 주요 업데이트 내역
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{notes_clean}

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
배포 파일 무결성 정보 (HTTP 200 & SHA-256 일치 검증 완료)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- ForeverSuite_Installer.exe ({exe_size:,} bytes)
  SHA-256: {exe_sha256}
- ForeverSuite-{tag}.zip ({zip_size:,} bytes)
  SHA-256: {zip_sha256}
"""

    escaped_notes_html = "<br/>".join(html.escape(line) for line in notes_clean.splitlines())
    html_body = f"""<!DOCTYPE html>
<html lang="ko">
<body style="font-family:-apple-system,BlinkMacSystemFont,'Malgun Gothic','Apple SD Gothic Neo',sans-serif;line-height:1.65;color:#1f2937;max-width:720px;margin:0 auto;padding:16px;">
  <p>안녕하세요! WoW 포에버(<code>1.60.1</code>) 전용 통합 애드온 <strong>ForeverSuite {html.escape(tag)}</strong> 업데이트가 공식 릴리스되었습니다.<br/>
  공개 다운로드 정상 작동(HTTP 200)과 SHA-256 무결성 검증을 마친 Windows PC 설치 파일을 안내해 드립니다.</p>

  <div style="border-top:2px solid #d4af37;padding:12px 16px;background:#f8fafc;border-radius:8px;margin:16px 0;">
    <h3 style="margin:0 0 8px;color:#0f172a;">[방법 1 · 권장] Windows 원클릭 자동 설치기 (.exe)</h3>
    <p style="margin:8px 0;">
      <a href="{html.escape(exe_url)}" style="display:inline-block;padding:9px 15px;background:#0f172a;color:#f8fafc;text-decoration:none;border-radius:6px;font-weight:700;">ForeverSuite_Installer.exe 다운로드 ({exe_size // 1024} KB)</a>
    </p>
    <ol style="margin:8px 0 0;padding-left:20px;font-size:14px;">
      <li>위 버튼을 눌러 <code>ForeverSuite_Installer.exe</code>를 내려받아 실행합니다.<br/>
      <span style="color:#475569;font-size:13px;">* 브라우저 "유지" 및 SmartScreen 창에서 <strong>[추가 정보] → [실행]</strong>을 눌러 주세요.</span></li>
      <li>설치기가 자동으로 <code>_forever_\\Interface\\AddOns</code> 경로에 총 23개 폴더를 설치하고, 로그온 자동 업데이트(<code>ForeverSuite_AutoUpdate</code>)를 등록합니다.</li>
      <li>게임 실행 중이었다면 채팅창에 <strong><code>/reload</code></strong> 를 입력하면 즉시 적용됩니다.</li>
    </ol>
  </div>

  <div style="padding:12px 16px;border:1px solid #e2e8f0;border-radius:8px;margin:16px 0;">
    <h3 style="margin:0 0 8px;color:#0f172a;">[방법 2] 자동 업데이트 또는 압축본(.zip) 수동 덮어쓰기</h3>
    <ul style="margin:0;padding-left:20px;font-size:14px;">
      <li>기존 설치 사용자는 Windows 재부팅(로그온)만으로 백그라운드 자동 패치가 반영됩니다.</li>
      <li>수동 설치: <a href="{html.escape(zip_url)}">ForeverSuite-{html.escape(tag)}.zip 다운로드 ({zip_size // 1024} KB)</a> ·
      <a href="{html.escape(release_url)}">GitHub {html.escape(tag)} 릴리스 노트</a></li>
    </ul>
  </div>

  <h3 style="margin:20px 0 8px;color:#0f172a;">{html.escape(tag)} 주요 업데이트 내역</h3>
  <div style="font-size:13.5px;color:#1e293b;background:#f8fafc;padding:12px 14px;border-radius:6px;border:1px solid #e2e8f0;">
    {escaped_notes_html}
  </div>

  <div style="margin-top:18px;padding:10px 14px;background:#f1f5f9;border-radius:6px;font-size:12.5px;color:#334155;">
    <strong>배포 파일 무결성 (HTTP 200 &amp; SHA-256 일치 검증 완료)</strong><br/>
    • <code>ForeverSuite_Installer.exe</code> ({exe_size:,} bytes): <code>{html.escape(exe_sha256)}</code><br/>
    • <code>ForeverSuite-{html.escape(tag)}.zip</code> ({zip_size:,} bytes): <code>{html.escape(zip_sha256)}</code>
  </div>
</body>
</html>
"""
    return subject, text_body, html_body


def send_via_gmail_api(
    recipients: list[str],
    subject: str,
    text_body: str,
    html_body: str,
    token_path: pathlib.Path | None = None,
    token_json_str: str | None = None,
    tag: str | None = None,
    force: bool = False,
) -> list[str]:
    """Send individual MIME emails via Gmail API OAuth credentials (with optional Sent-box dedup)."""
    from google.auth.transport.requests import Request
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build

    if token_json_str:
        info = json.loads(token_json_str)
        creds = Credentials.from_authorized_user_info(info)
    else:
        tpath = token_path or DEFAULT_GMAIL_TOKEN
        if not tpath.is_file():
            raise FileNotFoundError(f"Gmail OAuth token not found: {tpath}")
        creds = Credentials.from_authorized_user_file(str(tpath))

    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())

    service = build("gmail", "v1", credentials=creds)
    msg_ids: list[str] = []
    for recipient in recipients:
        if tag and not force:
            existing = service.users().messages().list(
                userId="me",
                q=f'in:sent to:{recipient} "ForeverSuite {tag} 업데이트 안내"',
                maxResults=1,
            ).execute()
            if existing.get("messages"):
                raise RuntimeError(
                    f"Duplicate release email blocked by Gmail Sent check for {tag} -> {recipient} (use --force to override)"
                )
        msg = MIMEMultipart("alternative")
        msg["To"] = recipient
        msg["Subject"] = subject
        msg.attach(MIMEText(text_body, "plain", "utf-8"))
        msg.attach(MIMEText(html_body, "html", "utf-8"))
        raw = base64.urlsafe_b64encode(msg.as_bytes()).decode("ascii")
        resp = service.users().messages().send(userId="me", body={"raw": raw}).execute()
        msg_ids.append(str(resp.get("id", "")))
    return msg_ids


def send_via_smtp(
    recipients: list[str],
    subject: str,
    text_body: str,
    html_body: str,
    host: str,
    port: int,
    user: str,
    password: str,
    from_addr: str | None = None,
) -> list[str]:
    """Send individual MIME emails over SMTP + STARTTLS (or SSL on 465)."""
    sender = (from_addr or user).strip()
    if not (host and user and password):
        raise ValueError("Missing SMTP credentials (SMTP_HOST, SMTP_USER, SMTP_PASS)")

    context = ssl.create_default_context()
    ids: list[str] = []
    if port == 465:
        server_cm = smtplib.SMTP_SSL(host, port, context=context, timeout=25)
    else:
        server_cm = smtplib.SMTP(host, port, timeout=25)

    with server_cm as server:
        if port != 465:
            server.starttls(context=context)
        server.login(user, password)
        for recipient in recipients:
            msg = MIMEMultipart("alternative")
            msg["From"] = sender
            msg["To"] = recipient
            msg["Subject"] = subject
            msg.attach(MIMEText(text_body, "plain", "utf-8"))
            msg.attach(MIMEText(html_body, "html", "utf-8"))
            server.sendmail(sender, [recipient], msg.as_string())
            ids.append(f"smtp:{recipient}")
    return ids


def dispatch_release_notification(
    repo_root: pathlib.Path,
    *,
    version: str | None = None,
    repo_slug: str = DEFAULT_REPO_SLUG,
    recipients: list[str] | None = None,
    sent_ledger_path: pathlib.Path = DEFAULT_SENT_LEDGER,
    verify_downloads: bool = True,
    dry_run: bool = False,
    force: bool = False,
    transport: str = "auto",
    url_verifier: Callable[[str, str, int | None], tuple[int, str, int]] = fetch_and_verify_url,
    gmail_sender: Callable[..., list[str]] = send_via_gmail_api,
    smtp_sender: Callable[..., list[str]] = send_via_smtp,
) -> dict:
    """Verify release assets, guard against duplicates, and dispatch release emails."""
    resolved_ver = (version or read_suite_version(repo_root)).lstrip("v")
    tag = f"v{resolved_ver}"

    dist_dir = repo_root / "dist"
    exe_path = dist_dir / "ForeverSuite_Installer.exe"
    zip_path = dist_dir / f"ForeverSuite-{tag}.zip"
    if not exe_path.is_file():
        raise FileNotFoundError(f"Missing installer artifact: {exe_path}")
    if not zip_path.is_file():
        raise FileNotFoundError(f"Missing release ZIP artifact: {zip_path}")

    exe_bytes = exe_path.read_bytes()
    zip_bytes = zip_path.read_bytes()
    exe_sha = sha256_bytes(exe_bytes)
    zip_sha = sha256_bytes(zip_bytes)

    if verify_downloads:
        exe_url = f"https://github.com/{repo_slug}/releases/download/{tag}/ForeverSuite_Installer.exe"
        zip_url = f"https://github.com/{repo_slug}/releases/download/{tag}/ForeverSuite-{tag}.zip"
        url_verifier(exe_url, exe_sha, len(exe_bytes))
        url_verifier(zip_url, zip_sha, len(zip_bytes))

    ledger = read_sent_ledger(sent_ledger_path)
    target_recipients = recipients if recipients is not None else load_recipients()
    if not target_recipients:
        raise RuntimeError(
            "No recipients configured (set FOREVERSUITE_RELEASE_RECIPIENTS or ~/.config/foreversuite/recipients.json)"
        )

    prev_entry = ledger.get(tag) if isinstance(ledger.get(tag), dict) else {}
    prev_sent_addrs = {
        str(addr).strip().lower()
        for addr in (prev_entry.get("recipients") or [])
        if str(addr).strip()
    }
    pending_recipients = (
        target_recipients
        if force
        else [r for r in target_recipients if r.lower() not in prev_sent_addrs]
    )
    if not pending_recipients:
        return {
            "status": "skipped_already_sent",
            "version": resolved_ver,
            "tag": tag,
            "previous": prev_entry,
        }

    changelog_path = repo_root / "CHANGELOG.md"
    changelog_text = changelog_path.read_text(encoding="utf-8") if changelog_path.is_file() else ""
    section = extract_changelog_section(changelog_text, resolved_ver)
    subject, text_body, html_body = render_release_email(
        resolved_ver,
        section,
        len(exe_bytes),
        exe_sha,
        len(zip_bytes),
        zip_sha,
        repo_slug=repo_slug,
    )

    if dry_run:
        return {
            "status": "dry_run",
            "version": resolved_ver,
            "tag": tag,
            "recipients_count": len(pending_recipients),
            "subject": subject,
            "exe_sha256": exe_sha,
            "zip_sha256": zip_sha,
        }

    token_env = os.getenv("GMAIL_TOKEN_JSON", "").strip()
    smtp_host = os.getenv("SMTP_HOST", "smtp.gmail.com").strip()
    smtp_port = int(os.getenv("SMTP_PORT", "587").strip() or "587")
    smtp_user = os.getenv("SMTP_USER", "").strip()
    smtp_pass = os.getenv("SMTP_PASS", "").strip()
    smtp_from = os.getenv("SMTP_FROM", smtp_user).strip()

    chosen = transport
    if chosen == "auto":
        if token_env or DEFAULT_GMAIL_TOKEN.is_file():
            chosen = "gmail"
        elif smtp_user and smtp_pass:
            chosen = "smtp"
        else:
            raise RuntimeError("No mail transport credentials found (Gmail OAuth token or SMTP_USER/SMTP_PASS)")

    # Send one recipient at a time & checkpoint ledger after each success so partial failure never duplicates
    msg_ids: list[str] = list(prev_entry.get("message_ids") or [])
    delivered_addrs: list[str] = list(prev_entry.get("recipients") or [])
    for recipient in pending_recipients:
        if chosen == "gmail":
            one_ids = gmail_sender(
                [recipient],
                subject,
                text_body,
                html_body,
                token_path=DEFAULT_GMAIL_TOKEN,
                token_json_str=token_env or None,
                tag=tag,
                force=force,
            )
        elif chosen == "smtp":
            one_ids = smtp_sender(
                [recipient],
                subject,
                text_body,
                html_body,
                host=smtp_host,
                port=smtp_port,
                user=smtp_user,
                password=smtp_pass,
                from_addr=smtp_from,
            )
        else:
            raise ValueError(f"Unsupported transport: {chosen}")
        delivered_addrs.append(recipient)
        msg_ids.extend(one_ids)
        ledger[tag] = {
            "sent_at": datetime.now(timezone.utc).astimezone().isoformat(),
            "recipient_count": len(delivered_addrs),
            "recipients": delivered_addrs,
            "message_ids": msg_ids,
            "transport": chosen,
            "exe_sha256": exe_sha,
            "zip_sha256": zip_sha,
        }
        write_json_atomic(sent_ledger_path, ledger)

    return {
        "status": "sent",
        "version": resolved_ver,
        "tag": tag,
        "transport": chosen,
        "recipient_count": len(pending_recipients),
        "message_ids": msg_ids[-len(pending_recipients):],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify & dispatch ForeverSuite release emails.")
    parser.add_argument("--version", default=None, help="Release version (default: read from ForeverSuite.toc)")
    parser.add_argument("--repo-slug", default=DEFAULT_REPO_SLUG, help="GitHub owner/repo slug")
    parser.add_argument("--recipients", default=None, help="Comma-separated recipient emails override")
    parser.add_argument("--recipients-file", default=None, help="Path to JSON recipients file")
    parser.add_argument("--sent-ledger", default=str(DEFAULT_SENT_LEDGER), help="Path to idempotent sent ledger JSON")
    parser.add_argument("--transport", choices=("auto", "gmail", "smtp"), default="auto")
    parser.add_argument("--skip-download-verify", action="store_true", help="Skip live HTTP 200 + SHA-256 verification")
    parser.add_argument("--dry-run", action="store_true", help="Verify assets and render email without sending")
    parser.add_argument("--force", action="store_true", help="Send even if tag is already recorded in sent ledger")
    args = parser.parse_args(argv)

    explicit_recipients = load_recipients(
        cli_recipients=args.recipients,
        recipients_file=pathlib.Path(args.recipients_file) if args.recipients_file else None,
    )
    result = dispatch_release_notification(
        REPO_ROOT,
        version=args.version,
        repo_slug=args.repo_slug,
        recipients=explicit_recipients,
        sent_ledger_path=pathlib.Path(args.sent_ledger),
        verify_downloads=not args.skip_download_verify,
        dry_run=args.dry_run,
        force=args.force,
        transport=args.transport,
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

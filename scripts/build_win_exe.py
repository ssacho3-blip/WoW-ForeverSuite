#!/usr/bin/env python3
"""Deterministic PE32+ (Windows x64) 1-Click Self-Extracting Installer Builder for ForeverSuite + GodJohnson Bridge."""

from __future__ import annotations

import base64
import io
import json
import os
import pathlib
import struct
import zipfile


class AssemblerX64:
    """Minimal deterministic RIP-relative x86_64 code emitter for the PE32+ launcher stub."""

    def __init__(self, code_rva: int = 0x1000) -> None:
        self.code_rva = code_rva
        self.buf = bytearray()

    @property
    def current_rva(self) -> int:
        return self.code_rva + len(self.buf)

    def emit(self, raw: bytes) -> None:
        self.buf.extend(raw)

    def emit_rip_disp32(self, prefix: bytes, target_rva: int, imm_after: bytes = b"") -> None:
        next_rip = self.current_rva + len(prefix) + 4 + len(imm_after)
        disp32 = target_rva - next_rip
        self.buf.extend(prefix)
        self.buf.extend(struct.pack("<i", disp32))
        self.buf.extend(imm_after)


def build_embedded_ps1_script(manifest: dict, embedded_zip_b64: str) -> str:
    """Generate the PowerShell one-click installer script embedded inside ForeverSuite_Installer.exe."""
    upstream_url = manifest["download_url"]
    upstream_sha256 = manifest["zip_sha256"].lower()
    upstream_version = manifest["version"]
    upstream_filename = manifest["file_name"]

    return f"""$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  WoW Forever 통합 애드온 원클릭 설치기 (v0.2.0)" -ForegroundColor Yellow
Write-Host "  구성: 갓존슨 통합 애드온 (v{upstream_version}, 21개 폴더) + ForeverSuite + GJBridge" -ForegroundColor Gray
Write-Host "=================================================================" -ForegroundColor Cyan

$AddOnsPath = $env:WOW_FOREVER_ADDONS_DIR
if ([string]::IsNullOrWhiteSpace($AddOnsPath)) {{
    $Candidates = @(
        "C:\\Program Files (x86)\\World of Warcraft\\_forever_\\Interface\\AddOns",
        "C:\\Program Files\\World of Warcraft\\_forever_\\Interface\\AddOns",
        "D:\\World of Warcraft\\_forever_\\Interface\\AddOns",
        "E:\\World of Warcraft\\_forever_\\Interface\\AddOns"
    )
    try {{
        $RegPath = "HKLM:\\SOFTWARE\\WOW6432Node\\Blizzard Entertainment\\World of Warcraft"
        if (Test-Path $RegPath) {{
            $Inst = (Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue).InstallPath
            if (-not [string]::IsNullOrWhiteSpace($Inst)) {{
                $Candidates = @((Join-Path $Inst "_forever_\\Interface\\AddOns"), (Join-Path $Inst "Interface\\AddOns")) + $Candidates
            }}
        }}
    }} catch {{}}

    foreach ($Cand in $Candidates) {{
        if (Test-Path $Cand) {{
            $AddOnsPath = $Cand
            break
        }}
    }}
}}

if ([string]::IsNullOrWhiteSpace($AddOnsPath) -or -not (Test-Path $AddOnsPath)) {{
    try {{
        Add-Type -AssemblyName System.Windows.Forms
        $Dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $Dlg.Description = "World of Warcraft\\_forever_\\Interface\\AddOns 폴더를 선택해 주세요."
        $Dlg.ShowNewFolderButton = $true
        if ($Dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {{
            $AddOnsPath = $Dlg.SelectedPath
        }}
    }} catch {{}}
}}

if ([string]::IsNullOrWhiteSpace($AddOnsPath) -or -not (Test-Path $AddOnsPath)) {{
    Write-Host "[ERROR] WoW Forever AddOns 폴더를 찾지 못했습니다." -ForegroundColor Red
    exit 1
}}

Write-Host "[1/4] 대상 설치 경로 확인: $AddOnsPath" -ForegroundColor Green

$CacheDir = Join-Path $env:LOCALAPPDATA "ForeverSuiteCache"
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$UpstreamZip = Join-Path $CacheDir "{upstream_filename}"

$LocalSearch = @()
if (-not [string]::IsNullOrWhiteSpace($env:FS_SELF_EXE)) {{
    $ExeDir = Split-Path -Parent $env:FS_SELF_EXE
    $LocalSearch += (Join-Path $ExeDir "{upstream_filename}")
}}
$LocalSearch += (Join-Path $env:USERPROFILE "Downloads\\{upstream_filename}")
$LocalSearch += $UpstreamZip

$ValidZip = $null
foreach ($CandidateZip in $LocalSearch) {{
    if (Test-Path $CandidateZip) {{
        $Hash = (Get-FileHash -Path $CandidateZip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($Hash -eq "{upstream_sha256}") {{
            $ValidZip = $CandidateZip
            break
        }}
    }}
}}

if ($null -eq $ValidZip) {{
    Write-Host "[2/4] 갓존슨 통합 애드온 (v{upstream_version}) 다운로드 중..." -ForegroundColor Yellow
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "{upstream_url}" -OutFile $UpstreamZip -UseBasicParsing
    $DownloadedHash = (Get-FileHash -Path $UpstreamZip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($DownloadedHash -ne "{upstream_sha256}") {{
        Remove-Item -Force $UpstreamZip -ErrorAction SilentlyContinue
        throw "SHA-256 해시 불일치 차단 (기대값: {upstream_sha256}, 실제값: $DownloadedHash)"
    }}
    $ValidZip = $UpstreamZip
}} else {{
    Write-Host "[2/4] 로컬 캐시된 갓존슨 통합 애드온 (SHA-256 검증 통과) 사용: $ValidZip" -ForegroundColor Green
}}

Write-Host "[3/4] 스테이징 압축 해제 및 무결성 검증 중..." -ForegroundColor Yellow
$StageRoot = Join-Path $AddOnsPath (".ForeverSuite_stage_" + $PID)
$BackupRoot = Join-Path $AddOnsPath ".ForeverSuite_prev_backup"
if (Test-Path $StageRoot) {{ Remove-Item -Recurse -Force $StageRoot }}
New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null

Expand-Archive -Path $ValidZip -DestinationPath $StageRoot -Force

$EmbeddedZipBytes = [Convert]::FromBase64String("{embedded_zip_b64}")
$EmbeddedZipPath = Join-Path $CacheDir "ForeverSuite_Embedded.zip"
[IO.File]::WriteAllBytes($EmbeddedZipPath, $EmbeddedZipBytes)
Expand-Archive -Path $EmbeddedZipPath -DestinationPath $StageRoot -Force

$ExpectedFolders = @("ForeverSuite", "ForeverSuite_GJBridge", "GodJohnsonGoldBorder", "GodJohnsonEngineStartup")
foreach ($Req in $ExpectedFolders) {{
    if (-not (Test-Path (Join-Path $StageRoot $Req))) {{
        Remove-Item -Recurse -Force $StageRoot -ErrorAction SilentlyContinue
        throw "필수 폴더 누락으로 배포 중단: $Req"
    }}
}}

Write-Host "[4/4] 원자적 교체(Atomic Swap) 적용 중..." -ForegroundColor Yellow
if (Test-Path $BackupRoot) {{ Remove-Item -Recurse -Force $BackupRoot }}
New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

Get-ChildItem -Path $StageRoot -Directory | ForEach-Object {{
    $FolderName = $_.Name
    $DestPath = Join-Path $AddOnsPath $FolderName
    $BkPath = Join-Path $BackupRoot $FolderName
    if (Test-Path $DestPath) {{
        Move-Item -Path $DestPath -Destination $BkPath -Force
    }}
    Move-Item -Path $_.FullName -Destination $DestPath -Force
}}

Remove-Item -Recurse -Force $StageRoot -ErrorAction SilentlyContinue
Write-Host "[OK] 갓존슨 통합 애드온(21개) + ForeverSuite + GJBridge 원클릭 설치 완료!" -ForegroundColor Green
try {{
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "설치 완료!`n경로: $AddOnsPath`n`n갓존슨 통합 애드온(v{upstream_version}) 21개 폴더 + ForeverSuite + GJBridge가 안전하게 설치되었습니다.`n게임 접속 후 /fsgj status 및 /fs 명령어로 상태를 확인할 수 있습니다.",
        "WoW Forever 통합 애드온 원클릭 설치 완료",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}} catch {{}}
"""


def build_pe32plus_stub() -> bytes:
    """Construct a valid 64-bit Windows PE32+ executable stub (.text + .data)."""
    text_rva = 0x1000
    data_rva = 0x2000

    # Layout inside .data section (RVA 0x2000 .. 0x2FFF, File Offset 0x400 .. 0x13FF):
    # 0x2000: IMAGE_IMPORT_DESCRIPTOR[0] (KERNEL32.dll) (20 bytes)
    # 0x2014: IMAGE_IMPORT_DESCRIPTOR[1] (Null terminator) (20 bytes)
    # 0x2028: ILT (6 x 8 bytes = 48 bytes: 5 imports + 1 null)
    # 0x2058: IAT (6 x 8 bytes = 48 bytes: 5 imports + 1 null)
    # 0x2088: DLL Name "KERNEL32.dll\0" (16 bytes padded)
    # 0x2098: Hint/Name table (5 functions)
    # 0x2140: envName "FS_SELF_EXE\0"
    # 0x2160: siBuf (STARTUPINFOA, 104 bytes)
    # 0x21D0: piBuf (PROCESS_INFORMATION, 24 bytes)
    # 0x2200: cmdLine (writable command line string, 768 bytes)
    # 0x2500: selfPathBuf (1024 bytes)

    data_sec = bytearray(0x1000)

    def put_data(offset: int, raw: bytes) -> int:
        data_sec[offset : offset + len(raw)] = raw
        return data_rva + offset

    dll_name_rva = put_data(0x0088, b"KERNEL32.dll\x00")

    imports = [
        b"GetModuleFileNameA",
        b"SetEnvironmentVariableA",
        b"CreateProcessA",
        b"WaitForSingleObject",
        b"ExitProcess",
    ]
    hn_offset = 0x0098
    hn_rvas: list[int] = []
    for fn_name in imports:
        entry = struct.pack("<H", 0) + fn_name + b"\x00"
        if len(entry) % 2 == 1:
            entry += b"\x00"
        hn_rvas.append(put_data(hn_offset, entry))
        hn_offset += len(entry)

    ilt_rva = data_rva + 0x0028
    iat_rva = data_rva + 0x0058
    for idx, rva in enumerate(hn_rvas):
        qword = struct.pack("<Q", rva)
        put_data(0x0028 + idx * 8, qword)
        put_data(0x0058 + idx * 8, qword)

    # IMAGE_IMPORT_DESCRIPTOR for KERNEL32.dll
    imp_desc = struct.pack("<IIIII", ilt_rva, 0, 0, dll_name_rva, iat_rva)
    put_data(0x0000, imp_desc)

    env_name_rva = put_data(0x0140, b"FS_SELF_EXE\x00")
    si_rva = data_rva + 0x0160
    pi_rva = data_rva + 0x01D0
    cmd_rva = data_rva + 0x0200
    self_path_rva = data_rva + 0x0500

    ps_bootstrap = (
        b'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'
        b"$raw=[IO.File]::ReadAllBytes($env:FS_SELF_EXE);"
        b"$m=[Text.Encoding]::ASCII.GetBytes('__FS_PS1_START__');"
        b"for($i=$raw.Length-$m.Length;$i -ge 0;$i--){"
        b"$ok=$true;for($j=0;$j -lt $m.Length;$j++){if($raw[$i+$j]-ne $m[$j]){$ok=$false;break}};"
        b"if($ok){$s=[Text.Encoding]::UTF8.GetString($raw,$i+$m.Length,$raw.Length-($i+$m.Length));"
        b"$e=$s.IndexOf('__FS_PS1_END__');if($e -ge 0){$s=$s.Substring(0,$e)};"
        b'Invoke-Expression $s;break}}"\x00'
    )
    put_data(0x0200, ps_bootstrap)

    iat_get_mod = iat_rva + 0 * 8
    iat_set_env = iat_rva + 1 * 8
    iat_create_proc = iat_rva + 2 * 8
    iat_wait = iat_rva + 3 * 8
    iat_exit = iat_rva + 4 * 8

    asm = AssemblerX64(code_rva=text_rva)
    # 1. sub rsp, 0x58
    asm.emit(b"\x48\x83\xEC\x58")
    # 2. GetModuleFileNameA(NULL, selfPathBuf, 1024)
    asm.emit(b"\x31\xC9")  # xor ecx, ecx
    asm.emit_rip_disp32(b"\x48\x8D\x15", self_path_rva)  # lea rdx, [rip + selfPathBuf]
    asm.emit(b"\x41\xB8\x00\x04\x00\x00")  # mov r8d, 1024
    asm.emit_rip_disp32(b"\xFF\x15", iat_get_mod)  # call [rip + GetModuleFileNameA]
    # 3. SetEnvironmentVariableA("FS_SELF_EXE", selfPathBuf)
    asm.emit_rip_disp32(b"\x48\x8D\x0D", env_name_rva)  # lea rcx, [rip + envName]
    asm.emit_rip_disp32(b"\x48\x8D\x15", self_path_rva)  # lea rdx, [rip + selfPathBuf]
    asm.emit_rip_disp32(b"\xFF\x15", iat_set_env)  # call [rip + SetEnvironmentVariableA]
    # 4. CreateProcessA(NULL, cmdLine, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)
    asm.emit_rip_disp32(b"\xC7\x05", si_rva, struct.pack("<I", 104))  # mov dword ptr [rip + si], 104
    asm.emit(b"\x31\xC9")  # xor ecx, ecx
    asm.emit_rip_disp32(b"\x48\x8D\x15", cmd_rva)  # lea rdx, [rip + cmdLine]
    asm.emit(b"\x45\x31\xC0")  # xor r8d, r8d
    asm.emit(b"\x45\x31\xC9")  # xor r9d, r9d
    asm.emit(b"\xC7\x44\x24\x20\x00\x00\x00\x00")  # [rsp+0x20] = 0
    asm.emit(b"\xC7\x44\x24\x28\x00\x00\x00\x00")  # [rsp+0x28] = 0
    asm.emit(b"\x48\xC7\x44\x24\x30\x00\x00\x00\x00")  # [rsp+0x30] = 0
    asm.emit(b"\x48\xC7\x44\x24\x38\x00\x00\x00\x00")  # [rsp+0x38] = 0
    asm.emit_rip_disp32(b"\x48\x8D\x05", si_rva)  # lea rax, [rip + si]
    asm.emit(b"\x48\x89\x44\x24\x40")  # [rsp+0x40] = rax
    asm.emit_rip_disp32(b"\x48\x8D\x05", pi_rva)  # lea rax, [rip + pi]
    asm.emit(b"\x48\x89\x44\x24\x48")  # [rsp+0x48] = rax
    asm.emit_rip_disp32(b"\xFF\x15", iat_create_proc)  # call [rip + CreateProcessA]
    # 5. WaitForSingleObject(pi.hProcess, INFINITE)
    asm.emit_rip_disp32(b"\x48\x8B\x0D", pi_rva)  # mov rcx, qword ptr [rip + pi]
    asm.emit(b"\xBA\xFF\xFF\xFF\xFF")  # mov edx, 0xFFFFFFFF
    asm.emit_rip_disp32(b"\xFF\x15", iat_wait)  # call [rip + WaitForSingleObject]
    # 6. ExitProcess(0)
    asm.emit(b"\x31\xC9")  # xor ecx, ecx
    asm.emit_rip_disp32(b"\xFF\x15", iat_exit)  # call [rip + ExitProcess]

    text_sec = bytearray(0x200)
    text_sec[: len(asm.buf)] = asm.buf

    # Build DOS + PE32+ Headers (0x200 bytes)
    headers = bytearray(0x200)
    headers[0:2] = b"MZ"
    struct.pack_into("<I", headers, 0x3C, 0x80)  # e_lfanew = 0x80
    headers[0x80:0x84] = b"PE\x00\x00"

    # IMAGE_FILE_HEADER (20 bytes at 0x84)
    struct.pack_into(
        "<HHIIIHH",
        headers,
        0x84,
        0x8664,  # Machine = AMD64
        2,  # NumberOfSections = 2
        0,  # TimeDateStamp (deterministic 0)
        0,  # PointerToSymbolTable
        0,  # NumberOfSymbols
        0xF0,  # SizeOfOptionalHeader = 240
        0x0022,  # Characteristics = EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE
    )

    # IMAGE_OPTIONAL_HEADER64 (240 bytes at 0x98)
    opt = bytearray(240)
    struct.pack_into(
        "<HBBIIIIIQIIHHHHHHIIIIHHQQQQII",
        opt,
        0,
        0x020B,  # Magic = PE32+
        14,  # MajorLinkerVersion
        0,  # MinorLinkerVersion
        0x200,  # SizeOfCode
        0x1000,  # SizeOfInitializedData
        0,  # SizeOfUninitializedData
        text_rva,  # AddressOfEntryPoint
        text_rva,  # BaseOfCode
        0x0000000140000000,  # ImageBase
        0x1000,  # SectionAlignment
        0x200,  # FileAlignment
        6,  # MajorOperatingSystemVersion
        0,  # MinorOperatingSystemVersion
        0,  # MajorImageVersion
        0,  # MinorImageVersion
        6,  # MajorSubsystemVersion
        0,  # MinorSubsystemVersion
        0,  # Win32VersionValue
        0x3000,  # SizeOfImage
        0x200,  # SizeOfHeaders
        0,  # CheckSum
        3,  # Subsystem = WINDOWS_CUI
        0x8100,  # DllCharacteristics = NX_COMPAT | TERMINAL_SERVER_AWARE
        0x100000,  # SizeOfStackReserve
        0x1000,  # SizeOfStackCommit
        0x100000,  # SizeOfHeapReserve
        0x1000,  # SizeOfHeapCommit
        0,  # LoaderFlags
        16,  # NumberOfRvaAndSizes
    )
    # DataDirectory[1] = Import Table (RVA 0x2000, Size 40)
    struct.pack_into("<II", opt, 112 + 1 * 8, data_rva, 40)
    # DataDirectory[12] = IAT (RVA 0x2058, Size 48)
    struct.pack_into("<II", opt, 112 + 12 * 8, iat_rva, 48)
    headers[0x98 : 0x98 + 240] = opt

    # Section Headers at 0x188 (2 x 40 bytes)
    sec1 = struct.pack(
        "<8sIIIIIIHHI",
        b".text\x00\x00\x00",
        len(asm.buf),  # VirtualSize
        text_rva,  # VirtualAddress
        0x200,  # SizeOfRawData
        0x200,  # PointerToRawData
        0,
        0,
        0,
        0,
        0x60000020,  # CODE | EXECUTE | READ
    )
    sec2 = struct.pack(
        "<8sIIIIIIHHI",
        b".data\x00\x00\x00",
        0x1000,  # VirtualSize
        data_rva,  # VirtualAddress
        0x1000,  # SizeOfRawData
        0x400,  # PointerToRawData
        0,
        0,
        0,
        0,
        0xC0000040,  # INITIALIZED_DATA | READ | WRITE
    )
    headers[0x188 : 0x188 + 40] = sec1
    headers[0x1B0 : 0x1B0 + 40] = sec2

    return bytes(headers) + bytes(text_sec) + bytes(data_sec)


def _write_single_file_to_zip(zf: zipfile.ZipFile, repo_root: pathlib.Path, file_path: pathlib.Path) -> None:
    if not file_path.is_file() or file_path.name.startswith("."):
        return
    rel_posix = file_path.relative_to(repo_root).as_posix()
    raw = file_path.read_bytes().removeprefix(b"\xef\xbb\xbf").replace(b"\r\n", b"\n")
    zf.writestr(rel_posix, raw)


def _write_addon_folder_to_zip(zf: zipfile.ZipFile, repo_root: pathlib.Path, addon_folder: str) -> None:
    src_dir = repo_root / addon_folder
    for file_path in sorted(src_dir.rglob("*")):
        _write_single_file_to_zip(zf, repo_root, file_path)


def _build_embedded_zip_b64(repo_root: pathlib.Path) -> str:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, mode="w", compression=zipfile.ZIP_DEFLATED) as zf:
        for addon_folder in ("ForeverSuite", "ForeverSuite_GJBridge"):
            _write_addon_folder_to_zip(zf, repo_root, addon_folder)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _resolve_writable_dist_dir(repo_root: pathlib.Path, out_dir: pathlib.Path | None = None) -> pathlib.Path:
    cand = out_dir if out_dir is not None else (repo_root / "dist")
    try:
        cand.mkdir(parents=True, exist_ok=True)
        probe = cand / ".write_probe"
        probe.write_bytes(b"ok")
        probe.unlink(missing_ok=True)
        return cand
    except PermissionError:
        fallback = pathlib.Path("/tmp/ForeverSuite_dist")
        fallback.mkdir(parents=True, exist_ok=True)
        return fallback


def build_windows_installer_exe(repo_root: pathlib.Path, out_dir: pathlib.Path | None = None) -> pathlib.Path:
    """Build dist/ForeverSuite_Installer.exe with embedded ForeverSuite + ForeverSuite_GJBridge payload."""
    manifest_path = repo_root / "pinned_upstream.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    embedded_zip_b64 = _build_embedded_zip_b64(repo_root)
    ps1_script = build_embedded_ps1_script(manifest, embedded_zip_b64)
    pe_stub = build_pe32plus_stub()

    payload = (
        pe_stub
        + b"\n__FS_PS1_START__"
        + ps1_script.encode("utf-8")
        + b"__FS_PS1_END__\n"
    )

    dist_dir = _resolve_writable_dist_dir(repo_root, out_dir)
    final_exe = dist_dir / "ForeverSuite_Installer.exe"
    staging_exe = dist_dir / ".ForeverSuite_Installer.staging.exe"
    staging_exe.write_bytes(payload)
    os.replace(staging_exe, final_exe)
    return final_exe


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    exe_out = build_windows_installer_exe(root)
    print(f"[OK] Built Windows 1-Click Installer EXE: {exe_out} ({exe_out.stat().st_size:,} bytes)")

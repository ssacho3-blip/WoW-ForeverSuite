param(
    [string]$WowForeverAddOnsPath = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir = Join-Path $RepoRoot "ForeverSuite"

if (-not (Test-Path (Join-Path $SrcDir "ForeverSuite.toc"))) {
    throw "ForeverSuite.toc not found at $SrcDir"
}

if ([string]::IsNullOrWhiteSpace($WowForeverAddOnsPath)) {
    $Candidates = @(
        "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns",
        "C:\Program Files\World of Warcraft\_forever_\Interface\AddOns",
        "D:\World of Warcraft\_forever_\Interface\AddOns",
        "E:\World of Warcraft\_forever_\Interface\AddOns"
    )
    foreach ($PathItem in $Candidates) {
        if (Test-Path $PathItem) {
            $WowForeverAddOnsPath = $PathItem
            break
        }
    }
}

if ([string]::IsNullOrWhiteSpace($WowForeverAddOnsPath) -or -not (Test-Path $WowForeverAddOnsPath)) {
    throw "WoW Forever AddOns 폴더를 찾을 수 없습니다. -WowForeverAddOnsPath 인자로 경로를 지정해 주세요."
}

$TargetDir = Join-Path $WowForeverAddOnsPath "ForeverSuite"
$StageDir = Join-Path $WowForeverAddOnsPath ".ForeverSuite_stage_tmp"
$BackupDir = Join-Path $WowForeverAddOnsPath ".ForeverSuite_prev_tmp"

if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
if (Test-Path $BackupDir) { Remove-Item -Recurse -Force $BackupDir }

Copy-Item -Path $SrcDir -Destination $StageDir -Recurse -Force

if (Test-Path $TargetDir) {
    Move-Item -Path $TargetDir -Destination $BackupDir -Force
}
Move-Item -Path $StageDir -Destination $TargetDir -Force

if (Test-Path $BackupDir) {
    Remove-Item -Recurse -Force $BackupDir
}

Write-Host "[OK] ForeverSuite deployed atomically to: $TargetDir" -ForegroundColor Green

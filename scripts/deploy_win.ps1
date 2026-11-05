param(
    [string]$WowForeverAddOnsPath = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$SrcDir = Join-Path $RepoRoot "ForeverSuite"
$BridgeDir = Join-Path $RepoRoot "ForeverSuite_GJBridge"

if (-not (Test-Path (Join-Path $SrcDir "ForeverSuite.toc"))) {
    throw "ForeverSuite.toc not found at $SrcDir"
}
if (-not (Test-Path (Join-Path $BridgeDir "ForeverSuite_GJBridge.toc"))) {
    throw "ForeverSuite_GJBridge.toc not found at $BridgeDir"
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

foreach ($AddonName in @("ForeverSuite", "ForeverSuite_GJBridge")) {
    $AddonSrc = Join-Path $RepoRoot $AddonName
    $TargetDir = Join-Path $WowForeverAddOnsPath $AddonName
    $StageDir = Join-Path $WowForeverAddOnsPath ".$AddonName.stage_tmp"
    $BackupDir = Join-Path $WowForeverAddOnsPath ".$AddonName.prev_tmp"

    if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
    if (Test-Path $BackupDir) { Remove-Item -Recurse -Force $BackupDir }

    Copy-Item -Path $AddonSrc -Destination $StageDir -Recurse -Force

    if (Test-Path $TargetDir) {
        Move-Item -Path $TargetDir -Destination $BackupDir -Force
    }
    Move-Item -Path $StageDir -Destination $TargetDir -Force

    if (Test-Path $BackupDir) {
        Remove-Item -Recurse -Force $BackupDir
    }
    Write-Host "[OK] $AddonName deployed atomically to: $TargetDir" -ForegroundColor Green
}

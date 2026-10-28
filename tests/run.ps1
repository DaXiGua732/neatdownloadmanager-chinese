[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root         = Split-Path -Parent $PSScriptRoot
$Engine       = Join-Path $Root 'ndm_patch.ps1'
$Verifier     = Join-Path $Root 'verify_diff.ps1'
$SourceTable  = Join-Path $Root 'translations.txt'
$RealBackup   = Join-Path $Root 'NeatDM.英文原版.exe.bak'
$RealHashFile = Join-Path $Root 'backup.sha256'
$InstalledExe = Join-Path (Split-Path -Parent $Root) 'NeatDM.exe'
$HasInstalled = Test-Path -LiteralPath $InstalledExe

$OriginalFixture = $null
if (Test-Path -LiteralPath $RealBackup) {
    $OriginalFixture = $RealBackup
} else {
    $cand = Get-ChildItem -LiteralPath (Join-Path $Root 'originals') -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { $OriginalFixture = $cand.FullName }
}
if (-not $OriginalFixture) {
    throw "找不到英文原版 fixture：请保留 NeatDM.英文原版.exe.bak，或先运行 apply 生成 originals/"
}
if (-not (Test-Path -LiteralPath $SourceTable)) { throw "找不到词条表：$SourceTable" }

$Failures = [System.Collections.Generic.List[string]]::new()

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) {
        Write-Host ("  ok   {0}" -f $Name) -ForegroundColor Green
    } else {
        Write-Host ("  FAIL {0} {1}" -f $Name, $Detail) -ForegroundColor Red
        $Failures.Add($Name)
    }
}

function Get-Hash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Invoke-Engine([string]$Mode, [string]$Exe, [string]$Table, [string]$StateDir, [string]$TargetVersion = '') {
    $global:LASTEXITCODE = 0
    $engineParams = @{ Mode = $Mode; Exe = $Exe; Table = $Table; StateDir = $StateDir; Force = $true }
    if ($TargetVersion) { $engineParams['TargetVersion'] = $TargetVersion }
    $out = & $Engine @engineParams 6>&1 | Out-String
    [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
}

function Invoke-Verifier([string]$Orig, [string]$Patched) {
    $global:LASTEXITCODE = 0
    $out = & $Verifier -Orig $Orig -Patched $Patched 6>&1 | Out-String
    [pscustomobject]@{ Output = $out; Code = $LASTEXITCODE }
}

$Temp = Join-Path ([IO.Path]::GetTempPath()) ("ndm-patch-check-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp -Force | Out-Null

try {
    $InstalledBefore = if ($HasInstalled) { Get-Hash $InstalledExe } else { '' }
    $BackupBefore    = Get-Hash $OriginalFixture
    $HashBefore      = if (Test-Path -LiteralPath $RealHashFile) { (Get-Content -LiteralPath $RealHashFile -Raw).Trim() } else { '' }

    $Work  = Join-Path $Temp 'NeatDM.exe'
    $State = Join-Path $Temp 'state'
    $Table = Join-Path $Temp 'translations.txt'
    Copy-Item -LiteralPath $OriginalFixture -Destination $Work
    Copy-Item -LiteralPath $SourceTable -Destination $Table
    New-Item -ItemType Directory -Path $State -Force | Out-Null

    $WorkOrig   = Get-Hash $Work
    $WorkLength = (Get-Item -LiteralPath $Work).Length

    Write-Host ''
    Write-Host '--- status and verify on original ---'
    $r = Invoke-Engine -Mode status -Exe $Work -Table $Table -StateDir $State
    Check 'status exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'status sees 0 translated' ($r.Output -match '已汉化\s*:\s*0')
    Check 'status sees pending entries' ($r.Output -match '待汉化\s*:\s*[1-9]')
    $r = Invoke-Engine -Mode verify -Exe $Work -Table $Table -StateDir $State
    Check 'verify on original exits 5' ($r.Code -eq 5) ("exit=$($r.Code)")

    Write-Host ''
    Write-Host '--- apply on a copy ---'
    $r = Invoke-Engine -Mode apply -Exe $Work -Table $Table -StateDir $State
    Check 'apply exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'apply replaces strings' ($r.Output -match '成功替换\s*:\s*[1-9]')

    $PatchedHash = Get-Hash $Work
    $OrigDir = Join-Path $State 'originals'
    $OrigFiles = @(Get-ChildItem -LiteralPath $OrigDir -Filter '*.exe' -ErrorAction SilentlyContinue)
    Check 'apply changes the copy' ($PatchedHash -ne $WorkOrig)
    Check 'originals directory has one original' ($OrigFiles.Count -eq 1) ("count=$($OrigFiles.Count)")
    if ($OrigFiles.Count -eq 1) {
        Check 'versioned original matches the original' ((Get-Hash $OrigFiles[0].FullName) -eq $WorkOrig)
    }
    Check 'manifest exists' (Test-Path -LiteralPath (Join-Path $OrigDir 'manifest.tsv'))
    Check 'file length unchanged' ((Get-Item -LiteralPath $Work).Length -eq $WorkLength)

    Write-Host ''
    Write-Host '--- verify patched copy ---'
    $r = Invoke-Engine -Mode verify -Exe $Work -Table $Table -StateDir $State
    Check 'verify exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'verify reports all translated' ($r.Output -match '全部\s*\d+\s*条均已汉化')

    Write-Host ''
    Write-Host '--- byte diff ---'
    $r = Invoke-Verifier -Orig $OriginalFixture -Patched $Work
    Check 'byte diff exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'byte diff reports string-only overwrite' ($r.Output -match '所有差异段均为纯 UTF-16 字符串覆写')

    Write-Host ''
    Write-Host '--- second apply is idempotent and does not overwrite the original ---'
    $origHashBefore = if ($OrigFiles.Count -eq 1) { Get-Hash $OrigFiles[0].FullName } else { '' }
    $r = Invoke-Engine -Mode apply -Exe $Work -Table $Table -StateDir $State
    Check 'second apply exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'second apply leaves the patched bytes unchanged' ((Get-Hash $Work) -eq $PatchedHash)
    $origAfter = @(Get-ChildItem -LiteralPath $OrigDir -Filter '*.exe')
    Check 'second apply adds no original' ($origAfter.Count -eq $OrigFiles.Count)
    if ($origAfter.Count -gt 0) { Check 'original file unchanged' ((Get-Hash $origAfter[0].FullName) -eq $origHashBefore) }

    # Keep a patched copy for the refuse-backup test.
    $PatchedCopy = Join-Path $Temp 'NeatDM-patched.exe'
    Copy-Item -LiteralPath $Work -Destination $PatchedCopy

    Write-Host ''
    Write-Host '--- restore ---'
    $r = Invoke-Engine -Mode restore -Exe $Work -Table $Table -StateDir $State
    Check 'restore exits 0' ($r.Code -eq 0) ("exit=$($r.Code)")
    Check 'restore returns the original hash' ((Get-Hash $Work) -eq $WorkOrig)

    Write-Host ''
    Write-Host '--- version mismatch and safe refusal ---'
    $r = Invoke-Engine -Mode status -Exe $Work -Table $Table -StateDir $State -TargetVersion '1.4.25'
    Check 'version mismatch is reported' (($r.Code -eq 0) -and ($r.Output -match '不一致'))
    $EmptyState = Join-Path $Temp 'empty-state'
    New-Item -ItemType Directory -Path $EmptyState -Force | Out-Null
    $r = Invoke-Engine -Mode restore -Exe $Work -Table $Table -StateDir $EmptyState
    Check 'restore without a matching original exits 3' ($r.Code -eq 3) ("exit=$($r.Code)")
    $r = Invoke-Engine -Mode apply -Exe $PatchedCopy -Table $Table -StateDir $EmptyState
    Check 'apply refuses to back up a patched exe' ($r.Code -eq 6) ("exit=$($r.Code)")

    Write-Host ''
    Write-Host '--- overlong entry is reported, skipped, and exits 5 ---'
    $FailWork  = Join-Path $Temp 'NeatDM-overlong.exe'
    $FailState = Join-Path $Temp 'state-overlong'
    $FailTable = Join-Path $Temp 'overlong.txt'
    Copy-Item -LiteralPath $OriginalFixture -Destination $FailWork
    New-Item -ItemType Directory -Path $FailState -Force | Out-Null
    Set-Content -LiteralPath $FailTable -Encoding UTF8 -Value @(
        "Pause`t暂停",
        "Status`t这是一个明显超过原文长度的中文译文"
    )
    $r = Invoke-Engine -Mode apply -Exe $FailWork -Table $FailTable -StateDir $FailState
    Check 'overlong apply exits 5' ($r.Code -eq 5) ("exit=$($r.Code)")
    Check 'overlong report names the entry' (($r.Output -match '译文超出原文长度') -and ($r.Output -match 'Status'))
    $v = Invoke-Engine -Mode verify -Exe $FailWork -Table $FailTable -StateDir $FailState
    Check 'overlong verify exits 5' ($v.Code -eq 5) ("exit=$($v.Code)")
    Check 'overlong entry was not written' ($v.Output -match '\[英文\]\s*Status')
    Check 'valid entry was still applied' ($v.Output -match '\[中文\]\s*暂停')

    Write-Host ''
    Write-Host '--- PowerShell 5.1 and 7 parse/run ---'
    $pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if ($pwshExe) {
        $global:LASTEXITCODE = 0
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $Engine -Mode status -Exe $Work -Table $Table -StateDir $State -Force *> $null
        Check 'PowerShell 7 status exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
    }
    $ps5 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $ps5) {
        $global:LASTEXITCODE = 0
        & $ps5 -NoProfile -ExecutionPolicy Bypass -File $Engine -Mode status -Exe $Work -Table $Table -StateDir $State -Force *> $null
        Check 'PowerShell 5.1 status exits 0' ($LASTEXITCODE -eq 0) ("exit=$LASTEXITCODE")
    }

    Write-Host ''
    Write-Host '--- real files untouched ---'
    if ($HasInstalled) {
        Check 'installed exe unchanged' ((Get-Hash $InstalledExe) -eq $InstalledBefore)
    } else {
        Write-Host '  skip installed exe check (not installed)' -ForegroundColor DarkGray
    }
    Check 'original fixture unchanged' ((Get-Hash $OriginalFixture) -eq $BackupBefore)
    if ((Test-Path -LiteralPath $RealHashFile) -and ($OriginalFixture -eq $RealBackup)) {
        $hashAfter = (Get-Content -LiteralPath $RealHashFile -Raw).Trim()
        Check 'backup hash file unchanged' ($hashAfter -eq $HashBefore)
    } else {
        Write-Host '  skip backup hash file check' -ForegroundColor DarkGray
    }
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($Failures.Count -gt 0) {
    Write-Host ("FAILED: {0} check(s)" -f $Failures.Count) -ForegroundColor Red
    foreach ($f in $Failures) { Write-Host ("  - {0}" -f $f) -ForegroundColor Red }
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green

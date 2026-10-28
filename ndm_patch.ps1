<#
    NDM 汉化补丁引擎
    ---------------------------------------------------------------------------
    用法：
        ndm_patch.ps1 -Mode apply     应用汉化
        ndm_patch.ps1 -Mode restore   恢复英文原版
        ndm_patch.ps1 -Mode status    查看当前汉化状态
        ndm_patch.ps1 -Mode verify    逐条校验当前 exe 中的实际文案
        ndm_patch.ps1 -Mode audit     列出尚未分类的 UI 候选
        -StateDir <dir>               备份、校验和与临时文件目录（默认补丁目录）

    原理：
        NeatDM.exe 把全部界面文案以 UTF-16LE 字面量形式硬编码在 .rdata 段，
        并且没有可替换的语言包文件。中文码位长度普遍短于英文，因此可以原地
        覆写字符串：写入中文 + 空终止符，剩余字节补 0，总长度与原文完全一致。
        PE 结构、导入表、重定位表一律不动，因此不会破坏可执行文件完整性。

    匹配规则（两条都要满足才算命中独立字符串）：
        1. 紧跟在字符串之后必须是 UTF-16 空终止符 0x0000
        2. 字符串之前必须是空终止符，或非字母/数字字符
           —— 第 2 条用来排除 "Status" 命中 "Video Status" 结尾这类误匹配
#>
[CmdletBinding()]
param(
    [ValidateSet('apply', 'restore', 'status', 'verify', 'audit')]
    [string]$Mode = 'status',
    [string]$Exe,
    [string]$Table,
    [string]$KeepFile,
    # 词条表针对的 NDM 版本；用于版本不匹配报告
    [string]$TargetVersion = '1.4.24',
    # 备份、校验和与临时文件的目录；默认补丁目录，测试时可指向临时目录
    [string]$StateDir,
    # 跳过“程序正在运行”检查（仅在你确认 NDM 已退出时使用）
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $StateDir) { $StateDir = $PatchDir }
if (-not $Table) { $Table = Join-Path $PatchDir 'translations.txt' }
if (-not $KeepFile) { $KeepFile = Join-Path $PatchDir 'keep_english.txt' }
if (-not $Exe)   { $Exe = Join-Path (Split-Path -Parent $PatchDir) 'NeatDM.exe' }
$OriginalsDir = Join-Path $StateDir 'originals'
$ManifestFile = Join-Path $OriginalsDir 'manifest.tsv'
$LegacyBackup = Join-Path $StateDir 'NeatDM.英文原版.exe.bak'
$LegacyHashFile = Join-Path $StateDir 'backup.sha256'
$TmpExe = Join-Path $StateDir 'patch_tmp.exe'

function Write-Section($t) {
    Write-Host ''
    Write-Host "===== $t =====" -ForegroundColor Cyan
}

function Unescape([string]$s) {
    return $s.Replace('\r', "`r").Replace('\n', "`n").Replace('\t', "`t").Replace('\\', '\')
}

function Read-Table {
    if (-not (Test-Path -LiteralPath $Table)) { throw "找不到词条表：$Table" }
    $sr = New-Object System.IO.StreamReader($Table, [System.Text.Encoding]::UTF8, $true)
    $raw = $sr.ReadToEnd(); $sr.Close()

    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $i = $line.IndexOf("`t")
        if ($i -lt 0) { continue }
        $en = Unescape $line.Substring(0, $i)
        $rest = $line.Substring($i + 1)
        # 可选的第三列：精确文件偏移，用于紧邻指针表、无法被字面量扫描识别的字符串
        $off = -1
        $j = $rest.IndexOf("`t")
        if ($j -ge 0) {
            $offTxt = $rest.Substring($j + 1).Trim()
            $zh = Unescape $rest.Substring(0, $j)
            if ($offTxt -match '^0[xX][0-9a-fA-F]+$') { $off = [Convert]::ToInt32($offTxt.Substring(2), 16) }
        } else {
            $zh = Unescape $rest
        }
        if ($en.Length -eq 0 -or $zh.Length -eq 0) { continue }
        $pairs.Add([pscustomobject]@{ En = $en; Zh = $zh; Offset = $off })
    }
    return $pairs
}

function Get-RdataRange([byte[]]$buf) {
    $peOff  = [BitConverter]::ToInt32($buf, 0x3C)
    $numSec = [BitConverter]::ToUInt16($buf, $peOff + 6)
    $optSz  = [BitConverter]::ToUInt16($buf, $peOff + 20)
    $secStart = $peOff + 24 + $optSz
    for ($i = 0; $i -lt $numSec; $i++) {
        $o = $secStart + $i * 40
        $name = [System.Text.Encoding]::ASCII.GetString($buf, $o, 8).Trim([char]0)
        if ($name -eq '.rdata') {
            $raw = [int][BitConverter]::ToUInt32($buf, $o + 20)
            $sz  = [int][BitConverter]::ToUInt32($buf, $o + 16)
            return @{ Start = $raw; End = $raw + $sz }
        }
    }
    return @{ Start = 0; End = $buf.Length }
}

function Test-PrecededByBoundary([byte[]]$buf, [int]$i) {
    # 保留：用于调试输出
    if ($i -lt 2) { return $true }
    $pc = [int]$buf[$i - 2] + ([int]$buf[$i - 1] * 256)
    if ($pc -eq 0) { return $true }
    if (($pc -ge 0x41 -and $pc -le 0x5A) -or ($pc -ge 0x61 -and $pc -le 0x7A) -or ($pc -ge 0x30 -and $pc -le 0x39)) {
        return $false
    }
    return $true
}

function Get-StringIndex([byte[]]$buf, [int]$start, [int]$end) {
    # 扫描 .rdata，取出所有“以空终止符结束的极大可打印字符串”，
    # 建立 文本 -> 偏移列表 的索引。之后按文本精确查表，
    # 从根本上杜绝 "Status" 命中 "Video Status" 尾部这类子串误匹配。
    $idx = @{}
    $i = $start
    while ($i -lt $end - 1) {
        $j = $i
        $ok = $true
        while ($j -lt $end - 1) {
            $c = [int]$buf[$j] + ([int]$buf[$j + 1] * 256)
            if ($c -eq 0) { break }
            if (($c -ge 0x20 -and $c -lt 0xFFFD) -or $c -eq 9 -or $c -eq 10 -or $c -eq 13) { $j += 2 }
            else { $ok = $false; break }
        }
        if ($ok -and $j -gt $i -and $j -lt ($end - 1) -and
            [int]$buf[$j] -eq 0 -and [int]$buf[$j + 1] -eq 0) {
            $t = [System.Text.Encoding]::Unicode.GetString($buf, $i, $j - $i)
            if (-not $idx.ContainsKey($t)) {
                $idx[$t] = New-Object System.Collections.Generic.List[int]
            }
            $idx[$t].Add($i)
        }
        $i = if ($j -gt $i) { $j + 2 } else { $i + 2 }
    }
    return $idx
}

function Get-Matches($index, [string]$text) {
    if ($index.ContainsKey($text)) { return $index[$text] }
    return (New-Object System.Collections.Generic.List[int])
}

function Test-StringAt([byte[]]$buf, [string]$text, [int]$off) {
    # 在指定偏移处逐字节比对 UTF-16LE 文本，并要求其后是空终止符
    if ($off -lt 0 -or ($off + $text.Length * 2 + 2) -gt $buf.Length) { return $false }
    $p = [System.Text.Encoding]::Unicode.GetBytes($text)
    for ($m = 0; $m -lt $p.Length; $m++) {
        if ($buf[$off + $m] -ne $p[$m]) { return $false }
    }
    return ([int]$buf[$off + $p.Length] -eq 0 -and [int]$buf[$off + $p.Length + 1] -eq 0)
}

function Read-KeepFile([string]$Path) {
    $keep = New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([System.StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) { return $keep }
    $sr = New-Object System.IO.StreamReader($Path, [System.Text.Encoding]::UTF8, $true)
    $raw = $sr.ReadToEnd(); $sr.Close()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*#') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $i = $line.IndexOf("`t")
        $text = if ($i -ge 0) { $line.Substring(0, $i) } else { $line }
        $text = Unescape $text
        if ($text.Length -gt 0) { $keep[$text] = $true }
    }
    return $keep
}

function Test-UiLike([string]$s) {
    if ($s.Length -lt 2 -or $s.Length -gt 160) { return $false }
    if ($s -notmatch '[A-Za-z]') { return $false }
    if ($s -match '[^\x20-\x7E\r\n\t]') { return $false }
    if ($s -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { return $false }
    if ($s -match '^(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|PRAGMA|BEGIN|COMMIT|ROLLBACK)\b') { return $false }
    if ($s -match '^(api-ms-|ext-ms-|\.\?AV|Mozilla/)') { return $false }
    if ($s -match '^(https?://|www\.)') { return $false }
    if ($s -match '[\\/<>|%]') { return $false }
    if ($s -cmatch '^[A-Z0-9_ .\-]+$' -and $s.Length -gt 12) { return $false }
    if ($s -match '^[a-z]{2}(-[A-Za-z]{2,4})?$') { return $false }
    if ($s -match '^(Sun|Mon|Tue|Wed|Thu|Fri|Sat|Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec|January|February|March|April|June|July|August|September|October|November|December)$') { return $false }
    if ($s -match '^[a-z0-9]+$' -and $s.Length -le 4) { return $false }
    if ($s -match '\s') { return $true }
    if ($s -match '[:.!?]$') { return $true }
    return $false
}

function Test-NdmRunning {
    if ($Force) { return 0 }
    $p = Get-Process -Name 'NeatDM' -ErrorAction SilentlyContinue
    if ($p) { return $p[0].Id } else { return 0 }
}

function Get-ExeInfo([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Version = $item.VersionInfo.ProductVersion
        Hash    = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        Size    = $item.Length
    }
}

function Read-Manifest {
    $list = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $ManifestFile) {
        foreach ($line in (Get-Content -LiteralPath $ManifestFile)) {
            if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -ge 3) {
                $created = if ($parts.Count -ge 4) { $parts[3] } else { '' }
                $list.Add([pscustomobject]@{ Version = $parts[0]; Hash = $parts[1]; File = $parts[2]; Created = $created })
            }
        }
    }
    return ,$list
}

function Save-Manifest($entries) {
    New-Item -ItemType Directory -Path $OriginalsDir -Force | Out-Null
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# version`thash`tfile`tcreated")
    foreach ($e in $entries) {
        $lines.Add(("{0}`t{1}`t{2}`t{3}" -f $e.Version, $e.Hash, $e.File, $e.Created))
    }
    Set-Content -LiteralPath $ManifestFile -Value $lines -Encoding UTF8
}

function Get-OriginalPath($entry) {
    Join-Path $OriginalsDir $entry.File
}

function Find-Original($entries, [string]$Version) {
    $matches = @($entries | Where-Object { $_.Version -eq $Version })
    if ($matches.Count -eq 0) { return $null }
    return $matches[-1]
}

function Initialize-Originals {
    New-Item -ItemType Directory -Path $OriginalsDir -Force | Out-Null
    $entries = Read-Manifest
    if ($entries.Count -eq 0 -and (Test-Path -LiteralPath $LegacyBackup)) {
        $li = Get-ExeInfo $LegacyBackup
        if (Test-Path -LiteralPath $LegacyHashFile) {
            $expect = (Get-Content -LiteralPath $LegacyHashFile -Raw).Trim()
            if ($expect -and $expect -ne $li.Hash) {
                Write-Host "✗ 旧备份校验失败，未迁移：$LegacyBackup" -ForegroundColor Red
                exit 4
            }
        }
        $name = "NeatDM-$($li.Version)-$($li.Hash.Substring(0,8)).exe"
        $dest = Join-Path $OriginalsDir $name
        if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $LegacyBackup -Destination $dest }
        $entries.Add([pscustomobject]@{ Version = $li.Version; Hash = $li.Hash; File = $name; Created = (Get-Date).ToString('s') })
        Save-Manifest $entries
    }
    return ,$entries
}

function Test-IsPatched($index, $pairs) {
    foreach ($p in $pairs) {
        if ((Get-Matches $index $p.Zh).Count -gt 0) { return $true }
    }
    return $false
}

function Ensure-CurrentOriginal($index, $pairs) {
    $entries = Initialize-Originals
    $info = Get-ExeInfo $Exe
    $existing = Find-Original $entries $info.Version
    if ($existing) { return @{ Entries = $entries; Entry = $existing; Info = $info } }
    if (Test-IsPatched $index $pairs) {
        Write-Host ''
        Write-Host ("✗ 当前 exe 已含汉化文案，但找不到版本 {0} 的原版备份。" -f $info.Version) -ForegroundColor Red
        Write-Host '  为避免把已汉化文件当成原版，已拒绝创建备份。' -ForegroundColor Yellow
        exit 6
    }
    $name = "NeatDM-$($info.Version)-$($info.Hash.Substring(0,8)).exe"
    $dest = Join-Path $OriginalsDir $name
    if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $Exe -Destination $dest }
    $entry = [pscustomobject]@{ Version = $info.Version; Hash = $info.Hash; File = $name; Created = (Get-Date).ToString('s') }
    $entries.Add($entry)
    Save-Manifest $entries
    return @{ Entries = $entries; Entry = $entry; Info = $info }
}

# ===========================================================================
if (-not (Test-Path -LiteralPath $Exe)) { throw "找不到主程序：$Exe" }

$pairs = Read-Table
$buf   = [System.IO.File]::ReadAllBytes($Exe)   # 分析阶段始终基于这份原始字节
$rd    = Get-RdataRange $buf
$index = Get-StringIndex $buf $rd.Start $rd.End

$exeInfo = Get-ExeInfo $Exe
Write-Host "主程序 : $Exe"
Write-Host "版本   : $($exeInfo.Version)"
Write-Host "目标版本: $TargetVersion"
if ($exeInfo.Version -notlike "$TargetVersion*") {
    Write-Host "⚠ 当前版本与词条表目标版本不一致：只做精确匹配，未匹配项会列出。" -ForegroundColor Yellow
}
Write-Host "SHA256 : $($exeInfo.Hash)"
Write-Host "大小   : $($buf.Length) 字节"

switch ($Mode) {

    'status' {
        Write-Section '当前状态'
        $done = 0; $todo = 0; $missing = 0; $toolong = 0
        foreach ($p in $pairs) {
            if ($p.Offset -ge 0) {
                if (Test-StringAt $buf $p.En $p.Offset)          { $todo++;  continue }
                if (Test-StringAt $buf $p.Zh $p.Offset)          { $done++;  continue }
            }
            if ((Get-Matches $index $p.En).Count -gt 0) { $todo++; continue }
            if ((Get-Matches $index $p.Zh).Count -gt 0) { $done++; continue }
            if ($p.Zh.Length -gt $p.En.Length) { $toolong++ } else { $missing++ }
        }
        Write-Host ("已汉化   : {0}" -f $done)  -ForegroundColor Green
        Write-Host ("待汉化   : {0}" -f $todo)  -ForegroundColor Yellow
        Write-Host ("未匹配   : {0}" -f $missing)
        Write-Host ("译文超长 : {0}" -f $toolong)
    }

    'verify' {
        Write-Section '逐条校验'
        $bad = 0
        foreach ($p in $pairs) {
            $hasZh = $false; $hasEn = $false
            if ($p.Offset -ge 0) {
                $hasEn = Test-StringAt $buf $p.En $p.Offset
                $hasZh = Test-StringAt $buf $p.Zh $p.Offset
            } else {
                $hasZh = (Get-Matches $index $p.Zh).Count -gt 0
                $hasEn = (Get-Matches $index $p.En).Count -gt 0
            }
            if ($hasZh) {
                Write-Host ("  [中文] {0}" -f $p.Zh)
            } elseif ($hasEn) {
                Write-Host ("  [英文] {0}" -f $p.En) -ForegroundColor Yellow
                $bad++
            } else {
                Write-Host ("  [无]   {0}" -f $p.En) -ForegroundColor DarkGray
                $bad++
            }
        }
        Write-Host ''
        if ($bad -eq 0) {
            Write-Host ("✓ 全部 {0} 条均已汉化。" -f $pairs.Count) -ForegroundColor Green
        } else {
            Write-Host ("✗ 仍有 {0} 条未汉化。" -f $bad) -ForegroundColor Yellow
        }
        if ($bad -gt 0) { exit 5 }
    }

    'audit' {
        Write-Section '覆盖审计'
        $keep = Read-KeepFile $KeepFile
        $tableKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($p in $pairs) { [void]$tableKeys.Add($p.En) }
        $rows = New-Object System.Collections.Generic.List[object]
        $unclassified = 0
        foreach ($kv in $index.GetEnumerator()) {
            $text = [string]$kv.Key
            if ($tableKeys.Contains($text) -or $keep.ContainsKey($text)) { continue }
            $unclassified++
            if (-not (Test-UiLike $text)) { continue }
            $rows.Add([pscustomobject]@{ Offset = $kv.Value[0]; Text = $text })
        }
        $sorted = @($rows | Sort-Object Offset)
        Write-Host ("未分类字面量 : {0}" -f $unclassified)
        Write-Host ("UI 候选       : {0}" -f $sorted.Count) -ForegroundColor Yellow
        Write-Host ("keep-English  : {0}" -f $keep.Count)
        Write-Host ''
        Write-Host ("{0,-10} {1}" -f 'Offset', 'Text')
        foreach ($row in $sorted) {
            Write-Host ("0x{0:X6}  {1}" -f $row.Offset, $row.Text)
        }
    }

    'apply' {
        $pid_ = Test-NdmRunning
        if ($pid_) {
            Write-Host ''
            Write-Host "✗ 检测到 NeatDM 正在运行 (PID $pid_)，无法覆盖程序文件。" -ForegroundColor Red
            Write-Host "  请先在系统托盘中右键 NeatDM 图标 → 退出，然后重新运行本工具。" -ForegroundColor Yellow
            exit 2
        }
        if (-not (Test-Path -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        $orig = Ensure-CurrentOriginal $index $pairs
        $currentOriginalPath = Get-OriginalPath $orig.Entry
        Write-Host ''
        Write-Host "原版备份: $currentOriginalPath" -ForegroundColor Green
        if (-not (Test-Path -LiteralPath $currentOriginalPath)) {
            Write-Host "✗ 原版备份缺失：$currentOriginalPath" -ForegroundColor Red
            exit 3
        }

        # ---------- 阶段一：只读分析（不修改 $buf） ----------
        Write-Section '分析'
        $plan     = New-Object System.Collections.Generic.List[object]
        $already  = New-Object System.Collections.Generic.List[string]
        $missing  = New-Object System.Collections.Generic.List[string]
        $toolong  = New-Object System.Collections.Generic.List[string]

        foreach ($p in $pairs) {
            if ($p.Zh.Length -gt $p.En.Length) {
                $toolong.Add($p.En)
                continue
            }
            # 指定了偏移的条目：先校验该处确实是原文且以空终止符结尾
            if ($p.Offset -ge 0) {
                $okAt = $false
                if ($p.Offset + $p.En.Length * 2 + 2 -le $buf.Length) {
                    $probe = [System.Text.Encoding]::Unicode.GetBytes($p.En)
                    $okAt = $true
                    for ($m = 0; $m -lt $probe.Length; $m++) {
                        if ($buf[$p.Offset + $m] -ne $probe[$m]) { $okAt = $false; break }
                    }
                    if ($okAt -and [int]$buf[$p.Offset + $probe.Length] -ne 0) { $okAt = $false }
                    if ($okAt -and [int]$buf[$p.Offset + $probe.Length + 1] -ne 0) { $okAt = $false }
                }
                if ($okAt) {
                    $lst = New-Object System.Collections.Generic.List[int]
                    $lst.Add($p.Offset)
                    $plan.Add([pscustomobject]@{ Pair = $p; Offsets = $lst })
                    continue
                }
                # 原文已不在（可能被替换过，或偏移失效）
                if (Test-StringAt $buf $p.Zh $p.Offset) {
                    $already.Add($p.En)
                    continue
                }
                $missing.Add($p.En)
                continue
            }
            $hits = Get-Matches $index $p.En
            if ($hits.Count -gt 0) {
                $plan.Add([pscustomobject]@{ Pair = $p; Offsets = $hits })
            } elseif ($p.Offset -lt 0 -and (Get-Matches $index $p.Zh).Count -gt 0) {
                $already.Add($p.En)
            } else {
                $missing.Add($p.En)
            }
        }
        Write-Host ("可替换 : {0} 条" -f $plan.Count)
        Write-Host ("已汉化 : {0} 条" -f $already.Count)
        Write-Host ("未匹配 : {0} 条" -f $missing.Count)
        Write-Host ("超长   : {0} 条" -f $toolong.Count)

        # ---------- 阶段二：写入（检测区间重叠） ----------
        Write-Section '应用汉化'
        $written = New-Object System.Collections.Generic.List[long[]]   # 每项 = @(偏移, 长度)
        $ok = 0
        $conflict = New-Object System.Collections.Generic.List[string]

        foreach ($item in $plan) {
            $en = $item.Pair.En
            $zh = $item.Pair.Zh
            $zhBytes = [System.Text.Encoding]::Unicode.GetBytes($zh)
            $span = $en.Length * 2 + 2

            # 先做重叠预检，任何一处冲突就整条放弃，避免半改半留
            $clash = $false
            foreach ($off in $item.Offsets) {
                foreach ($w in $written) {
                    if ($off -lt ($w[0] + $w[1]) -and $w[0] -lt ($off + $span)) { $clash = $true; break }
                }
                if ($clash) { break }
            }
            if ($clash) {
                $conflict.Add($en)
                continue
            }

            foreach ($off in $item.Offsets) {
                [Array]::Copy($zhBytes, 0, $buf, $off, $zhBytes.Length)
                # 剩余空间补 0：写入中文后的空终止符 + 与原文等长的填充
                for ($k = $off + $zhBytes.Length; $k -lt ($off + $span); $k++) { $buf[$k] = 0 }
                $written.Add([long[]]@([long]$off, [long]$span))
                $ok++
            }
        }

        if ($ok -gt 0) {
            $tmp = $TmpExe
            [System.IO.File]::WriteAllBytes($tmp, $buf)
            Move-Item -LiteralPath $tmp -Destination $Exe -Force
        }
        Write-Host ("成功替换 : {0} 处" -f $ok) -ForegroundColor Green

        if ($conflict.Count -gt 0) {
            Write-Host ''
            Write-Host ("以下 {0} 条与其它条目地址重叠，已跳过：" -f $conflict.Count) -ForegroundColor DarkYellow
            foreach ($c in $conflict) { Write-Host ("    - [{0}]" -f $c) -ForegroundColor DarkGray }
        }
        if ($missing.Count -gt 0) {
            Write-Host ''
            Write-Host ("以下 {0} 条未在当前版本中找到原文（已跳过）：" -f $missing.Count) -ForegroundColor DarkYellow
            foreach ($m in $missing) { Write-Host ("    - [{0}]" -f $m) -ForegroundColor DarkGray }
        }
        if ($toolong.Count -gt 0) {
            Write-Host ''
            Write-Host ("以下 {0} 条译文超出原文长度（请缩短译文）：" -f $toolong.Count) -ForegroundColor DarkYellow
            foreach ($t in $toolong) { Write-Host ("    - [{0}]" -f $t) -ForegroundColor DarkGray }
        }

        # ---------- 阶段三：回读校验 ----------
        Write-Section '回读校验'
        $vbuf = [System.IO.File]::ReadAllBytes($Exe)
        $vrd  = Get-RdataRange $vbuf
        $vidx = Get-StringIndex $vbuf $vrd.Start $vrd.End
        $stillEn = 0
        $remains = New-Object System.Collections.Generic.List[string]
        foreach ($item in $plan) {
            if ($item.Pair.En -eq $item.Pair.Zh) { continue }
            $present = $false
            if ($item.Pair.Offset -ge 0) {
                # 偏移型条目：直接比对该处字节
                $probe = [System.Text.Encoding]::Unicode.GetBytes($item.Pair.En)
                $present = $true
                for ($m = 0; $m -lt $probe.Length; $m++) {
                    if ($vbuf[$item.Pair.Offset + $m] -ne $probe[$m]) { $present = $false; break }
                }
            } else {
                $present = (Get-Matches $vidx $item.Pair.En).Count -gt 0
            }
            if ($present) {
                $stillEn++
                $remains.Add($item.Pair.En)
            }
        }
        if ($stillEn -eq 0) {
            Write-Host ("✓ 全部 {0} 条目标字符串均已替换为中文。" -f $plan.Count) -ForegroundColor Green
        } else {
            Write-Host ("✗ 仍有 {0} 条残留英文：" -f $stillEn) -ForegroundColor Red
            foreach ($r in $remains) { Write-Host ("    - [{0}]" -f $r) -ForegroundColor DarkGray }
        }

        # 结构校验：文件长度与各节大小必须与备份完全一致
        $origSize = (Get-Item -LiteralPath $currentOriginalPath).Length
        $newSize  = (Get-Item -LiteralPath $Exe).Length
        if ($origSize -eq $newSize) {
            Write-Host ("✓ 文件长度未变（{0} 字节），PE 结构完好。" -f $newSize) -ForegroundColor Green
        } else {
            Write-Host ("✗ 文件长度发生变化：{0} -> {1}" -f $origSize, $newSize) -ForegroundColor Red
        }
        $partial = (($missing.Count + $toolong.Count + $conflict.Count) -gt 0) -or ($stillEn -gt 0)
        if ($partial) { exit 5 }
    }

    'restore' {
        $pid_ = Test-NdmRunning
        if ($pid_) {
            Write-Host "✗ 检测到 NeatDM 正在运行 (PID $pid_)，请先完全退出后再恢复。" -ForegroundColor Red
            exit 2
        }
        $entries = Initialize-Originals
        $orig = Find-Original $entries $exeInfo.Version
        if (-not $orig) {
            Write-Host ("✗ 找不到版本 {0} 的原版备份；拒绝恢复以避免降级。" -f $exeInfo.Version) -ForegroundColor Red
            Write-Host "  请从官网重新下载安装该版本。" -ForegroundColor Yellow
            exit 3
        }
        $path = Get-OriginalPath $orig
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host "✗ 原版备份缺失：$path" -ForegroundColor Red
            exit 3
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actual -ne $orig.Hash) {
            Write-Host "✗ 原版备份校验失败，可能已损坏。" -ForegroundColor Red
            exit 4
        }
        Copy-Item -LiteralPath $path -Destination $Exe -Force
        Write-Host ''
        Write-Host "✓ 已恢复英文原版（版本 $($orig.Version)）。" -ForegroundColor Green
    }
}

Write-Host ''
exit 0

param(
  [string]$Orig,
  [string]$Patched
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$a = [System.IO.File]::ReadAllBytes($Orig)
$b = [System.IO.File]::ReadAllBytes($Patched)

if ($a.Length -ne $b.Length) { Write-Host "长度不同: $($a.Length) vs $($b.Length)" -ForegroundColor Red; exit 1 }

$ranges = New-Object System.Collections.Generic.List[object]
$i = 0
while ($i -lt $a.Length) {
    if ($a[$i] -eq $b[$i]) { $i++; continue }
    $s = $i
    while ($i -lt $a.Length -and $a[$i] -ne $b[$i]) { $i++ }
    $ranges.Add([pscustomobject]@{ Start = $s; End = $i - 1 })
}

Write-Host ("原文件 : {0} 字节" -f $a.Length)
Write-Host ("新文件 : {0} 字节" -f $b.Length)
Write-Host ("差异段 : {0} 处，共 {1} 字节" -f $ranges.Count, ($ranges | ForEach-Object { $_.End - $_.Start + 1 } | Measure-Object -Sum).Sum)
Write-Host ''

$bad = 0
foreach ($r in $ranges) {
    # 对齐到 UTF-16 边界
    if (($r.Start % 2) -ne 0) { $bad++; Write-Host ("✗ 0x{0:X} 未对齐" -f $r.Start) -ForegroundColor Red; continue }

    # 读出该处的英文原文与新的中文内容（按 0x0000 截断）
    $j = $r.Start
    $oldChars = @()
    while ($j -lt $b.Length - 1) {
        $c = [int]$a[$j] + ([int]$a[$j + 1] * 256)
        if ($c -eq 0) { break }
        $oldChars += $c; $j += 2
    }
    $j = $r.Start
    $newChars = @()
    while ($j -lt $b.Length - 1) {
        $c = [int]$b[$j] + ([int]$b[$j + 1] * 256)
        if ($c -eq 0) { break }
        $newChars += $c; $j += 2
    }
    $old = -join ($oldChars | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } elseif ($_ -eq 13) { '<CR>' } elseif ($_ -eq 10) { '<LF>' } else { '?' } })
    $new = -join ($newChars | ForEach-Object { [char]$_ })
    $padding = ($r.End - $r.Start + 1) - $newChars.Count * 2
    $isZero = $true
    for ($k = $r.Start + $newChars.Count * 2; $k -le $r.End; $k++) { if ($b[$k] -ne 0) { $isZero = $false; break } }
    if (-not $isZero) { $bad++ }
    "{0}`t{1}`t{2}`tpad={3}{4}" -f ('0x{0:X6}' -f $r.Start), $old, $new, $padding, $(if ($isZero) { '' } else { '  <-- 填充区非零!' })
}
Write-Host ''
if ($bad -eq 0) { Write-Host "✓ 所有差异段均为纯 UTF-16 字符串覆写，填充区全零，无结构破坏。" -ForegroundColor Green }
else { Write-Host "✗ 发现 $bad 处异常。" -ForegroundColor Red; exit 2 }
exit 0

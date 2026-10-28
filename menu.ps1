<#
    NDM 汉化补丁 —— 交互式菜单
    双击“汉化工具.cmd”即可进入本菜单。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Engine = Join-Path $PSScriptRoot 'ndm_patch.ps1'

function Clear-Host2 {
    if (Get-Command Clear-Host -ErrorAction SilentlyContinue) { Clear-Host }
}

while ($true) {
    Clear-Host2
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host '     Neat Download Manager  汉化补丁  (v1.4.24)' -ForegroundColor Cyan
    Write-Host '  ============================================================' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host '    [1]  应用汉化        把界面替换为简体中文' -ForegroundColor White
    Write-Host '    [2]  恢复英文        从备份还原原版程序' -ForegroundColor White
    Write-Host '    [3]  查看状态        当前汉化进度' -ForegroundColor White
    Write-Host '    [4]  逐条校验        列出每一条文案的实际情况' -ForegroundColor White
    Write-Host ''
    Write-Host '    [0]  退出' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '  提示：执行 [1] 和 [2] 之前，请先在系统托盘中右键 NeatDM' -ForegroundColor DarkGray
    Write-Host '        图标选择“退出”，否则程序文件被占用无法覆盖。' -ForegroundColor DarkGray
    Write-Host '  ------------------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
    $c = Read-Host '  请输入编号后回车'

    switch ($c.Trim()) {
        '1' { & $Engine -Mode apply }
        '2' { & $Engine -Mode restore }
        '3' { & $Engine -Mode status }
        '4' { & $Engine -Mode verify }
        '0' { Write-Host ''; Write-Host '  再见。' -ForegroundColor Cyan; return }
        default {
            Write-Host ''
            Write-Host '  无效的编号，请重新输入。' -ForegroundColor Yellow
        }
    }
    Write-Host ''
    $null = Read-Host '  按回车键返回菜单'
}

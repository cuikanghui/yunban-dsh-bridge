# 生成桌面快捷方式（启动 / 设置人格）
# 用法：powershell -ExecutionPolicy Bypass -File tools\make_shortcuts.ps1 [-Dir "程序目录"]
param([string]$Dir = (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)))

$ErrorActionPreference = 'Stop'
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ico = Join-Path $Dir 'data\app.ico'
$desktop = [Environment]::GetFolderPath('Desktop')

function New-Lnk($path, $argLine) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($path)
    $sc.TargetPath = $ps
    $sc.Arguments = [string]$argLine
    $sc.WorkingDirectory = $Dir
    if (Test-Path $ico) { $sc.IconLocation = $ico }
    $sc.Save()
}

New-Lnk (Join-Path $desktop '云班桥接器.lnk') ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $Dir '托盘.ps1') + '"')
New-Lnk (Join-Path $desktop '设置 AI 人格.lnk') ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dir '人格设置.ps1') + '"')

Write-Host "已创建："
Write-Host ("  云班桥接器.lnk     → " + (Join-Path $Dir '托盘.ps1'))
Write-Host ("  设置 AI 人格.lnk   → " + (Join-Path $Dir '人格设置.ps1'))

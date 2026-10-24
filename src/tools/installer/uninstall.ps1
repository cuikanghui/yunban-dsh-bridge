# 云班-DSH 桥接器 · 卸载脚本
$ErrorActionPreference = 'SilentlyContinue'
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 安装目录 = 本脚本所在目录（迁移到任何路径都能正确卸载）
$dest = Split-Path -Parent $MyInvocation.MyCommand.Path
if (!(Test-Path (Join-Path $dest 'bridge\main.js'))) {
    # 兜底：万一被单独拷到别处，回退到老的默认位置
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge'
}

Write-Host ''
Write-Host '=========================================='
Write-Host '  云班-DSH 桥接器  卸载程序'
Write-Host '=========================================='
Write-Host ''
Write-Host "将删除：$dest"
Write-Host '（含登录态、会话映射、日志；不可恢复）'
Write-Host ''
$interactive = $true
try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
$ans = 'n'
if ($interactive) {
    try { $ans = Read-Host '确认卸载？(y/N)' } catch { $ans = 'n' }
} else {
    Write-Host '非交互环境：默认取消（如需静默卸载请直接删除目录）'
}
if ($ans -notmatch '^[Yy]') { Write-Host '已取消'; Start-Sleep -Seconds 1; exit 0 }

Write-Host '停止进程…'
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
    Where-Object { $_.CommandLine -like '*bridge\main.js*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*托盘.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 700

Write-Host '删除快捷方式…'
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) '云班桥接器.lnk') -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) '云班桥接器') -Recurse -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) '云班桥接器.lnk') -Force

Write-Host '删除程序目录…'
Remove-Item $dest -Recurse -Force

Write-Host ''
Write-Host '卸载完成。' -ForegroundColor Green
Start-Sleep -Seconds 2

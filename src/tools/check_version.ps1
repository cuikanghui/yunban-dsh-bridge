# 版本体检：判断当前安装的是「旧版」还是「含 2026-11-07 修复的版本」
# 用法：双击 或 powershell -ExecutionPolicy Bypass -File tools\check_version.ps1
$ErrorActionPreference = 'Continue'
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cands = @(
    $here,
    (Split-Path $here -Parent),
    'D:\大肥鱼\云班桥接器',
    (Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge')
)
$root = $null
foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c '托盘.ps1'))) { $root = $c; break }
}
if (!$root) { Write-Host '找不到安装目录（没看到 托盘.ps1）。把本脚本放回安装目录的 tools\ 下再运行。' -ForegroundColor Red; Read-Host '按回车关闭'; exit 1 }

Write-Host ''
Write-Host '云班桥接器 · 版本体检' -ForegroundColor Cyan
Write-Host ('安装目录：' + $root)
Write-Host ''

# 每项：文件 / 关键标记 / 说明
$checks = @(
    @{ File = '托盘.ps1'; Mark = 'Get-ExternalBridgePid';      What = '托盘能识别"不是自己起的"桥接实例' },
    @{ File = '托盘.ps1'; Mark = 'AppActivate';                What = '人格窗口已开则切过去' },
    @{ File = '托盘.ps1'; Mark = 'tray.log';                   What = '托盘动作落日志' },
    @{ File = '人格设置.ps1'; Mark = 'Apply-Persona';          What = '保存后统一走"写入→核验"流程' },
    @{ File = '人格设置.ps1'; Mark = '看起来是一个文件路径';     What = '拦截"存进一行路径"的误操作' },
    @{ File = '人格设置.ps1'; Mark = 'SmokeTest';              What = '界面冒烟测试' },
    @{ File = 'tools\verify_persona.js'; Mark = 'personaPrefix'; What = '向 DSH 实机核验人格' },
    @{ File = 'uninstall.ps1'; Mark = 'MyInvocation.MyCommand.Path'; What = '卸载脚本按自身位置定位' }
)

$pass = 0; $miss = 0
foreach ($c in $checks) {
    $p = Join-Path $root $c.File
    if (!(Test-Path $p)) {
        Write-Host ('  [缺少] ' + $c.File + '  —— ' + $c.What) -ForegroundColor Red
        $miss++
        continue
    }
    $hit = Select-String -LiteralPath $p -Pattern ([regex]::Escape($c.Mark)) -Quiet -ErrorAction SilentlyContinue
    if ($hit) {
        Write-Host ('  [有] ' + $c.File + '  —— ' + $c.What) -ForegroundColor Green
        $pass++
    } else {
        Write-Host ('  [没有] ' + $c.File + '  —— ' + $c.What) -ForegroundColor Red
        $miss++
    }
}

Write-Host ''
Write-Host ('结果：命中 ' + $pass + ' / 共 ' + $checks.Count + ' 项') -ForegroundColor Cyan
if ($miss -eq 0) {
    Write-Host '  当前是【含 2026-11-07 修复】的版本。' -ForegroundColor Green
} else {
    Write-Host '  当前是【旧版】：缺少上面标红的实现。' -ForegroundColor Yellow
    Write-Host '  → 换用最新版：把仓库里的 src\ 覆盖到本目录（保留 data\ 和 config\），再重启托盘。'
}
Write-Host ''
Write-Host '文件时间（辅助判断）：'
foreach ($f in @('托盘.ps1', '人格设置.ps1')) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Write-Host ('  ' + $f + '  ' + (Get-Item $p).LastWriteTime) }
}
Write-Host ''
Read-Host '按回车关闭'

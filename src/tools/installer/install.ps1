# 云班-DSH 桥接器 · 安装脚本
# 由安装包（IExpress）解压后调用：$PSScriptRoot\app 里是程序本体
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$src  = Join-Path $PSScriptRoot 'app'
# 默认装到 D 盘这个目录；也允许用环境变量 YB_INSTALL_DIR 临时改到别处
$dest = if ($env:YB_INSTALL_DIR) { $env:YB_INSTALL_DIR } else { (Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge') }

function Say($msg) { Write-Host $msg }
function Ok($msg)  { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg){ Write-Host "  [!] $msg" -ForegroundColor Yellow }

Say ''
Say '=========================================='
Say '  云班-DSH 桥接器  安装程序'
Say '=========================================='
Say ''
Say "安装位置：$dest"
Say ''

if (!(Test-Path $src)) { throw "安装包不完整：找不到 $src" }

# ---------- 1) 停掉正在运行的旧版本 ----------
Say '[1/5] 停止正在运行的旧版本…'
$killed = 0
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*bridge\main.js*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*托盘.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }
Start-Sleep -Milliseconds 600
if ($killed -gt 0) { Ok "已停止 $killed 个旧进程" } else { Ok '没有正在运行的实例' }

# ---------- 2) 复制文件（data 目录单独处理，不覆盖登录态） ----------
Say '[2/5] 复制程序文件…'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

$keepData = Join-Path $dest 'data'
$tmpData = Join-Path $env:TEMP ('ybdata_' + [Guid]::NewGuid().ToString('N'))
if (Test-Path $keepData) {
    Copy-Item $keepData $tmpData -Recurse -Force
    Ok '已暂存原有 data 目录（登录态 / 进度）'
}

Copy-Item (Join-Path $src '*') $dest -Recurse -Force -Exclude 'data'

# 恢复 data：只补缺失文件，不覆盖用户数据
New-Item -ItemType Directory -Path $keepData -Force | Out-Null
if (Test-Path $tmpData) {
    Get-ChildItem $tmpData -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($tmpData.Length).TrimStart('\')
        $target = Join-Path $keepData $rel
        if (!(Test-Path $target)) {
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            Copy-Item $_.FullName $target -Force
        }
    }
    Remove-Item $tmpData -Recurse -Force -ErrorAction SilentlyContinue
}
# 补上安装包里自带的 data（图标等）
if (Test-Path (Join-Path $src 'data')) {
    Get-ChildItem (Join-Path $src 'data') -File -ErrorAction SilentlyContinue | ForEach-Object {
        $t = Join-Path $keepData $_.Name
        if (!(Test-Path $t)) { Copy-Item $_.FullName $t -Force }
    }
}

# ---------- 3) 迁移已有登录态（从常见旧路径） ----------
$cookieFile = Join-Path $keepData 'session_cookies.json'
if (!(Test-Path $cookieFile)) {
    $legacy = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge\data\session_cookies.json'),
        (Join-Path $env:USERPROFILE 'Desktop\云班桥接器\data\session_cookies.json')
    )
    foreach ($p in $legacy) {
        if ((Test-Path $p) -and ($p -ne $cookieFile)) {
            Copy-Item $p $cookieFile -Force
            Ok '已复用旧版本的登录态（免重新登录）'
            break
        }
    }
}
if (!(Test-Path $cookieFile)) { Warn '还没有登录态，首次使用需要右键托盘 →「重新登录」' }

Ok "程序已安装到 $dest"

# 卸载脚本必须落到安装目录里，否则开始菜单的「卸载」是个死链接
$unSrc = Join-Path $PSScriptRoot 'uninstall.ps1'
if (Test-Path $unSrc) {
    Copy-Item $unSrc (Join-Path $dest 'uninstall.ps1') -Force
    Ok '已放置卸载脚本 uninstall.ps1'
} else {
    Warn '安装包缺少 uninstall.ps1，「卸载」快捷方式将不可用'
}

# ---------- 4) 快捷方式 ----------
Say '[3/5] 创建快捷方式…'
$ps  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$ico = Join-Path $keepData 'app.ico'
$tray = Join-Path $dest '托盘.ps1'

function New-Lnk($path, $target, $argLine, $workdir, $icon) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($path)
    $sc.TargetPath = $target
    # 注意：参数名不能叫 $args —— 那是 PowerShell 的自动变量（空数组），
    # 写成 $args 会导致 if ($args) 永远为假，快捷方式创建出来没有参数。
    if ($argLine) { $sc.Arguments = [string]$argLine }
    if ($workdir) { $sc.WorkingDirectory = $workdir }
    if ($icon -and (Test-Path $icon)) { $sc.IconLocation = $icon }
    $sc.Save()
}

$trayArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $tray + '"'
$desktop  = Join-Path ([Environment]::GetFolderPath('Desktop')) '云班桥接器.lnk'
New-Lnk $desktop $ps $trayArgs $dest $ico
Ok '桌面快捷方式（启动）'

# 人格设置入口：双击弹出输入框
$personaPs = Join-Path $dest '人格设置.ps1'
if (Test-Path $personaPs) {
    $personaArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $personaPs + '"'
    New-Lnk (Join-Path ([Environment]::GetFolderPath('Desktop')) '设置 AI 人格.lnk') $ps $personaArgs $dest $ico
    Ok '桌面快捷方式（设置 AI 人格）'
}

$smDir = Join-Path ([Environment]::GetFolderPath('Programs')) '云班桥接器'
New-Item -ItemType Directory -Path $smDir -Force | Out-Null
New-Lnk (Join-Path $smDir '启动云班桥接器.lnk') $ps $trayArgs $dest $ico
if (Test-Path $personaPs) {
    New-Lnk (Join-Path $smDir '设置 AI 人格.lnk') $ps $personaArgs $dest $ico
}
New-Lnk (Join-Path $smDir '卸载.lnk') $ps ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dest 'uninstall.ps1') + '"') $dest $ico
Ok '开始菜单项（启动 / 卸载）'

# ---------- 5) 完成 ----------
Say '[4/5] 检查运行环境…'

# Node.js 是硬性前置：程序本体是 Node 脚本，安装包里不包含 Node
$nodePath = $null
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd) { $nodePath = $nodeCmd.Source }
elseif (Test-Path 'C:\Program Files\nodejs\node.exe') { $nodePath = 'C:\Program Files\nodejs\node.exe' }
elseif (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')) { $nodePath = Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe' }

$needNode = $false
if ($nodePath) {
    try {
        $ver = (& $nodePath -v 2>$null) -replace '^v', ''
        $major = [int]($ver.Split('.')[0])
        if ($major -ge 22) { Ok "Node.js v$ver（$nodePath）" }
        else { Warn "Node.js 版本过低：v$ver（需要 18 及以上）"; $needNode = $true }
    } catch { Warn 'Node.js 已找到但无法读取版本'; $needNode = $true }
} else {
    $needNode = $true
}

if ($needNode) {
    Write-Host ''
    Write-Host '  ┌────────────────────────────────────────────────────────┐' -ForegroundColor Red
    Write-Host '  │  ⚠ 缺少 Node.js 22+ —— 装好也无法运行                  │' -ForegroundColor Red
    Write-Host '  │                                                        │' -ForegroundColor Red
    Write-Host '  │  程序本体是 Node 脚本，安装包内不包含 Node 运行时。    │' -ForegroundColor Red
    Write-Host '  │  请先安装： https://nodejs.org/zh-cn/download         │' -ForegroundColor Red
    Write-Host '  │  （一路默认下一步即可，装完重启电脑或重开托盘）        │' -ForegroundColor Red
    Write-Host '  └────────────────────────────────────────────────────────┘' -ForegroundColor Red
    Write-Host ''
}

$dsh = @('D:\DeepSeekHarness','C:\Program Files\DeepSeek Harness', (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) |
       Where-Object { Test-Path (Join-Path $_ 'app\DeepSeek Harness.exe') }
if ($dsh) { Ok "DeepSeek Harness 已安装：$($dsh[0])" }
else { Warn '未找到 DeepSeek Harness。桥接器需要它来生成回答（可设环境变量 DSH_APP_DIR）' }

# 首次登录要借用本机 Chromium 内核浏览器
$browsers = @(
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
) | Where-Object { Test-Path $_ }
if ($browsers) { Ok '浏览器（登录用）：Edge/Chrome 已就绪' }
else { Warn '未找到 Edge/Chrome。首次登录需要一个 Chromium 内核浏览器' }

Say '[5/5] 安装完成'
Say ''
Say '------------------------------------------'
Say '  安装完成！下一步：'
Say '    1) 双击桌面「云班桥接器」启动（或开始菜单 → 云班桥接器）'
Say '    2) 托盘右键 → 重新登录（首次或会话过期时）'
Say '    3) 右键托盘 → 开机自启 / 运行时阻止睡眠（按需勾选）'
if ($needNode) {
    Say ''
    Write-Host '  ⚠ 还差一步：请先安装 Node.js 22+（https://nodejs.org），否则启动会提示「未找到 Node.js」' -ForegroundColor Red
}
Say '------------------------------------------'
Say ''
Say '按任意键关闭（15 秒后自动关闭）…'
# 用 KeyAvailable 轮询：有控制台就等按键，没有控制台立刻跳过，避免脚本卡死
$deadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $deadline) {
    try {
        if ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null; break }
    } catch { break }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 200

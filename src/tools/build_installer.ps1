# 云班-DSH 桥接器 · 打包脚本（生成 .exe 安装包）
# 依赖：只用 Windows 自带的 iexpress.exe + PowerShell 的 Compress-Archive
# 用法：powershell -ExecutionPolicy Bypass -File build_installer.ps1
param(
    [string]$Source = 'D:\大肥鱼\云班桥接器',
    [string]$Out    = 'D:\Build'
)

$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Step($m) { Write-Host "[build] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }

$payloadDir = Join-Path $Out 'payload'
$stageDir   = Join-Path $Out 'stage'
$distDir    = Join-Path $Out 'dist'
$zipPath    = Join-Path $payloadDir 'payload.zip'
$sedPath    = Join-Path $Out 'YunbanBridge.sed'
$exePath    = Join-Path $distDir 'YunbanBridge-Setup.exe'

# ---------- 0) 清理 ----------
Step '清理上次构建产物'
foreach ($d in @($payloadDir, $stageDir)) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
}
New-Item -ItemType Directory -Path $payloadDir, $stageDir, $distDir -Force | Out-Null

# ---------- 1) 准备 app 目录 ----------
Step '复制程序文件（排除 stage0 / 运行数据 / 日志）'
$appStage = Join-Path $stageDir 'app'
New-Item -ItemType Directory -Path $appStage -Force | Out-Null

# 白名单式复制：只带运行必需的东西
$items = @('bridge', 'config', 'tools', 'README.md', '云班桥接器.bat', '托盘.ps1', '人格设置.ps1')
foreach ($it in $items) {
    $p = Join-Path $Source $it
    if (Test-Path $p) {
        Copy-Item $p $appStage -Recurse -Force
        Ok $it
    } else {
        Write-Host "  [skip] 不存在: $it" -ForegroundColor DarkGray
    }
}

# tools 里去掉安装器自身和调试图纸，避免包里有冗余
$toolInstaller = Join-Path $appStage 'tools\installer'
if (Test-Path $toolInstaller) { Remove-Item $toolInstaller -Recurse -Force }
Get-ChildItem (Join-Path $appStage 'tools') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like '*.bak*' -or $_.Extension -eq '.log' -or $_.Name -eq 'build_installer.ps1' } |
    ForEach-Object { Remove-Item $_.FullName -Force }

# 运行数据只带图标
$dataStage = Join-Path $appStage 'data'
New-Item -ItemType Directory -Path $dataStage -Force | Out-Null
$ico = Join-Path $Source 'data\app.ico'
if (Test-Path $ico) { Copy-Item $ico $dataStage -Force; Ok 'data\app.ico' }
else { Write-Host '  [warn] 缺少 data\app.ico（托盘/快捷方式图标），可用默认图标' -ForegroundColor Yellow }

# ---------- 2) 放入安装脚本 ----------
Step '放入安装/卸载脚本'
$instDir = Join-Path $Source 'tools\installer'
Copy-Item (Join-Path $instDir 'install.ps1')   $stageDir -Force
Copy-Item (Join-Path $instDir 'uninstall.ps1') $stageDir -Force
Ok 'install.ps1 / uninstall.ps1'

# ---------- 3) 打 payload.zip ----------
Step '压缩 payload.zip'
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
$zipKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Ok "payload.zip = $zipKB KB"

# ---------- 4) install.cmd（IExpress 的入口，纯 ASCII） ----------
Copy-Item (Join-Path $instDir 'install.cmd') $payloadDir -Force
Ok 'install.cmd'

# ---------- 5) 生成 SED ----------
Step '生成 IExpress 配置'
$sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=0
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exePath
FriendlyName=Yunban Bridge (Cloud Class to DSH)
AppLaunched=install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
SourceFiles=SourceFiles
[Strings]
FILE0="payload.zip"
FILE1="install.cmd"
[SourceFiles]
SourceFiles0=$payloadDir\
[SourceFiles0]
%FILE0%=
%FILE1%=
"@
Set-Content -Path $sedPath -Value $sed -Encoding ASCII
Ok "SED: $sedPath"

# ---------- 6) 构建 EXE ----------
Step '调用 iexpress 生成 EXE（约 10-30 秒）'
if (Test-Path $exePath) { Remove-Item $exePath -Force }
$iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
& $iexpress /N /Q $sedPath | Out-Null
Start-Sleep -Seconds 2

if (Test-Path $exePath) {
    $mb = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
    Write-Host ''
    Write-Host '==========================================' -ForegroundColor Green
    Write-Host "  构建成功：$exePath" -ForegroundColor Green
    Write-Host "  大小：$mb MB" -ForegroundColor Green
    Write-Host '==========================================' -ForegroundColor Green
} else {
    throw '构建失败：没有生成 EXE，检查 iexpress 的输出'
}

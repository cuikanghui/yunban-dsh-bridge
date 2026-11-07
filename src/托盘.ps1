# 云班-DSH 桥接器 · 托盘外壳（Windows 自带 WinForms，无需额外依赖）
# 功能：启停主程序、状态灯、立即检查、看日志、重新登录、开机自启、桌面快捷方式
# 说明：本文件必须保存为 UTF-8 带 BOM，否则 PowerShell 5.1 会把中文读成乱码

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir    = Join-Path $root 'data'
$logDir     = Join-Path $dataDir 'logs'
$statusFile = Join-Path $dataDir 'status.json'
$cookieFile = Join-Path $dataDir 'session_cookies.json'
$forceFile  = Join-Path $dataDir 'force-poll'
$confFile   = Join-Path $root 'config\bridge.json'
$iconFile   = Join-Path $dataDir 'app.ico'
$disabledFlag = Join-Path $dataDir 'disabled.flag'
$keepAwakeFlag = Join-Path $dataDir 'keepawake.flag'

# ---------- 阻止系统睡眠（运行期间） ----------
# 说明：ES_CONTINUOUS 让设置持续生效，ES_SYSTEM_REQUIRED 让系统保持唤醒（屏幕仍可按原设置关闭）。
# 该状态绑在**调用线程**上，所以必须在常驻的 UI 线程里调用，退出时释放。
if (-not ('PowerUtil' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PowerUtil {
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern uint SetThreadExecutionState(uint esFlags);
  public const uint ES_CONTINUOUS = 0x80000000;
  public const uint ES_SYSTEM_REQUIRED = 0x00000001;
}
"@
}

if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# ---------- 单实例 ----------
$mutexName = if ($env:YB_TRAY_MUTEX) { $env:YB_TRAY_MUTEX } else { 'Global\YunbanBridgeTray' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (!$mutex.WaitOne(0)) { exit }

# ---------- 找 node ----------
function Get-NodePath {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("C:\Program Files\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
$script:nodeExe = Get-NodePath
$script:proc = $null
$script:loginProc = $null
$script:stopping = $false
$script:lastStart = [DateTime]::MinValue
$script:check = $null          # 自检状态（非空表示正在自检）
$script:adoptedPid = 0         # 已接管的外部桥接实例 PID（0=无）

function Write-TrayLog([string]$m) {
    try {
        if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        [System.IO.File]::AppendAllText((Join-Path $logDir 'tray.log'),
            ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m))
    } catch { }
}

# ---------- 图标（GDI+ 现画，并存一份 ico 给快捷方式用） ----------
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $b = New-Object System.Drawing.SolidBrush($color)
    $g.FillEllipse($b, 2, 2, 28, 28)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 3)
    $g.DrawEllipse($pen, 2, 2, 28, 28)
    $g.Dispose(); $b.Dispose(); $pen.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:icons = @{
    gray   = New-DotIcon ([System.Drawing.Color]::FromArgb(150,150,150))
    green  = New-DotIcon ([System.Drawing.Color]::FromArgb(46,204,113))
    orange = New-DotIcon ([System.Drawing.Color]::FromArgb(243,156,18))
    red    = New-DotIcon ([System.Drawing.Color]::FromArgb(231,76,60))
}

# 存一份 ico 作为快捷方式图标
try {
    if (!(Test-Path $iconFile)) {
        $fs = [System.IO.File]::Create($iconFile)
        $script:icons.green.Save($fs)
        $fs.Close()
    }
} catch { }

# ---------- 快捷方式 ----------
function New-Shortcut([string]$path, [string]$target, [string]$arguments, [string]$workdir, [string]$icon) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($path)
    $sc.TargetPath = $target
    if ($arguments) { $sc.Arguments = $arguments }
    if ($workdir) { $sc.WorkingDirectory = $workdir }
    if ($icon -and (Test-Path $icon)) { $sc.IconLocation = $icon }
    $sc.Save()
}

function Get-TrayLaunchArgs {
    # 用 powershell -WindowStyle Hidden 启动，避免黑窗口闪一下
    return '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $root '托盘.ps1') + '"'
}

$script:startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '云班桥接器.lnk'
$script:desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '云班桥接器.lnk'

function Test-Autostart { return (Test-Path $script:startupLnk) }

# 总开关：data\disabled.flag 存在 = 整个桥接停用
function Test-Disabled { return (Test-Path $disabledFlag) }

# 防睡眠开关：data\keepawake.flag 存在 = 运行期间阻止系统自动睡眠
function Test-KeepAwake { return (Test-Path $keepAwakeFlag) }

function Set-KeepAwake([bool]$on) {
    try {
        if ($on) {
            Set-Content -Path $keepAwakeFlag -Value ('keepawake since ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
            $r = [PowerUtil]::SetThreadExecutionState([PowerUtil]::ES_CONTINUOUS -bor [PowerUtil]::ES_SYSTEM_REQUIRED)
            if ($r -eq 0) { throw '系统拒绝了防睡眠请求' }
            Show-Balloon '已阻止自动睡眠' '桥接运行期间电脑不会自动睡眠（屏幕仍可关闭）；点「退出」后恢复'
        } else {
            if (Test-Path $keepAwakeFlag) { Remove-Item $keepAwakeFlag -Force }
            [PowerUtil]::SetThreadExecutionState([PowerUtil]::ES_CONTINUOUS) | Out-Null
            Show-Balloon '已恢复系统睡眠策略' '电脑会按原来的电源计划自动睡眠'
        }
    } catch {
        Show-Balloon '操作失败' ([string]$_.Exception.Message)
    }
}

function Set-Disabled([bool]$off) {
    try {
        if ($off) {
            Set-Content -Path $disabledFlag -Value ('disabled at ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
            Stop-Bridge
            $script:proc = $null
            Show-Balloon '桥接已停用' '不会再轮询、也不会调用 DSH；右键「启用桥接」可恢复'
        } else {
            if (Test-Path $disabledFlag) { Remove-Item $disabledFlag -Force }
            $script:lastStart = [DateTime]::MinValue
            Start-Bridge
            Show-Balloon '桥接已启用' '已恢复轮询云班留言'
        }
    } catch {
        Show-Balloon '操作失败' ([string]$_.Exception.Message)
    }
}

function Set-Autostart([bool]$on) {
    try {
        if ($on) {
            New-Shortcut $script:startupLnk "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" (Get-TrayLaunchArgs) $root $iconFile
            Show-Balloon '已开启开机自启' '下次开机将自动在托盘启动'
        } else {
            if (Test-Path $script:startupLnk) { Remove-Item $script:startupLnk -Force }
            Show-Balloon '已关闭开机自启' '不会再随开机启动'
        }
    } catch {
        Show-Balloon '操作失败' ([string]$_.Exception.Message)
    }
}

function New-DesktopShortcut {
    try {
        New-Shortcut $script:desktopLnk "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" (Get-TrayLaunchArgs) $root $iconFile
        # 顺带给「设置 AI 人格」也建一个，双击即可改人格
        $personaPs = Join-Path $root '人格设置.ps1'
        if (Test-Path $personaPs) {
            $personaLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) '设置 AI 人格.lnk'
            $a = '-NoProfile -ExecutionPolicy Bypass -File "' + $personaPs + '"'
            New-Shortcut $personaLnk "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" $a $root $iconFile
        }
        Show-Balloon '桌面快捷方式已创建' '「云班桥接器」启动 / 「设置 AI 人格」改人设'
    } catch {
        Show-Balloon '创建失败' ([string]$_.Exception.Message)
    }
}

# ---------- 状态读取 ----------
function Read-Status {
    if (!(Test-Path $statusFile)) { return $null }
    try { return (Get-Content $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------- 进程控制 ----------
# 兼容性处理：某些环境（被代理注入过）会同时存在 http_proxy 与 HTTP_PROXY，
# Start-Process 复制环境变量时会因大小写重复而抛"重复的键"，先清掉小写那一份。
foreach ($n in @('http_proxy', 'https_proxy', 'no_proxy', 'all_proxy')) {
    if (Test-Path ("Env:" + $n)) { Remove-Item ("Env:" + $n) -ErrorAction SilentlyContinue }
}

# ---------- 进程识别：托盘自己的子进程 vs 已经在跑的实例 ----------
# 桥接是单实例的（data\bridge.lock 里写着持有者 PID）。若它不是「当前这个托盘」启动的
# （托盘重启过、从 bat 启动过、上次托盘异常退出留下孤儿进程），只看 $script:proc
# 就会误判成"已停止"——其实它在正常轮询。这里用 lock 文件把"在跑的实例"认出来。
function Get-BridgeLockPid {
    $lock = Join-Path $dataDir 'bridge.lock'
    if (!(Test-Path $lock)) { return 0 }
    $raw = Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue
    $n = 0
    if ([int]::TryParse(([string]$raw).Trim(), [ref]$n)) { return $n }
    return 0
}

function Get-ExternalBridgePid {
    $id = Get-BridgeLockPid
    if (!$id) { return 0 }
    if ($script:proc -and !$script:proc.HasExited -and $script:proc.Id -eq $id) { return 0 }  # 就是自己的孩子
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'node') { return $id }
    return 0
}

function Get-BridgeStartError {
    # 子进程秒退时，main.js 会把原因打到 console.err.log（例如锁冲突）
    $err = Join-Path $logDir 'console.err.log'
    if (!(Test-Path $err)) { return '' }
    $line = Get-Content -LiteralPath $err -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue
    return ([string]$line).Trim()
}

function Start-Bridge {
    if (Test-Disabled) { return }        # 总开关关着，绝不启动
    if ($script:proc -and !$script:proc.HasExited) { return }
    $ext = Get-ExternalBridgePid
    if ($ext) { return }                 # 已有实例在跑（不是自己起的），不要重复启动去撞锁
    if (!$script:nodeExe) { Show-Balloon '启动失败' '未找到 Node.js（本程序需要 Node 22+）：https://nodejs.org 安装后重启托盘'; return }
    $script:lastStart = Get-Date
    $out = Join-Path $logDir 'console.out.log'
    $err = Join-Path $logDir 'console.err.log'
    try {
        $script:proc = Start-Process -FilePath $script:nodeExe `
            -ArgumentList @('bridge\main.js') `
            -WorkingDirectory $root `
            -WindowStyle Hidden `
            -RedirectStandardOutput $out `
            -RedirectStandardError $err `
            -PassThru
    } catch {
        Show-Balloon '启动失败' ([string]$_.Exception.Message)
    }
    # 自己起来了，就别再记着"接管别人的实例"
    if ($script:proc -and !$script:proc.HasExited) { $script:adoptedPid = 0 }
}

function Stop-Bridge {
    if ($script:proc -and !$script:proc.HasExited) {
        try { Stop-Process -Id $script:proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 600
    }
    # 不是自己起的实例也要能停掉（否则「停用桥接」对孤儿进程无效）
    $ext = Get-ExternalBridgePid
    if ($ext) {
        try { Stop-Process -Id $ext -Force -ErrorAction SilentlyContinue } catch { }
        Start-Sleep -Milliseconds 600
    }
    $script:proc = $null
    $script:adoptedPid = 0
    # 强杀主程序会留下 DSH 子进程（Electron），它们会占着会话写句柄，
    # 下次提问就成了 "session already owned"。这里按命令行特征精准收掉。
    try {
        $stray = @(Get-CimInstance Win32_Process -Filter "Name='DeepSeek Harness.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*cli.js*' -and $_.CommandLine -like '*--profile*' })
        foreach ($x in $stray) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
}

function Start-Login {
    if ($script:loginProc -and !$script:loginProc.HasExited) {
        Show-Balloon '登录窗口已打开' '请在弹出的浏览器里完成登录'
        return
    }
    if (!$script:nodeExe) { Show-Balloon '启动失败' '未找到 Node.js（需要 18+）：https://nodejs.org'; return }
    Stop-Bridge
    # 登录后账号可能已经变了（重新注册/换号），让主程序重新发现班级
    try { Set-Content -Path (Join-Path $dataDir 'rebind.flag') -Value ('after login ' + (Get-Date -Format 'HH:mm:ss')) -Encoding UTF8 } catch { }
    try {
        $script:loginProc = Start-Process -FilePath $script:nodeExe `
            -ArgumentList @('bridge\main.js', '--login') `
            -WorkingDirectory $root `
            -WindowStyle Hidden `
            -PassThru
        Show-Balloon '请登录' '浏览器已打开，登录成功后会自动恢复桥接'
    } catch {
        Show-Balloon '登录失败' ([string]$_.Exception.Message)
    }
}

function Show-Balloon([string]$title, [string]$text) {
    try { $script:tray.ShowBalloonTip(4000, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info) } catch { }
}

# ---------- 回路自检 ----------
# 「立即检查一次」看不清到底通不通，改成逐段自检：
# 登录态 → 云班接口/班级 → DSH 启动与问答 → 会话锁 → 回发通道。
# 自检脚本只输出 NDJSON 进度行，这里边读边更新托盘文字，结束后弹结论。
function Start-SelfCheck {
    if ($script:check) { Show-Balloon '自检进行中' '等这一轮跑完再看结果'; return }
    if (!$script:nodeExe) { Show-Balloon '无法自检' '未找到 Node.js（需要 22+）'; return }

    $progress = Join-Path $dataDir 'selfcheck.progress'
    Remove-Item $progress -Force -ErrorAction SilentlyContinue
    $out = Join-Path $env:TEMP ('yb-selfcheck-' + [Guid]::NewGuid().ToString('N') + '.jsonl')
    try {
        $p = Start-Process -FilePath $script:nodeExe -ArgumentList @('tools\selfcheck.js') `
            -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError ($out + '.err') `
            -PassThru -WindowStyle Hidden
    } catch {
        Show-Balloon '自检启动失败' ([string]$_.Exception.Message)
        return
    }

    $script:check = @{ proc = $p; file = $progress; errFile = ($out + '.err'); read = 0; note = '准备中…'; result = $null }
    $itemCheck.Enabled = $false
    $itemCheck.Text = '自检进行中…'
    $itemStatus.Text = '状态：正在自检 0/5'
    $itemSummary.Text = '自检：启动中…'
    $script:tray.Text = '云班-DSH 桥接器（自检中）'
    $timer.Interval = 500      # 自检期间加快刷新
    Show-Balloon '开始回路自检' '检查：登录态 → 云班接口 → DSH 问答 → 会话锁 → 回发通道'
}

function Update-SelfCheck {
    $c = $script:check

    $raw = ''
    try { if (Test-Path $c['file']) { $raw = [System.IO.File]::ReadAllText($c['file']) } } catch { }

    if ($raw) {
        $lines = @($raw -split "`r?`n" | Where-Object { $_.Trim() })
        for ($i = [int]$c['read']; $i -lt $lines.Count; $i++) {
            $c['read'] = $i + 1
            $o = $null
            try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
            $names = @($o.PSObject.Properties.Name)
            if ($names -contains 'done') { $c['result'] = $o; continue }
            if ($names -contains 'stage') {
                $c['note'] = ('{0}/{1} {2}：{3}' -f $o.stage, $o.total, $o.name, $o.detail)
                $itemStatus.Text = ('状态：自检 {0}/{1} — {2}' -f $o.stage, $o.total, $o.name)
                $itemSummary.Text = ('自检：' + [string]$o.detail)
                $script:tray.Text = ('云班-DSH 桥接器（自检 {0}/{1}）' -f $o.stage, $o.total)
            }
        }
    }

    # 进程还没退出、也没拿到结论 → 继续等
    if (-not $c['proc'].HasExited -and -not $c['result']) { return }

    # 进程已退出但这次还没读到结论行 → 再读一次，避免漏掉
    if (-not $c['result'] -and $c['proc'].HasExited) {
        try {
            $raw = [System.IO.File]::ReadAllText($c['file'])
            foreach ($ln in ($raw -split "`r?`n" | Where-Object { $_.Trim() })) {
                try { $o = $ln | ConvertFrom-Json } catch { continue }
                if (@($o.PSObject.Properties.Name) -contains 'done') { $c['result'] = $o }
            }
        } catch { }
    }

    # 收尾：恢复界面
    $script:check = $null
    $timer.Interval = 3000
    $itemCheck.Enabled = $true
    $itemCheck.Text = '检查整个回路（自检）'

    $r = $c['result']
    $body = New-Object System.Collections.Generic.List[string]
    if ($r) {
        if ($r.ok) {
            $title = '回路正常 ✅'
            $body.Add('整条链路都通：云班账号 → 云班接口 → DSH 问答 → 会话锁 → 回发通道。')
        } else {
            $title = '回路异常 ❌'
            $body.Add(('卡在第 {0} 步「{1}」' -f $r.stage, $r.name))
            $body.Add([string]$r.reason)
        }
        $body.Add('')
        $body.Add('—— 各段结果 ——')
        foreach ($x in @($r.lines)) {
            $mark = if ($x.ok) { '[通过]' } else { '[失败]' }
            $body.Add(('{0} {1}. {2}' -f $mark, $x.i, $x.detail))
        }
        $body.Add('')
        $body.Add(('耗时 {0:N1} 秒' -f ([double]$r.ms / 1000)))
        if (@($r.notes).Count -gt 0) {
            $body.Add('')
            $body.Add('—— 提示 ——')
            foreach ($n in @($r.notes)) { $body.Add([string]$n) }
        }
    } else {
        $title = '自检未完成 ❌'
        $body.Add('自检进程异常退出，没有给出结论。')
        $errFile = $c['errFile']
        if (Test-Path $errFile) {
            $e = Get-Content $errFile -Raw -Encoding UTF8
            if ($e -and $e.Trim()) { $body.Add(''); $body.Add($e.Substring(0, [Math]::Min(600, $e.Length))) }
        }
    }

    $icon = if ($r -and $r.ok) { 'Information' } else { 'Warning' }

    # 落一份日志，方便事后查（也便于自动化验证）
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logFile = Join-Path $logDir 'selfcheck.log'
        $entry = @("[{0}] {1}" -f $stamp, $title)
        $entry += $body
        $entry += ''
        Add-Content -LiteralPath $logFile -Value ($entry -join "`r`n") -Encoding UTF8
    } catch { }

    try {
        [System.Windows.Forms.MessageBox]::Show(($body -join "`r`n"), $title, 'OK', $icon) | Out-Null
    } catch { }
    $script:tray.Text = '云班-DSH 桥接器'
    Update-Ui
}

function Open-LatestLog {
    $f = Get-ChildItem $logDir -Filter '*.log' -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { Start-Process notepad.exe $f.FullName } else { Show-Balloon '暂无日志' '还没有产生日志文件' }
}

# ---------- 菜单 ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemStatus  = $menu.Items.Add('状态：启动中…')
$itemStatus.Enabled = $false
$itemSummary = $menu.Items.Add('最近轮询：—')
$itemSummary.Enabled = $false
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$itemEnable = $menu.Items.Add('启用桥接')
$itemEnable.Checked = $true
$itemEnable.Add_Click({ Set-Disabled (-not (Test-Disabled)) })

$itemCheck = $menu.Items.Add('检查整个回路（自检）')
$itemCheck.Add_Click({ Start-SelfCheck })

$itemLogin = $menu.Items.Add('重新登录（会话过期时用）')
$itemLogin.Add_Click({ Start-Login })

# 账号重新注册后：让主程序丢掉旧班级、重新发现并绑定
$itemRebind = $menu.Items.Add('重新识别账号 / 换号后点这里')
$itemRebind.Add_Click({
    try {
        Set-Content -Path (Join-Path $dataDir 'rebind.flag') -Value ('rebind at ' + (Get-Date -Format 'HH:mm:ss')) -Encoding UTF8
        Set-Content -Path $forceFile -Value '1' -Encoding ASCII
        Show-Balloon '已请求重新识别' '下一轮轮询会重新发现账号的班级与会话（几秒内）'
    } catch {
        Show-Balloon '请求失败' ([string]$_.Exception.Message)
    }
})

$itemPersona = $menu.Items.Add('更换 AI 人格…')
$itemPersona.Add_Click({
    try {
        $s = Join-Path $root '人格设置.ps1'
        if (!(Test-Path $s)) {
            Show-Balloon '找不到人格设置脚本' $s
            return
        }

        # 已经开着就直接切过去，不要每点一次多一个进程
        $opened = @(Get-Process -Name 'powershell' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like '*人格设置*' })
        if ($opened.Count -gt 0) {
            try {
                (New-Object -ComObject WScript.Shell).AppActivate($opened[0].Id) | Out-Null
            } catch { }
            Show-Balloon '人格设置已经开着' '已帮你切到那个窗口'
            return
        }

        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (!(Test-Path $psExe)) { $psExe = 'powershell.exe' }

        # 注意：这里**不能**加 -WindowStyle Hidden。
        # 那会把进程的 STARTUPINFO 设成 SW_HIDE，而 Windows 只让进程的第一次 ShowWindow
        # 遵循这个标志 —— 正好被 WinForms 的窗体吃掉，结果窗口"显示"成隐藏状态：
        # 进程活着、ShowDialog 一直阻塞、界面永远看不见（以前点了没反应就是这个原因）。
        Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $s + '"')) `
            -WorkingDirectory $root | Out-Null

        Show-Balloon '已打开人格设置' '改完点「保存并应用」，会当场核验是否真的生效'
    } catch {
        Show-Balloon '打开人格设置失败' ([string]$_.Exception.Message)
    }
})

$itemLog = $menu.Items.Add('打开最新日志')
$itemLog.Add_Click({ Open-LatestLog })

$itemConf = $menu.Items.Add('打开配置文件')
$itemConf.Add_Click({ if (Test-Path $confFile) { Start-Process notepad.exe $confFile } })

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$itemAuto = $menu.Items.Add('开机自启')
$itemAuto.Add_Click({ Set-Autostart(-not (Test-Autostart)) })

$itemAwake = $menu.Items.Add('运行时阻止睡眠')
$itemAwake.Add_Click({ Set-KeepAwake(-not (Test-KeepAwake)) })

$itemDesk = $menu.Items.Add('创建桌面快捷方式')
$itemDesk.Add_Click({ New-DesktopShortcut })

$itemRestart = $menu.Items.Add('重启桥接')
$itemRestart.Add_Click({
    Stop-Bridge
    Start-Sleep -Milliseconds 500
    Start-Bridge
    Show-Balloon '已重启' '桥接器正在重新连接'
})

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$itemExit = $menu.Items.Add('退出（停止桥接）')

# ---------- 托盘 ----------
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = $script:icons.gray
$script:tray.Text = '云班-DSH 桥接器'
$script:tray.Visible = $true
$script:tray.ContextMenuStrip = $menu
$script:tray.Add_DoubleClick({ Open-LatestLog })

# ---------- 界面刷新 ----------
function Update-Ui {
    # 自检进行中：状态区交给自检流程，别被常规刷新覆盖
    if ($script:check) { Update-SelfCheck; return }

    # 登录子进程结束 → 恢复桥接
    if ($script:loginProc -and $script:loginProc.HasExited) {
        $code = $script:loginProc.ExitCode
        $script:loginProc = $null
        if ($code -eq 0) { Show-Balloon '登录完成' '已刷新登录态，正在恢复桥接' }
        else { Show-Balloon '登录未完成' '浏览器窗口关闭或超时，可再点一次「重新登录」' }
        # 没有登录态时启动主程序只会立刻退出，别白跑
        if (Test-Path $cookieFile) { Start-Bridge }
    }

    $s = Read-Status
    $alive = ($script:proc -and !$script:proc.HasExited)

    # 桥接是单实例的。如果它正在跑、但不是「本托盘」启动的（托盘重启过、从 bat 启动过、
    # 上次托盘异常退出留下孤儿进程），只看 $script:proc 会误判成"已停止"。
    # 这里用 data\bridge.lock 里的 PID 把它认出来，状态显示为"运行中（外部实例）"。
    $externalPid = if ($alive) { 0 } else { Get-ExternalBridgePid }
    $running = $alive -or ($externalPid -ne 0)
    if ($externalPid -ne 0 -and $script:adoptedPid -ne $externalPid) {
        $script:adoptedPid = $externalPid
        Write-TrayLog ("接管已在运行的桥接实例 PID=$externalPid（不是本托盘启动的）")
        Show-Balloon '已接管正在运行的桥接' ("桥接进程 PID $externalPid 原本就在跑（不是本托盘启动的），已直接接管，不会再重启一份")
    }

    # —— 总开关：停用时停掉一切（不自动拉起、不轮询）——
    $itemEnable.Checked = -not (Test-Disabled)
    if (Test-Disabled) {
        if ($alive) { Stop-Bridge }
        $script:tray.Icon = $script:icons.gray
        $script:tray.Text = '云班-DSH 桥接器（已停用）'
        $itemStatus.Text = '状态：已停用（右键「启用桥接」恢复）'
        $itemSummary.Text = '已关闭：不轮询、不调用 DSH'
        return
    }

    # 主程序意外退出 → 自动拉起（8 秒冷却，避免 crash 循环打满 CPU）
    # 正在登录时不自动拉起，否则会和登录进程抢锁；没有登录态时也不拉（起了也是立刻退出）
    # 注意用 $running 而不是 $alive：外部实例还活着时再拉一份只会撞锁白退
    if (!$running -and !$script:stopping -and !$script:loginProc -and (Test-Path $cookieFile)) {
        if (((Get-Date) - $script:lastStart).TotalSeconds -ge 8) {
            Start-Bridge
            Start-Sleep -Milliseconds 400
            $alive = ($script:proc -and !$script:proc.HasExited)
            $externalPid = if ($alive) { 0 } else { Get-ExternalBridgePid }
            $running = $alive -or ($externalPid -ne 0)
            if ($alive) { Show-Balloon '桥接器已自动重启' '主程序意外退出，已重新拉起' }
            elseif ($externalPid -ne 0) {
                # 起不来是因为别人占着锁：把真正原因说出来，别只显示"已停止"
                $why = Get-BridgeStartError
                $script:adoptedPid = $externalPid
                Show-Balloon '桥接已在运行' ("检测到 PID $externalPid 正在跑，已接管；本次启动被单实例锁挡住" + $(if ($why) { "：$why" } else { '' }))
            }
        }
    }

    # 开机自启勾选状态
    $itemAuto.Checked = Test-Autostart
    # 防睡眠勾选状态（只同步显示，实际 API 状态在切换时才调用）
    $itemAwake.Checked = Test-KeepAwake

    if ($script:loginProc) {
        $script:tray.Icon = $script:icons.orange
        $script:tray.Text = '云班-DSH 桥接器（等待登录）'
        $itemStatus.Text = '状态：等待浏览器登录…'
        $itemSummary.Text = '登录完成后会自动恢复'
        return
    }

    if (!$running) {
        if (!(Test-Path $cookieFile)) {
            # 全新安装：还没有登录态，主程序起来也会立刻退出，这里直接引导登录
            $script:tray.Icon = $script:icons.orange
            $script:tray.Text = '云班-DSH 桥接器（未登录）'
            $itemStatus.Text = '状态：未登录 —— 右键「重新登录」'
            $itemSummary.Text = '首次使用请先登录云班账号'
            return
        }
        $script:tray.Icon = $script:icons.gray
        $script:tray.Text = '云班-DSH 桥接器（已停止）'
        $itemStatus.Text = '状态：已停止'
        # 把"为什么停"说出来：真没进程，还是启动被锁挡住
        $why = Get-BridgeStartError
        $itemSummary.Text = if ($why) { '进程未运行：' + $why } else { '进程未运行' }
        return
    }

    if (!$s) {
        $script:tray.Icon = $script:icons.orange
        $script:tray.Text = '云班-DSH 桥接器（启动中）'
        $itemStatus.Text = '状态：启动中…'
        $itemSummary.Text = '等待首次轮询'
        return
    }

    $state = [string]$s.'状态'
    $err = [string]$s.'最后错误'
    if ($state -eq 'paused') {
        $script:tray.Icon = $script:icons.orange
        $script:tray.Text = '云班-DSH 桥接器（登录态失效）'
        $itemStatus.Text = '状态：登录态失效，右键「重新登录」'
    } elseif ($err) {
        $script:tray.Icon = $script:icons.red
        $script:tray.Text = '云班-DSH 桥接器（有错误）'
        $itemStatus.Text = '状态：运行中（有错误）'
    } else {
        $script:tray.Icon = $script:icons.green
        $script:tray.Text = '云班-DSH 桥接器（运行中）'
        $itemStatus.Text = '状态：运行中' + $(if ($s.'演练模式') { '（演练模式）' } else { '' })
    }

    # 明确标出"这不是我起的进程"，避免以后又误判成"已停止"
    if ($externalPid -ne 0) {
        $itemStatus.Text = $itemStatus.Text + '（外部实例 PID ' + $externalPid + '）'
    }

    $sum = [string]$s.'最后轮询摘要'
    if (!$sum) { $sum = '等待首次轮询' }
    $itemSummary.Text = '最近轮询：' + $sum

    $tip = '队列 ' + [string]$s.'队列' + ' / 进行中 ' + [string]$s.'进行中' + ' / 会话 ' + [string]$s.'已建会话'
    if ($err) { $tip = '错误：' + $err }
    if ($tip.Length -gt 60) { $tip = $tip.Substring(0, 60) }
    $script:tray.Text = '云班-DSH ' + $tip
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Ui })
$timer.Start()

# ---------- 退出 ----------
$itemExit.Add_Click({
    $script:stopping = $true
    $timer.Stop()
    # 释放防睡眠状态，别让系统因为托盘退出而继续被拦着
    try { [PowerUtil]::SetThreadExecutionState([PowerUtil]::ES_CONTINUOUS) | Out-Null } catch { }
    Stop-Bridge
    if ($script:loginProc -and !$script:loginProc.HasExited) {
        try { Stop-Process -Id $script:loginProc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:tray.Visible = $false
    $script:tray.Dispose()
    [System.Windows.Forms.Application]::ExitThread()
})

# ---------- 启动 ----------
# 首次运行自动补一个桌面快捷方式（已存在则不动）
if (!(Test-Path $script:desktopLnk)) { try { New-DesktopShortcut } catch { } }

# 上次开了"阻止睡眠"就继续生效
if (Test-KeepAwake) {
    try { [PowerUtil]::SetThreadExecutionState([PowerUtil]::ES_CONTINUOUS -bor [PowerUtil]::ES_SYSTEM_REQUIRED) | Out-Null } catch { }
}

if (Test-Path $cookieFile) {
    Start-Bridge
    Update-Ui
    Show-Balloon '云班-DSH 桥接器已启动' '正在连接云班与 DSH，图标变绿即表示正常'
} else {
    # 首次安装/登录态被清掉：直接引导登录，别让用户对着灰图标发呆
    Update-Ui
    Show-Balloon '首次使用需要登录' '正在打开登录窗口，用云班账号登录后会自动开始工作'
    Start-Login
}

$ctx = New-Object System.Windows.Forms.ApplicationContext

# 调试/自动化用：设 YB_SELFCHECK_ON_START=1 启动后立刻跑一次自检
if ($env:YB_SELFCHECK_ON_START -eq '1') {
    # 用 script 作用域保存，事件脚本块里才能引用到（局部变量在 handler 里是空的）
    $script:autoCheckTimer = New-Object System.Windows.Forms.Timer
    $script:autoCheckTimer.Interval = 1500
    $script:autoCheckTimer.Add_Tick({ $script:autoCheckTimer.Stop(); Start-SelfCheck })
    $script:autoCheckTimer.Start()
}

[System.Windows.Forms.Application]::Run($ctx)

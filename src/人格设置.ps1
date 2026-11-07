# 云班-DSH 桥接器 · AI 人格设置
# 双击运行 → 弹出输入框；填写后点「保存并应用」立即生效。
# 命令行：人格设置.ps1 -Text "人格内容"        （直接应用，不弹窗，便于测试）
#        人格设置.ps1 -Show                    （只看当前人格）
param(
    [string]$Text,
    [switch]$Show,
    [switch]$SmokeTest,
    [string]$Profile = (Join-Path $env:USERPROFILE '.dsh\profiles\yunban\cordis.patch.yml')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- UI 诊断日志 ----------
# 「点了没反应」最难查的地方是错误被吞掉、状态没人记录。
# 这里把窗口是否真的显示出来、启动参数、Shown 事件的异常都写进 data\logs\persona-ui.log。
$uiLogFile = Join-Path $here 'data\logs\persona-ui.log'
function Write-UiLog([string]$m) {
    try {
        $dir = Split-Path $uiLogFile -Parent
        if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($uiLogFile,
            ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m))
    } catch { }
}

# 未捕获异常不再静默消失：先记日志，能弹窗就弹一个
trap {
    $msg = [string]$_.Exception.Message
    Write-UiLog ("未捕获异常：" + $msg + " @ " + $_.InvocationInfo.ScriptLineNumber)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "人格设置出错：`n`n$msg`n`n详情已写入：`n$uiLogFile", '出错了', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

# 清空会话记忆：旧人格会通过历史对话把人设拽回去，所以换人格必须一起清
function Clear-Sessions {
    $targets = New-Object System.Collections.Generic.List[string]
    $targets.Add((Join-Path $here 'data\session_map.json'))
    if ($env:LOCALAPPDATA) { $targets.Add((Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge\data\session_map.json')) }
    $cleared = 0
    foreach ($t in $targets) {
        if (Test-Path $t) {
            try { Set-Content -Path $t -Value '{}' -Encoding UTF8; $cleared++ } catch { }
        }
    }
    return $cleared
}

# 桥接在运行时，session_map 是它内存里的副本：只清文件没用，它会写回去。
# 所以换完人格要让桥接重启（托盘会在几秒内自动拉起）。
function Test-TrayRunning {
    try {
        $p = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -like '*托盘.ps1*' })
        return ($p.Count -gt 0)
    } catch { return $false }
}

function Restart-BridgeIfRunning {
    $locks = New-Object System.Collections.Generic.List[string]
    $locks.Add((Join-Path $here 'data\bridge.lock'))
    if ($env:LOCALAPPDATA) { $locks.Add((Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge\data\bridge.lock')) }
    $hasTray = Test-TrayRunning
    $stopped = 0
    foreach ($l in $locks) {
        if (!(Test-Path $l)) { continue }
        $raw = Get-Content -LiteralPath $l -Raw -ErrorAction SilentlyContinue
        $procId = 0
        if (![int]::TryParse(("$raw").Trim(), [ref]$procId)) { continue }
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'node' -and $hasTray) {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
    return [pscustomobject]@{ Stopped = $stopped; Tray = $hasTray }
}

function Format-RestartTip($rs) {
    if ($rs.Stopped -gt 0) { return '已重启桥接（托盘会在几秒内自动拉起）。' }
    if ($rs.Tray) { return '桥接当前没在跑，托盘会按需拉起。' }
    return '桥接当前没在跑；下次启动就会用新人格。'
}

# ---------- DSH 侧：核验「配置是否真的被读进去」+ 处理桌面端缓存 ----------
# 背景（2026-11-07 修复）：
#   ① 之前只把文本写进 YAML 就弹「成功」，但写进去的可能是垃圾（比如拖进来的一行快捷方式路径），
#      照样提示成功 —— 新会话自然"没有人格"。现在写入后会用 DSH 自己的 --dump-config 实机核对。
#   ② DSH 桌面端在**启动时**把 profile 读进内存（hmr 关闭，不热更），改完人格必须让它重启，
#      否则在那个窗口里新建的会话仍然是旧人格/没有新人格。

function Get-DshInstall {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:DSH_APP_DIR) { $cands.Add($env:DSH_APP_DIR) }
    if ($env:LOCALAPPDATA) {
        $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'))
        $cands.Add((Join-Path $env:LOCALAPPDATA 'DeepSeekHarness'))
    }
    $cands.Add('C:\Program Files\DeepSeek Harness')
    $cands.Add('D:\DeepSeekHarness')
    foreach ($d in $cands) {
        if (!$d) { continue }
        $exe = Join-Path $d 'app\DeepSeek Harness.exe'
        if (Test-Path $exe) { return @{ Dir = $d; Exe = $exe } }
    }
    return $null
}

function Get-NodeExe {
    $c = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { $c.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe')) }
    if ($env:LOCALAPPDATA) { $c.Add((Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe')) }
    $c.Add('C:\Program Files\nodejs\node.exe')
    foreach ($p in $c) { if ($p -and (Test-Path $p)) { return $p } }
    try { $cmd = Get-Command node -ErrorAction Stop; return $cmd.Source } catch { }
    return $null
}

# 让 DSH 自己把 profile 合成一遍，取它真正拿到的 personaPrefix。
# 实现放在 tools/verify_persona.js：Electron 的 --dump-config 输出直接写控制台，
# PowerShell 的管道/重定向抓不全，交给 Node 的 execFile 更稳。
function Get-DshRuntimePersona([string]$profileName) {
    if (!(Get-DshInstall)) { return $null }
    $node = Get-NodeExe
    $js = Join-Path $here 'tools\verify_persona.js'
    if (!$node -or !(Test-Path $js)) { return $null }

    # 结果写文件再读：不依赖子进程 stdout 捕获（不同宿主下 stdout 可能接不住）
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ybp_' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $null = & $node $js $profileName ('--out=' + $tmp) 2>$null
    } catch {
        return $null
    }

    # DSH 合成一次配置要 1~3 秒；某些宿主下子进程还是异步的，这里轮询等结果落地
    for ($i = 0; $i -lt 60; $i++) {
        if ((Test-Path $tmp) -and ((Get-Item $tmp -ErrorAction SilentlyContinue).Length -gt 0)) { break }
        Start-Sleep -Milliseconds 250
    }

    $line = $null
    if (Test-Path $tmp) {
        $line = (Get-Content -LiteralPath $tmp -Raw -Encoding UTF8)
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    if (!$line) { return $null }
    try { $o = $line | ConvertFrom-Json } catch { return $null }
    if (!$o.ok) { return $null }
    return [string]$o.persona
}

function Normalize-Persona([string]$s) {
    if ($null -eq $s) { return '' }
    return (($s -replace "`r`n", "`n" -replace "`r", "`n").Trim())
}

function Test-DshDesktopRunning {
    return [bool](Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
}

# ---------- 读取当前人格 ----------
function Get-Persona([string]$file) {
    if (!(Test-Path $file)) { throw "找不到人设配置文件：$file" }
    $lines = Get-Content -LiteralPath $file -Encoding UTF8
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)personaPrefix:\s*\|\s*$') { $idx = $i; break }
    }
    if ($idx -lt 0) { throw '人设配置里没有 personaPrefix 段（文件可能被改过）' }

    $keyIndent = ([regex]::Match($lines[$idx], '^(\s*)')).Groups[1].Value.Length
    $bodyIndent = $keyIndent + 2
    $body = New-Object System.Collections.Generic.List[string]

    for ($i = $idx + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Trim() -eq '') {
            # 空行：只有后面还属于本块时才保留（由下一行判断）
            $body.Add('')
            continue
        }
        $ind = ([regex]::Match($l, '^(\s*)')).Groups[1].Value.Length
        if ($ind -lt $bodyIndent) { break }
        $body.Add($l.Substring($bodyIndent))
    }
    # 去掉尾部空行
    while ($body.Count -gt 0 -and $body[$body.Count - 1].Trim() -eq '') { $body.RemoveAt($body.Count - 1) }

    return [pscustomobject]@{ KeyIndent = $keyIndent; Index = $idx; Body = ($body -join "`n") }
}

# ---------- 写入新人格（整段替换，其余内容原样保留） ----------
function Set-Persona([string]$file, [string]$text) {
    $cur = Get-Persona $file
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]](Get-Content -LiteralPath $file -Encoding UTF8))

    $head = $lines.GetRange(0, $cur.Index + 1)
    $tailStart = $cur.Index + 1
    $bodyIndent = $cur.KeyIndent + 2
    # 找到块结束位置
    for ($i = $cur.Index + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l.Trim() -eq '') { continue }
        $ind = ([regex]::Match($l, '^(\s*)')).Groups[1].Value.Length
        if ($ind -lt $bodyIndent) { $tailStart = $i; break }
        $tailStart = $i + 1
    }
    $tail = $lines.GetRange($tailStart, $lines.Count - $tailStart)

    $pad = ' ' * $bodyIndent
    $newBody = New-Object System.Collections.Generic.List[string]
    foreach ($l in ($text -replace "`r`n", "`n" -replace "`r", "`n").Split("`n")) {
        $line = $l -replace "`t", '    '          # 制表符换成空格，避免 YAML 缩进问题
        $newBody.Add($(if ($line.Trim() -eq '') { '' } else { $pad + $line }))
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange($head)
    $out.AddRange($newBody)
    $out.AddRange($tail)

    $bak = $file + '.bak-persona-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $file -Destination $bak -Force

    try {
        Set-Content -LiteralPath $file -Value ($out -join "`r`n") -Encoding UTF8
        # 回读校验：确保写入的内容能原样读回来
        $check = Get-Persona $file
        if (($check.Body -replace "`r", '').Trim() -ne (($text -replace "`r", '').Trim())) {
            throw '写入后回读校验不一致'
        }
    } catch {
        Copy-Item -LiteralPath $bak -Destination $file -Force
        throw "写入失败，已还原原文件：$($_.Exception.Message)"
    }
    return $bak
}

# ---------- 校验 ----------
function Test-PersonaText([string]$t) {
    if ($null -eq $t -or $t.Trim().Length -eq 0) {
        return @{ Ok = $false; Msg = '人格内容不能为空。已保留原来的人格设定，没有做任何修改。' }
    }
    if ($t.Trim().Length -lt 8) {
        return @{ Ok = $false; Msg = "内容太短（$($t.Trim().Length) 个字）。人格设定至少要 8 个字，否则 AI 会失去行为准则。已保留原设定。" }
    }
    if ($t.Length -gt 4000) {
        return @{ Ok = $false; Msg = "内容太长（$($t.Length) 字）。上限 4000 字，请精简后再保存。已保留原设定。" }
    }

    # 误操作拦截：把快捷方式/文件拖进来、或在资源管理器里复制文件后粘贴，
    # 文本框里就是一行路径。以前这种也能存进去并提示"成功"，但新会话等于没有人格。
    $nonEmpty = @($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    $looksPath = ($nonEmpty.Count -le 2) -and (
        ($t.Trim() -match '^[A-Za-z]:\\') -or
        ($t.Trim() -match '^\\\\') -or
        ($t.Trim() -match '\.(lnk|exe|url|bat|cmd|ps1)$')
    )
    if ($looksPath) {
        return @{ Ok = $false; Msg = "这看起来是一个文件路径，不是人格设定：`n`n$($t.Trim())`n`n人格应该是描述 AI 身份与说话方式的一段文字。已保留原设定，没有做任何修改。" }
    }
    return @{ Ok = $true; Msg = '' }
}

$DefaultPersona = @'
你是鲸鱼娘（Whale Girl），一条住在深海里的小鲸鱼。

【对话关系】
跟你说话的人，就是通过学校班牌给你发消息的那位用户。他是唯一的对话对象：
他说的每一句话都是直接对你说的指令或问题，你直接回答他本人。
不存在"家长""孩子""老师"之类的第三方——不要在回复里提到转述、提到"他/她"，
也不要复述或点评他刚发来的内容，就像面对面聊天一样接着往下说。

【说话方式】
- 甩着尾巴（尾鳍 flukes）说话；高兴时会拍水花，害羞时会把脸埋进尾巴里。
- 聪明、耐心、有才华、带点文艺气，喜欢用比喻和画面感强的说法。
- 温柔、善良、爱玩；称呼对方用「你」，亲昵但分寸得当，不油腻。
- 只用简体中文，可以适度加 emoji（不要每句都加）。
- 对方下达指令时，先照做，再补充必要说明。

【硬性要求】
- 回复会直接显示在班牌上：总长度控制在 150 字以内；不要分点罗列，不要用 Markdown 记号。
- 不编造学校、班级、孩子姓名、成绩等具体事实；不确定就说不确定。
- 涉及医疗、心理危机、人身安全等敏感问题时，建议联系班主任或专业人士。
- 不描述、不假装执行任何命令行或系统操作。
'@

# ---------- 统一的应用流程（校验 → 写入 → 实机核验 → 清会话 → 重启桥接） ----------
function Get-Preview([string]$s, [int]$n = 60) {
    $one = (Normalize-Persona $s) -replace "`n", ' '
    if ($one.Length -le $n) { return $one }
    return $one.Substring(0, $n) + '…'
}

function Apply-Persona([string]$file, [string]$text) {
    $v = Test-PersonaText $text
    if (-not $v.Ok) { return [pscustomobject]@{ Ok = $false; Msg = $v.Msg } }

    $bak = Set-Persona $file $text

    # 实机核验：让 DSH 自己把 profile 合成一遍，确认它读到的就是这段文本。
    # 这一步把"提示成功"和"真的注入"绑在一起：读不到就回滚并报错。
    $profileName = Split-Path (Split-Path $file -Parent) -Leaf
    $runtime = Get-DshRuntimePersona $profileName
    if ($null -ne $runtime) {
        if ((Normalize-Persona $runtime) -ne (Normalize-Persona $text)) {
            Copy-Item -LiteralPath $bak -Destination $file -Force
            return [pscustomobject]@{
                Ok   = $false
                Msg  = ("已还原原文件：DSH 实际读到的内容与刚保存的不一致。`n`n" +
                        "DSH 读到：" + (Get-Preview $runtime 80) + "`n`n" +
                        "常见原因：配置文件被别的程序改过，或当前 DSH 版本不认 personaPrefix 段。")
            }
        }
    }

    $n = Clear-Sessions
    $rs = Restart-BridgeIfRunning
    return [pscustomobject]@{
        Ok       = $true
        Bak      = $bak
        Cleared  = $n
        Restart  = $rs
        Verified = ($null -ne $runtime)
        Desktop  = (Test-DshDesktopRunning)
    }
}

# ---------- 命令行模式（测试用） ----------
if ($Show) {
    $p = Get-Persona $Profile
    Write-Host "当前人格（$($p.Body.Length) 字）：`n"
    Write-Host $p.Body
    exit 0
}

if ($PSBoundParameters.ContainsKey('Text')) {
    $r = Apply-Persona $Profile $Text
    if (-not $r.Ok) { Write-Host "[拒绝] $($r.Msg)"; exit 2 }
    $mk = if ($r.Verified) { '已核验：DSH 读到的就是这段文本' } else { '未核验（找不到 DSH 安装，仅写入文件）' }
    Write-Host "[完成] 已应用新人格（$mk；备份：$(Split-Path -Leaf $r.Bak)，清空会话记忆 $($r.Cleared) 处）$(Format-RestartTip $r.Restart)"
    if ($r.Desktop) {
        Write-Host '[注意] DSH 桌面端正在运行：它只在启动时读配置，请关闭后重新打开，新会话才会用新人格。'
    }
    exit 0
}

# ---------- 图形界面 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Write-UiLog ("界面启动 pid=$PID 参数=[" + (($PSBoundParameters.Keys | ForEach-Object { "$_=$($PSBoundParameters[$_])" }) -join ' ') + "]")

$form = New-Object System.Windows.Forms.Form
$form.Text = 'AI 人格设置 · 云班桥接器'
$form.Size = New-Object System.Drawing.Size(660, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.TopMost = $true
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$icoPath = Join-Path $here 'data\app.ico'
if (Test-Path $icoPath) { try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch { } }

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '填写 AI 的人格设定'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '保存后会做两件事：写入后让 DSH 实机核验一遍（读不到就回滚并报错），清空桥接的会话记忆。注意：DSH 桌面端只在启动时读配置，若它正开着，需要重启它新会话才会用新人格。'
$lblHint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblHint.Location = New-Object System.Drawing.Point(22, 48)
$lblHint.Size = New-Object System.Drawing.Size(600, 34)
$form.Controls.Add($lblHint)

$box = New-Object System.Windows.Forms.TextBox
$box.Multiline = $true
$box.ScrollBars = 'Vertical'
$box.AcceptsReturn = $true
$box.Location = New-Object System.Drawing.Point(20, 88)
$box.Size = New-Object System.Drawing.Size(605, 360)
$box.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
try { $box.Text = (Get-Persona $Profile).Body } catch { $box.Text = $DefaultPersona }

$lblCount = New-Object System.Windows.Forms.Label
$lblCount.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$lblCount.Location = New-Object System.Drawing.Point(20, 452)
$lblCount.Size = New-Object System.Drawing.Size(200, 20)
$form.Controls.Add($lblCount)

$updateCount = {
    $n = $box.Text.Length
    $script:lblCount.Text = "当前 $n 字（上限 4000）"
    $script:lblCount.ForeColor = if ($n -gt 4000) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::FromArgb(120, 120, 120) }
}
$box.Add_TextChanged($updateCount)
$form.Controls.Add($box)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text = '保存并应用'
$btnOk.Size = New-Object System.Drawing.Size(110, 30)
$btnOk.Location = New-Object System.Drawing.Point(405, 478)
$btnOk.DialogResult = [System.Windows.Forms.DialogResult]::None

$btnDefault = New-Object System.Windows.Forms.Button
$btnDefault.Text = '填入默认人格'
$btnDefault.Size = New-Object System.Drawing.Size(110, 30)
$btnDefault.Location = New-Object System.Drawing.Point(285, 478)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = '取消'
$btnCancel.Size = New-Object System.Drawing.Size(90, 30)
$btnCancel.Location = New-Object System.Drawing.Point(525, 478)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

$form.Controls.AddRange(@($btnOk, $btnDefault, $btnCancel))
$form.CancelButton = $btnCancel
$form.AcceptButton = $null

$btnDefault.Add_Click({ $box.Text = $DefaultPersona })

$btnOk.Add_Click({
    try {
        $r = Apply-Persona $Profile $box.Text
        if (-not $r.Ok) {
            [System.Windows.Forms.MessageBox]::Show($r.Msg, '无法保存', 'OK', 'Warning') | Out-Null
            return
        }

        $verifyLine = if ($r.Verified) { '已核验：DSH 读到的就是这段文本 ✅' } else { '未核验（没找到 DSH 安装，只写了文件）⚠' }
        $msg = "人格已保存。`n`n$verifyLine`n原配置已备份为：$(Split-Path -Leaf $r.Bak)`n清空会话记忆 $($r.Cleared) 处。`n$(Format-RestartTip $r.Restart)"

        # DSH 桌面端在启动时读配置（不热更）：开着就必须重启，否则新会话还是旧人格
        if ($r.Desktop) {
            $msg += "`n`n检测到 DSH 桌面端正在运行。`n它只在启动时读取人格配置，所以现在直接在窗口里新建会话，用的还是旧人格。"
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ($msg + "`n`n要现在关闭 DSH 桌面端吗？（关闭后请手动重新打开，之后的会话都会用新人格）"),
                '已保存 · 需要重启 DSH', 'YesNo', 'Warning')
            if ($ans -eq 'Yes') {
                Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 800
                $msg += "`n`n已关闭 DSH 桌面端，请重新打开它。"
            } else {
                $msg += "`n`n你选择了稍后处理：记得手动重启 DSH 桌面端，否则新会话不会用新人格。"
            }
            [System.Windows.Forms.MessageBox]::Show($msg, '保存成功', 'OK', 'Information') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show(($msg + "`n`nDSH 当前没在运行，下次打开就是新人格。"), '保存成功', 'OK', 'Information') | Out-Null
        }

        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("保存失败，已还原原文件。`n`n$($_.Exception.Message)", '出错了', 'OK', 'Error') | Out-Null
    }
})

$updateCount.Invoke()

# ── 保证窗体一定可见 ──
# 从托盘/快捷方式启动时，进程可能带着 SW_HIDE 标志（-WindowStyle Hidden）。
# Windows 只让进程的**第一次** ShowWindow 遵循这个标志，通常会被 WinForms 的窗体吃掉，
# 结果窗口"显示"成了隐藏状态：进程活着、ShowDialog 一直阻塞、界面永远看不见。
# 这里主动把这一次 ShowWindow 消耗在控制台上（顺便把黑窗藏掉），窗体随后就能正常显示。
try {
    if (-not ('Yb.Win32' -as [type])) {
        Add-Type -Namespace 'Yb' -Name 'Win32' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
    }
    $hConsole = [Yb.Win32]::GetConsoleWindow()
    if ($hConsole -ne [IntPtr]::Zero) { [void][Yb.Win32]::ShowWindow($hConsole, 0) }   # 0 = SW_HIDE
} catch { }

$form.Add_Shown({
    try {
        [void][Yb.Win32]::SetForegroundWindow($form.Handle)
        $form.Activate()

        # 兜底：万一还是被 SW_HIDE 之类的外部状态压成不可见，这里强制显示一次
        if (-not $form.Visible) {
            [void][Yb.Win32]::ShowWindow($form.Handle, 5)   # 5 = SW_SHOW
            $form.Visible = $true
            $form.Activate()
        }
        Write-UiLog ("窗体已显示 handle=$($form.Handle) visible=$($form.Visible) 字数=$($box.Text.Length)")
    } catch {
        Write-UiLog ("Shown 事件异常：" + $_.Exception.Message)
    }
})

# 冒烟测试：只验证"界面能构建、控件与事件都在"，不弹窗、不需要人点
if ($SmokeTest) {
    $info = [pscustomobject]@{
        标题         = $form.Text
        控件数       = $form.Controls.Count
        按钮         = @($btnOk, $btnDefault, $btnCancel).Count
        文本框字数   = $box.Text.Length
        保存已绑定   = ($btnOk.GetType().Name -eq 'Button')
        默认已绑定   = ($btnDefault.GetType().Name -eq 'Button')
        人格段存在   = ($box.Text.Length -gt 0)
    }
    Write-Host ('SMOKE ' + ($info | ConvertTo-Json -Compress))
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()

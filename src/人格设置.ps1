# 云班-DSH 桥接器 · AI 人格设置
# 双击运行 → 弹出输入框；填写后点「保存并应用」立即生效。
# 命令行：人格设置.ps1 -Text "人格内容"        （直接应用，不弹窗，便于测试）
#        人格设置.ps1 -Show                    （只看当前人格）
param(
    [string]$Text,
    [switch]$Show,
    [string]$Profile = (Join-Path $env:USERPROFILE '.dsh\profiles\yunban\cordis.patch.yml')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 清空会话记忆：旧人格会通过历史对话把人设拽回去，所以换人格必须一起清
function Clear-Sessions {
    $targets = @(
        (Join-Path $here 'data\session_map.json'),
        (Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge\data\session_map.json')
    )
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
    $locks = @(
        (Join-Path $here 'data\bridge.lock'),
        (Join-Path $env:LOCALAPPDATA 'Programs\YunbanBridge\data\bridge.lock')
    )
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

# ---------- 命令行模式（测试用） ----------
if ($Show) {
    $p = Get-Persona $Profile
    Write-Host "当前人格（$($p.Body.Length) 字）：`n"
    Write-Host $p.Body
    exit 0
}

if ($PSBoundParameters.ContainsKey('Text')) {
    $v = Test-PersonaText $Text
    if (-not $v.Ok) { Write-Host "[拒绝] $($v.Msg)"; exit 2 }
    $bak = Set-Persona $Profile $Text
    $n = Clear-Sessions
    $rs = Restart-BridgeIfRunning
    Write-Host "[完成] 已应用新人格（备份：$(Split-Path -Leaf $bak)，清空会话记忆 $n 处）$(Format-RestartTip $rs)"
    exit 0
}

# ---------- 图形界面 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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
$lblHint.Text = '保存后立即生效（下一次回复就用新人格）。为避免旧对话把人设拽回去，保存时会清空会话记忆。'
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
    $v = Test-PersonaText $box.Text
    if (-not $v.Ok) {
        [System.Windows.Forms.MessageBox]::Show($v.Msg, '无法保存', 'OK', 'Warning') | Out-Null
        return
    }
    try {
        $bak = Set-Persona $Profile $box.Text
        $n = Clear-Sessions
        $rs = Restart-BridgeIfRunning
        [System.Windows.Forms.MessageBox]::Show(
            "已应用新人格，下一次回复就会用它。`n`n原配置已备份为：$(Split-Path -Leaf $bak)`n清空会话记忆 $n 处。`n$(Format-RestartTip $rs)",
            '保存成功', 'OK', 'Information') | Out-Null
        $form.Close()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("保存失败，已还原原文件。`n`n$($_.Exception.Message)", '出错了', 'OK', 'Error') | Out-Null
    }
})

$updateCount.Invoke()
[void]$form.ShowDialog()

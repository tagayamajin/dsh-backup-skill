<#
.SYNOPSIS
    显示 DSH 恢复进度的小窗口（由 restore-dsh.ps1 自动启动，也可手动运行查看进度）。

.DESCRIPTION
    读取恢复脚本写入的状态文件（默认 %TEMP%\dsh-restore-progress.json），
    显示当前阶段、百分比、已用时间、预计剩余时间与明细。
    窗口置顶，可最小化；关闭窗口不会影响后台恢复进程。

.PARAMETER StateFile
    进度状态 JSON 的路径。默认 %TEMP%\dsh-restore-progress.json。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File show-progress.ps1
#>
[CmdletBinding()]
param(
    [string]$StateFile = (Join-Path $env:TEMP 'dsh-restore-progress.json')
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ('DshProgressNative' -as [type])) {
    Add-Type -Namespace '' -Name 'DshProgressNative' -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
'@
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:StateFile = $StateFile
$script:ClosedTimer = $null

# ---------------------------------------------------------------------------
# 窗口
# ---------------------------------------------------------------------------
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'DSH 恢复进度'
$script:Form.ClientSize = New-Object System.Drawing.Size(560, 262)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.FormBorderStyle = 'FixedDialog'
$script:Form.MaximizeBox = $false
$script:Form.MinimizeBox = $true
$script:Form.TopMost = $true
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)

$script:TitleLabel = New-Object System.Windows.Forms.Label
$script:TitleLabel.Location = New-Object System.Drawing.Point(18, 14)
$script:TitleLabel.Size = New-Object System.Drawing.Size(520, 26)
$script:TitleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$script:TitleLabel.Text = 'DSH 恢复进度'
$script:Form.Controls.Add($script:TitleLabel)

$script:PhaseLabel = New-Object System.Windows.Forms.Label
$script:PhaseLabel.Location = New-Object System.Drawing.Point(18, 46)
$script:PhaseLabel.Size = New-Object System.Drawing.Size(520, 24)
$script:PhaseLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10.5, [System.Drawing.FontStyle]::Bold)
$script:PhaseLabel.Text = '等待恢复进程启动…'
$script:Form.Controls.Add($script:PhaseLabel)

$script:Bar = New-Object System.Windows.Forms.ProgressBar
$script:Bar.Location = New-Object System.Drawing.Point(18, 76)
$script:Bar.Size = New-Object System.Drawing.Size(524, 22)
$script:Bar.Minimum = 0
$script:Bar.Maximum = 100
$script:Bar.Style = 'Marquee'
$script:Bar.MarqueeAnimationSpeed = 30
$script:Form.Controls.Add($script:Bar)

$script:PctLabel = New-Object System.Windows.Forms.Label
$script:PctLabel.Location = New-Object System.Drawing.Point(18, 104)
$script:PctLabel.Size = New-Object System.Drawing.Size(120, 28)
$script:PctLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$script:PctLabel.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 200)
$script:PctLabel.Text = ''
$script:Form.Controls.Add($script:PctLabel)

$script:TimeLabel = New-Object System.Windows.Forms.Label
$script:TimeLabel.Location = New-Object System.Drawing.Point(150, 108)
$script:TimeLabel.Size = New-Object System.Drawing.Size(392, 24)
$script:TimeLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$script:TimeLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 100)
$script:TimeLabel.Text = ''
$script:Form.Controls.Add($script:TimeLabel)

$script:DetailLabel = New-Object System.Windows.Forms.Label
$script:DetailLabel.Location = New-Object System.Drawing.Point(18, 140)
$script:DetailLabel.Size = New-Object System.Drawing.Size(524, 44)
$script:DetailLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$script:DetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$script:DetailLabel.Text = ''
$script:Form.Controls.Add($script:DetailLabel)

$script:LogLabel = New-Object System.Windows.Forms.Label
$script:LogLabel.Location = New-Object System.Drawing.Point(18, 190)
$script:LogLabel.Size = New-Object System.Drawing.Size(524, 20)
$script:LogLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8.5)
$script:LogLabel.ForeColor = [System.Drawing.Color]::FromArgb(130, 130, 140)
$script:LogLabel.Text = ''
$script:Form.Controls.Add($script:LogLabel)

$script:CloseBtn = New-Object System.Windows.Forms.Button
$script:CloseBtn.Location = New-Object System.Drawing.Point(444, 216)
$script:CloseBtn.Size = New-Object System.Drawing.Size(98, 30)
$script:CloseBtn.Text = '关闭'
$script:CloseBtn.Visible = $false
$script:CloseBtn.Add_Click({ $script:Form.Close() })
$script:Form.Controls.Add($script:CloseBtn)

# ---------------------------------------------------------------------------
# 刷新
# ---------------------------------------------------------------------------
$script:Tick = {
    $sf = $script:StateFile
    if (-not (Test-Path -LiteralPath $sf)) {
        $script:PhaseLabel.Text = '等待恢复进程启动…'
        $script:DetailLabel.Text = '如果长时间停在这里：恢复脚本可能已结束，或尚未开始写入进度。'
        $script:Bar.Style = 'Marquee'
        return
    }
    try {
        $raw = [System.IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $s = $raw | ConvertFrom-Json
    } catch { return }

    if ($s.Title) { $script:TitleLabel.Text = [string]$s.Title }
    if ($s.Phase) { $script:PhaseLabel.Text = [string]$s.Phase }
    if ($s.Detail) { $script:DetailLabel.Text = [string]$s.Detail }
    if ($s.LogFile) { $script:LogLabel.Text = '日志: ' + [string]$s.LogFile }

    $pct = 0
    try { $pct = [int]$s.Percent } catch { $pct = 0 }
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    if ($s.Indeterminate -and -not $s.Done) {
        if ($script:Bar.Style -ne 'Marquee') { $script:Bar.Style = 'Marquee' }
        $script:PctLabel.Text = '进行中'
    } else {
        if ($script:Bar.Style -ne 'Continuous') { $script:Bar.Style = 'Continuous' }
        $script:Bar.Value = $pct
        $script:PctLabel.Text = [string]$pct + '%'
    }

    $timeText = ''
    if ($s.ElapsedText) { $timeText = '已用 ' + [string]$s.ElapsedText }
    if ($s.EtaText) { $timeText = $timeText + '    预计剩余 ' + [string]$s.EtaText }
    $script:TimeLabel.Text = $timeText

    if ($s.Done) {
        if ($script:TickTimer) { $script:TickTimer.Stop() }
        if ($s.Error) {
            $script:Bar.Style = 'Continuous'
            $script:Bar.Value = $pct
            $script:PhaseLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30)
            $script:PhaseLabel.Text = '恢复失败'
            $script:DetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 30, 30)
            $script:DetailLabel.Text = [string]$s.Error
            $script:CloseBtn.Visible = $true
            $script:Form.TopMost = $true
        } else {
            $script:Bar.Style = 'Continuous'
            $script:Bar.Value = 100
            $script:PctLabel.Text = '100%'
            $script:PhaseLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 130, 60)
            $script:PhaseLabel.Text = '恢复完成'
            $script:DetailLabel.Text = '窗口将在 2 秒后自动关闭；恢复日志可在上面路径查看。'
            # 2 秒后自动关闭
            $script:ClosedTimer = New-Object System.Windows.Forms.Timer
            $script:ClosedTimer.Interval = 2000
            $script:ClosedTimer.Add_Tick({
                $script:ClosedTimer.Stop()
                $script:Form.Close()
            })
            $script:ClosedTimer.Start()
        }
    }
}

$script:TickTimer = New-Object System.Windows.Forms.Timer
$script:TickTimer.Interval = 500
$script:TickTimer.Add_Tick($script:Tick)
$script:TickTimer.Start()

$script:Form.Add_Shown({
    # 进程可能是以 -WindowStyle Hidden 启动的：Windows 会把“第一次 ShowWindow”强制为隐藏。
    # 这里再显式 ShowWindow(SW_SHOWNORMAL)，保证窗口一定可见。
    try {
        [DshProgressNative]::ShowWindow($script:Form.Handle, 5) | Out-Null
        [DshProgressNative]::SetForegroundWindow($script:Form.Handle) | Out-Null
    } catch { }
    $script:Form.Activate()
    & $script:Tick
})

try {
    [System.Windows.Forms.Application]::Run($script:Form)
} catch {
    # 窗口无法显示时静默退出（不影响恢复主流程）
}
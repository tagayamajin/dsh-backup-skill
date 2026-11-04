<#
.SYNOPSIS
    在 DSH 会话中启动“后台独立恢复”：拉起隐藏的 restore-dsh.ps1 进程，
    由它等待用户完全退出 DSH，然后自动恢复配置，完成后自动重新启动 DSH。

.DESCRIPTION
    用于新机恢复场景：用户在 DSH 里让新会话执行恢复时，DSH 本身正在运行，
    无法直接覆盖 %USERPROFILE%\.dsh。本脚本会：
      1. 校验备份目录与 restore-dsh.ps1 存在；
      2. 用隐藏窗口启动 restore-dsh.ps1（-WaitForExit -RestartApp），脱离当前会话；
         默认恢复配置、插件离线依赖、历史会话与附件；
      3. 提示用户：在任务栏托盘退出 DSH，恢复会自动继续，完成后自动重新打开 DSH。

    如果后台进程随 DSH 退出被一起回收（少数环境），按 README 的“手动兜底”章节：
    退出 DSH 后自己打开 PowerShell 运行
        powershell -NoProfile -ExecutionPolicy Bypass -File "<本目录>\restore-dsh.ps1" -WaitForExit -RestartApp

.PARAMETER BackupDir
    备份根目录（含 config\ 的目录）。默认为本脚本所在目录的上一级（backup\）。
.PARAMETER WaitTimeoutMin
    等待用户退出 DSH 的最长分钟数，默认 120。
.PARAMETER NoRestart
    恢复完成后不自动重启 DSH。
.PARAMETER NoWait
    不等待 DSH 退出（仅在 DSH 已经退出时使用）。
.PARAMETER SkipUserData
    不恢复历史会话与附件（默认会恢复）。
#>
[CmdletBinding()]
param(
    [string]$BackupDir,
    [int]$WaitTimeoutMin = 120,
    [switch]$NoRestart,
    [switch]$NoWait,
    [switch]$SkipUserData
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $BackupDir -or $BackupDir.Trim().Length -eq 0) {
    $BackupDir = Split-Path -Parent $scriptDir
}
$BackupDir = [System.IO.Path]::GetFullPath($BackupDir)
$restore = Join-Path $scriptDir 'restore-dsh.ps1'

if (-not (Test-Path -LiteralPath $restore)) {
    Write-Host ('[错误] 找不到恢复脚本: ' + $restore)
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $BackupDir 'config'))) {
    Write-Host ('[错误] 备份目录无效（缺少 config\）: ' + $BackupDir)
    exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $BackupDir 'manifest.json'))) {
    Write-Host '[警告] 备份目录缺少 manifest.json，继续。'
}

$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $restore, '-BackupDir', $BackupDir, '-WaitTimeoutMin', $WaitTimeoutMin)
if (-not $NoWait) { $argList += '-WaitForExit' }
if (-not $NoRestart) { $argList += '-RestartApp' }
if ($SkipUserData) { $argList += '-SkipUserData' }

Write-Host ''
Write-Host '============================================================'
Write-Host '  DSH 恢复已准备就绪'
Write-Host '============================================================'
Write-Host ('  备份目录: ' + $BackupDir)
if ($SkipUserData) {
    Write-Host '  将恢复：配置、插件离线依赖（不恢复历史会话/附件）。'
} else {
    Write-Host '  将恢复：配置、插件离线依赖、历史会话与附件（默认）。'
}
Write-Host '  即将启动后台恢复进程（隐藏窗口）。'
Write-Host ''
Write-Host '  >>> 现在请在任务栏托盘右键 DSH 图标，选择“退出” <<<'
Write-Host ('  退出后恢复会自动开始，完成后自动重新启动 DSH（最多等待 ' + $WaitTimeoutMin + ' 分钟）。')
Write-Host '============================================================'
Write-Host ''

$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
if ($proc.HasExited) {
    Write-Host ('[错误] 后台恢复进程启动后立即退出（exit ' + $proc.ExitCode + '）。')
    Write-Host '请按 README 的“手动兜底”章节：退出 DSH 后自己打开 PowerShell 运行 restore-dsh.ps1。'
    exit 1
}

Write-Host ('后台恢复进程已启动，PID=' + $proc.Id + '。')
Write-Host ('日志文件: ' + $env:TEMP + '\dsh-restore-*.log')
Write-Host '请立刻退出 DSH（任务栏托盘 -> 退出）。'
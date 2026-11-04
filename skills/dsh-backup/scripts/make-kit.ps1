#requires -Version 5.1
<#
.SYNOPSIS
    构建 DSH 迁移包（同版本安装包 + 去凭据配置/插件备份 + 面向新会话 AI 的恢复指南），
    输出带日期时间戳的单个 zip，并在成功后自动清理旧备份（保留最新 N 个）。

.DESCRIPTION
    这是 DSH 技能 dsh-backup 的编排脚本。它在临时目录组装一个 DSH-kit-<版本> 目录：
      installer\  当前 DSH 版本的官方安装包
      backup\     去凭据备份（config / offline node_modules / user-data-optional / scripts）
      RECOVERY-GUIDE.md + README-FIRST.txt + kit-manifest.json
    然后用系统自带 tar.exe 以 store（不压缩）方式打包成一个 zip，并写 .sha256 校验文件。
    打包成功后默认删除旧备份，只保留最新一份（-Keep 可调，-NoPrune 可关闭）。

.PARAMETER OutputDir
    zip 输出目录。默认：桌面\DSH备份\zips

.PARAMETER WorkDir
    临时组装目录。默认：%TEMP%\dsh-kit-build-<yyyymmdd-HHmmss>（成功且打包后自动删除）

.PARAMETER Installer
    DSH 安装包路径。默认自动在 electron-updater 缓存中查找与当前版本一致的安装器。

.PARAMETER Keep
    成功后保留的备份数量（含本次），默认 1。<=0 表示不清理。

.PARAMETER SkipUserData
    不备份会话记录与附件（默认包含）。

.PARAMETER KeepStaging
    打包后保留临时组装目录（排查问题时用）。

.PARAMETER NoZip
    只组装、不打包 zip（同时跳过旧备份清理），用于验证。

.PARAMETER AllowVersionMismatch
    安装包版本与当前 DSH 版本不一致时仍然继续（默认报错退出）。

.PARAMETER NoPrune
    打包成功后不删除旧备份。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "<技能目录>\scripts\make-kit.ps1"

.EXAMPLE
    .\make-kit.ps1 -OutputDir D:\DSH备份 -Keep 2 -SkipUserData
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$WorkDir,
    [string]$Installer,
    [int]$Keep = 1,
    [switch]$SkipUserData,
    [switch]$KeepStaging,
    [switch]$NoZip,
    [switch]$AllowVersionMismatch,
    [switch]$NoPrune
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('==> ' + $Message) -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host ('    ' + $Message)
}

function Write-Warn {
    param([string]$Message)
    Write-Host ('[警告] ' + $Message) -ForegroundColor Yellow
}

function Fail {
    param([string]$Message)
    Write-Host ('[错误] ' + $Message) -ForegroundColor Red
    exit 1
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Get-DirStats {
    param([string]$Path)
    $stats = New-Object psobject -Property @{ FileCount = 0; SizeBytes = [int64]0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $stats }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $stats.FileCount = $files.Count
    if ($files.Count -gt 0) {
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($null -ne $sum) { $stats.SizeBytes = [int64]$sum }
    }
    return $stats
}

function Resolve-DshInstall {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'DeepSeek Harness.exe'))) { return $c }
    }
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $items = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        })
        foreach ($item in $items) {
            if ($item.DisplayName -like 'DeepSeek Harness*' -and $item.InstallLocation) {
                $exe = Join-Path $item.InstallLocation 'DeepSeek Harness.exe'
                if (Test-Path -LiteralPath $exe) { return $item.InstallLocation }
            }
        }
    }
    return $null
}

function Get-DshVersion {
    param([string]$InstallDir)
    $version = ''
    $runtimeJson = Join-Path $InstallDir 'resources\runtime\primary-runtime\runtime.json'
    if (Test-Path -LiteralPath $runtimeJson) {
        try { $version = [string](Get-Content -Raw -LiteralPath $runtimeJson | ConvertFrom-Json).desktopVersion } catch { $version = '' }
    }
    if (-not $version) {
        $exe = Join-Path $InstallDir 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $exe) {
            try { $version = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { $version = '' }
        }
    }
    return $version
}

function Resolve-InstallerPath {
    param([string]$Requested, [string]$Version, [bool]$AllowMismatch)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Requested -and $Requested.Trim().Length -gt 0) { $candidates.Add($Requested.Trim()) }
    if ($env:LOCALAPPDATA) {
        $updater = Join-Path $env:LOCALAPPDATA '@deepseek-aidsh-desktop-updater\installer.exe'
        if (Test-Path -LiteralPath $updater) { $candidates.Add($updater) }
    }
    if ($env:TEMP) {
        $tmp = Join-Path $env:TEMP 'DeepSeek-Harness-Installer.exe'
        if (Test-Path -LiteralPath $tmp) { $candidates.Add($tmp) }
    }
    $existing = @($candidates | Where-Object { Test-Path -LiteralPath $_ })
    if ($existing.Count -eq 0) {
        Fail '找不到 DSH 安装包。请用 -Installer 指定，或先运行一次 DSH 自动更新以生成 electron-updater 缓存安装器。'
    }
    foreach ($c in $existing) {
        $pv = ''
        try { $pv = [string](Get-Item -LiteralPath $c).VersionInfo.ProductVersion } catch { $pv = '' }
        if ($pv -and $pv -eq $Version) { return $c }
    }
    $first = $existing[0]
    $firstPv = ''
    try { $firstPv = [string](Get-Item -LiteralPath $first).VersionInfo.ProductVersion } catch { $firstPv = '' }
    if ($AllowMismatch) {
        Write-Warn ('安装包版本 [' + $firstPv + '] 与当前 DSH [' + $Version + '] 不一致，按参数继续。')
        return $first
    }
    Fail ('找到的安装包版本 [' + $firstPv + '] 与当前 DSH [' + $Version + '] 不一致。请用 -Installer 指定同版本安装器，或加 -AllowVersionMismatch。')
}

# ---------------------------------------------------------------------------
# 0. 路径与参数
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
$kitScriptsDir = Join-Path $scriptDir 'kit'
$skillDir = Split-Path -Parent $scriptDir
$assetsDir = Join-Path $skillDir 'assets'
$backupScript = Join-Path $kitScriptsDir 'backup-dsh.ps1'
$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

if (-not (Test-Path -LiteralPath $backupScript)) { Fail ('技能文件不完整，缺少备份脚本: ' + $backupScript) }
if (-not (Test-Path -LiteralPath $tarExe)) { Fail ('找不到系统 tar.exe: ' + $tarExe) }

if (-not $OutputDir -or $OutputDir.Trim().Length -eq 0) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = $env:USERPROFILE }
    $OutputDir = Join-Path $desktop 'DSH备份\zips'
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $WorkDir -or $WorkDir.Trim().Length -eq 0) {
    $WorkDir = Join-Path $env:TEMP ('dsh-kit-build-' + $stamp)
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

# ---------------------------------------------------------------------------
# 1. 解析环境
# ---------------------------------------------------------------------------
Write-Step '1/6 解析本机 DSH 环境'

$installDir = Resolve-DshInstall
if (-not $installDir) {
    Fail '未检测到已安装的 DSH 桌面版（找不到 DeepSeek Harness.exe）。请先安装 DSH 桌面版。'
}
$version = Get-DshVersion -InstallDir $installDir
if (-not $version) { Fail ('无法从安装目录读取 DSH 版本: ' + $installDir) }
Write-Info ('DSH 版本  : ' + $version)
Write-Info ('安装目录  : ' + $installDir)

$installerPath = Resolve-InstallerPath -Requested $Installer -Version $version -AllowMismatch $AllowVersionMismatch
$installerItem = Get-Item -LiteralPath $installerPath
$installerPv = ''
try { $installerPv = [string]$installerItem.VersionInfo.ProductVersion } catch { $installerPv = '' }
Write-Info ('安装包    : ' + $installerPath)

$sigStatus = 'Unknown'
$sigSigner = ''
try {
    $sig = Get-AuthenticodeSignature -LiteralPath $installerPath
    $sigStatus = [string]$sig.Status
    if ($sig.SignerCertificate) { $sigSigner = [string]$sig.SignerCertificate.Subject }
} catch {
    $sigStatus = 'Unknown'
}
Write-Info ('签名状态  : ' + $sigStatus)
if ($sigStatus -ne 'Valid') { Write-Warn '安装包数字签名未验证通过（仍继续，请自行确认来源安全）。' }

# ---------------------------------------------------------------------------
# 2. 组装 staging 目录
# ---------------------------------------------------------------------------
Write-Step '2/6 组装迁移包目录'

$kitLeaf = 'DSH-kit-' + $version
$kitDir = Join-Path $WorkDir $kitLeaf
$installerDir = Join-Path $kitDir 'installer'
$backupDir = Join-Path $kitDir 'backup'
if (Test-Path -LiteralPath $kitDir) { Remove-Item -LiteralPath $kitDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $installerDir, $backupDir | Out-Null

$installerLeaf = 'DeepSeek-Harness-' + $version + '-win-x64.exe'
$installerDst = Join-Path $installerDir $installerLeaf
Copy-Item -LiteralPath $installerPath -Destination $installerDst -Force
$installerHash = Get-FileSha256 -Path $installerDst
Write-Info ('安装包已复制（' + [math]::Round($installerItem.Length / 1MB, 1) + ' MB）')

$shaLines = @(
    '# DeepSeek Harness ' + $version + ' Windows x64 安装包校验信息',
    ('File: ' + $installerLeaf),
    ('SizeBytes: ' + $installerItem.Length),
    ('SHA256: ' + $installerHash),
    ('ProductVersion: ' + $installerPv),
    ('Signature: ' + $sigStatus),
    ('Signer: ' + $sigSigner),
    '',
    '# PowerShell 校验命令:',
    ('# Get-FileHash -Algorithm SHA256 "' + $installerDst + '"')
)
$shaLines | Set-Content -LiteralPath (Join-Path $installerDir 'installer.sha256.txt') -Encoding UTF8

foreach ($asset in @('RECOVERY-GUIDE.md', 'README-FIRST.txt')) {
    $assetSrc = Join-Path $assetsDir $asset
    if (Test-Path -LiteralPath $assetSrc) {
        Copy-Item -LiteralPath $assetSrc -Destination (Join-Path $kitDir $asset) -Force
    } else {
        Write-Warn ('缺少文档资源: ' + $assetSrc)
    }
}

# ---------------------------------------------------------------------------
# 3. 备份配置与插件（调用 kit\backup-dsh.ps1）
# ---------------------------------------------------------------------------
Write-Step '3/6 备份配置、插件依赖与用户数据（约 2-4 分钟）'

$psExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }

$backupArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $backupScript,
    '-OutputDir', $backupDir, '-Refresh', '-ExcludeCredentials', '-NoZip'
)
if (-not $SkipUserData) { $backupArgs += '-IncludeUserData' }

& $psExe @backupArgs
if ($LASTEXITCODE -ne 0) {
    Fail ('备份脚本失败（exit ' + $LASTEXITCODE + '），临时目录保留在: ' + $WorkDir)
}

$backupManifestPath = Join-Path $backupDir 'manifest.json'
if (-not (Test-Path -LiteralPath $backupManifestPath)) {
    Fail ('备份未生成 manifest.json，临时目录保留在: ' + $WorkDir)
}
$backupManifest = Get-Content -Raw -LiteralPath $backupManifestPath | ConvertFrom-Json
$backupManifestHash = Get-FileSha256 -Path $backupManifestPath

$credHits = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -Force -Filter '.credentials.yaml' -ErrorAction SilentlyContinue)
if ($credHits.Count -gt 0) {
    Fail ('备份中检测到凭据文件，已中止打包: ' + $credHits[0].FullName)
}
Write-Info '凭据检查：未包含 .credentials.yaml'

$desktopPackage = Join-Path $backupDir 'config\profiles\desktop\package.json'
if (-not (Test-Path -LiteralPath $desktopPackage)) {
    Fail '备份缺少 desktop profile 配置，已中止。'
}
$backupStats = Get-DirStats -Path $backupDir
Write-Info ('备份文件数: ' + $backupStats.FileCount + '，大小: ' + [math]::Round($backupStats.SizeBytes / 1MB, 1) + ' MB')

# ---------------------------------------------------------------------------
# 4. 写 kit-manifest.json
# ---------------------------------------------------------------------------
Write-Step '4/6 写入 kit-manifest.json'

$kitManifest = [ordered]@{
    format         = 'dsh-migration-kit'
    formatVersion  = 1
    createdAt      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    host           = $env:COMPUTERNAME
    dshVersion     = $version
    installDir     = $installDir
    installer      = [ordered]@{
        file           = 'installer/' + $installerLeaf
        sizeBytes      = $installerItem.Length
        sha256         = $installerHash
        productVersion = $installerPv
        signature      = $sigStatus
        signer         = $sigSigner
    }
    backup         = [ordered]@{
        manifest          = 'backup/manifest.json'
        manifestSizeBytes = (Get-Item -LiteralPath $backupManifestPath).Length
        manifestSha256    = $backupManifestHash
        fileCount         = $backupStats.FileCount
        sizeBytes         = $backupStats.SizeBytes
        credentialsIncluded = $false
        userDataIncluded  = (-not $SkipUserData)
    }
    restore        = [ordered]@{
        entryPoint     = 'backup/scripts/start-restore.ps1'
        manualFallback = 'backup/scripts/restore-dsh.ps1 -BackupDir <包目录>\backup -WaitForExit -RestartApp'
        guide          = 'RECOVERY-GUIDE.md'
        requires       = ('已安装 DSH ' + $version + ' 并完全退出；磁盘空间 >= 6 GB')
    }
}
$kitManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $kitDir 'kit-manifest.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# 5. 打包 zip（store 模式，与安装方式无关）
# ---------------------------------------------------------------------------
$zipPath = ''
$zipHash = ''
$entryCount = 0

if ($NoZip) {
    Write-Step '5/6 跳过打包（-NoZip）'
    Write-Info ('组装目录: ' + $kitDir)
} else {
    Write-Step '5/6 打包 zip（约 10-20 分钟，请勿中断）'
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    }
    $zipName = 'DSH-migration-kit-' + $version + '-' + $stamp + '.zip'
    $zipPath = Join-Path $OutputDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    $tarArgs = @('--options', 'zip:compression=store', '-a', '-c', '-f', $zipPath, '-C', $WorkDir, $kitLeaf)
    & $tarExe @tarArgs
    if ($LASTEXITCODE -ne 0) {
        Fail ('打包失败（tar exit ' + $LASTEXITCODE + '），临时目录保留在: ' + $WorkDir)
    }
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Fail ('打包后未找到 zip: ' + $zipPath)
    }
    $zipItem = Get-Item -LiteralPath $zipPath
    $zipHash = Get-FileSha256 -Path $zipPath
    Write-Info ('zip: ' + $zipPath)
    Write-Info ('大小: ' + [math]::Round($zipItem.Length / 1GB, 2) + ' GB  SHA256: ' + $zipHash)

    # 校验归档内容
    $listing = @(& $tarExe -t -f $zipPath)
    if ($LASTEXITCODE -ne 0) { Fail ('zip 校验失败（tar -t exit ' + $LASTEXITCODE + '）') }
    $entryCount = $listing.Count
    $requiredEntries = @(
        ($kitLeaf + '/kit-manifest.json'),
        ($kitLeaf + '/RECOVERY-GUIDE.md'),
        ($kitLeaf + '/installer/' + $installerLeaf),
        ($kitLeaf + '/backup/manifest.json'),
        ($kitLeaf + '/backup/scripts/start-restore.ps1'),
        ($kitLeaf + '/backup/config/profiles/web/cordis.patch.yml.fixed')
    )
    $missing = @()
    foreach ($needle in $requiredEntries) {
        $hit = @($listing | Where-Object { $_ -eq $needle })
        if ($hit.Count -eq 0) { $missing += $needle }
    }
    if ($missing.Count -gt 0) {
        Fail ('zip 缺少关键条目: ' + ($missing -join '; '))
    }
    Write-Info ('校验通过: ' + $entryCount + ' 个条目，关键文件齐全')

    $shaText = @(
        '# DSH 迁移包 SHA256 校验',
        ('# 文件: ' + $zipName),
        ('# 用法: Get-FileHash -Algorithm SHA256 "' + $zipPath + '"'),
        ('#       或 Linux: sha256sum "' + $zipName + '"'),
        '',
        ($zipHash + '  ' + $zipName)
    )
    $shaText | Set-Content -LiteralPath ($zipPath + '.sha256') -Encoding UTF8
}

# ---------------------------------------------------------------------------
# 6. 清理旧备份 + staging
# ---------------------------------------------------------------------------
Write-Step '6/6 清理旧备份与临时文件'

if (-not $NoZip -and -not $NoPrune) {
    if ($Keep -le 0) {
        Write-Info 'Keep<=0，不清理旧备份。'
    } else {
        $keepOld = $Keep - 1
        $oldZips = @(Get-ChildItem -LiteralPath $OutputDir -File -Filter 'DSH-migration-kit-*.zip' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $zipPath } |
            Sort-Object LastWriteTime -Descending)
        $toDelete = @($oldZips | Select-Object -Skip $keepOld)
        $deleted = 0
        foreach ($f in $toDelete) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $shaPath = $f.FullName + '.sha256'
                if (Test-Path -LiteralPath $shaPath) { Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue }
                Write-Info ('已删除旧备份: ' + $f.Name)
                $deleted = $deleted + 1
            } catch {
                Write-Warn ('删除旧备份失败: ' + $f.FullName + '（' + $_.Exception.Message + '）')
            }
        }
        if ($deleted -eq 0) { Write-Info '没有需要删除的旧备份。' }
        # 清理失去对应 zip 的 .sha256 孤文件
        $orphanShas = @(Get-ChildItem -LiteralPath $OutputDir -File -Filter 'DSH-migration-kit-*.zip.sha256' -ErrorAction SilentlyContinue)
        foreach ($s in $orphanShas) {
            $candidate = $s.FullName.Substring(0, $s.FullName.Length - '.sha256'.Length)
            if (-not (Test-Path -LiteralPath $candidate)) {
                Remove-Item -LiteralPath $s.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
} else {
    if ($NoZip) { Write-Info '未打包 zip，跳过旧备份清理。' }
    if ($NoPrune) { Write-Info '按参数 -NoPrune 跳过旧备份清理。' }
}

if ($KeepStaging) {
    Write-Info ('保留组装目录: ' + $WorkDir)
} else {
    $cleanupOk = $false
    try {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction Stop
        $cleanupOk = $true
    } catch {
        $cleanupOk = $false
    }
    if (-not $cleanupOk) {
        # 兜底：个别 node_modules 深层路径会让 PowerShell 递归删除失败，改用 cmd 的 rd 强删
        $cmdLine = 'rd /s /q "' + $WorkDir + '"'
        & cmd.exe /c $cmdLine 2>$null | Out-Null
        $cleanupOk = -not (Test-Path -LiteralPath $WorkDir)
    }
    if ($cleanupOk) {
        Write-Info '已清理临时组装目录。'
    } else {
        Write-Warn ('清理临时目录失败（可手工删除）: ' + $WorkDir)
    }
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '================ 备份完成 ================' -ForegroundColor Green
Write-Info ('DSH 版本 : ' + $version)
Write-Info ('备份时间 : ' + $stamp)
if ($zipPath) {
    Write-Info ('输出文件 : ' + $zipPath)
    Write-Info ('文件大小 : ' + [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1GB, 2) + ' GB')
    Write-Info ('SHA256   : ' + $zipHash)
    Write-Info ('归档条目 : ' + $entryCount)
} else {
    Write-Info ('组装目录 : ' + $kitDir)
}
Write-Info ('恢复方式 : 新机解压后，按 RECOVERY-GUIDE.md 由新会话 AI 执行 backup\scripts\start-restore.ps1')
Write-Info '注意     : 迁移包不含登录凭据与 API Key，恢复后需重新登录并重填 API Key。'
Write-Host '==========================================' -ForegroundColor Green

exit 0
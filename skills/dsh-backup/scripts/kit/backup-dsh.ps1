<#
.SYNOPSIS
    备份 DSH（DeepSeek Harness）的插件、插件配置与离线依赖，便于在另一台电脑上原样恢复。

.DESCRIPTION
    备份内容：
        config\                   %USERPROFILE%\.dsh 下的配置与插件配置（profiles、skins、skills、storages 等）
        offline\profiles\         各 profile 已安装的 node_modules（离线恢复用，可跳过）
        user-data-optional\       会话记录 sessions\ 与附件 attachments\（加 -IncludeUserData 时）
        scripts\                  恢复 / 校验脚本
        manifest.json             文件清单 + SHA256 + 版本信息
        README.md                 恢复说明

    典型用法：
        powershell -ExecutionPolicy Bypass -File .\scripts\backup-dsh.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\backup-dsh.ps1 -OutputDir "D:\DSH-backup-20261105" -IncludeUserData -FullZip

    警告：默认会备份 .credentials.yaml（明文保存登录 token 与 API Key）。
          请像保管密码一样保管整个备份目录。

.PARAMETER OutputDir
    备份输出目录。默认：<脚本上级目录>\DSH-backup-<yyyyMMdd-HHmm>
.PARAMETER DshHome
    DSH 数据目录。默认为环境变量 DSH_HOME，否则 %USERPROFILE%\.dsh
.PARAMETER IncludeUserData
    额外备份 sessions\ 与 attachments\（体积较大，非必需）
.PARAMETER SkipOffline
    不复制 node_modules（轻量备份，恢复时需联网安装插件）
.PARAMETER Refresh
    刷新已存在的备份目录：重新复制配置、重建 manifest；离线数据已存在则复用
.PARAMETER FullZip
    额外生成包含离线依赖的完整 zip（约 1.8GB）
.PARAMETER NoZip
    不生成 zip
.PARAMETER ExcludeCredentials
    不备份 .credentials.yaml（恢复后需要在应用内重新登录，且部分 API Key 需重新配置）
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$DshHome,
    [switch]$IncludeUserData,
    [switch]$SkipOffline,
    [switch]$Refresh,
    [switch]$FullZip,
    [switch]$NoZip,
    [switch]$ExcludeCredentials
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

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

# robocopy 复制目录树；robocopy 退出码 < 8 表示成功
function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Info ('跳过（不存在）: ' + $Source)
        return
    }
    $rcArgs = @($Source, $Destination, '/E', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Fail ('robocopy 失败（exit ' + $LASTEXITCODE + '）: ' + $Source + ' -> ' + $Destination)
    }
}

# pnpm hoisted 布局离线迁移的关键文件
function Test-OfflineMarker {
    param([string]$NodeModulesPath)
    return (Test-Path -LiteralPath (Join-Path $NodeModulesPath '.modules.yaml'))
}

# 修复非法 overlay：有些 profile 的 cordis.patch.yml 在顶格 [] 之后又跟了列表
function Repair-Overlay {
    param([string]$Source, [string]$FixedPath)
    # 注意：不能用 Get-Content（PS 5.1 默认按 ANSI/GBK 读取无 BOM 的 UTF-8 文件，中文会变乱码），
    # 必须显式按 UTF-8 读取并写回。
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $lines = @()
    try { $lines = @([System.IO.File]::ReadAllLines($Source, $utf8)) } catch { return $false }
    if ($lines.Count -eq 0) { return $false }
    $emptyIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '[]') { $emptyIndex = $i }
    }
    if ($emptyIndex -lt 0) { return $false }
    $hasList = $false
    for ($i = $emptyIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -match '^-(\s|$)') { $hasList = $true; break }
    }
    if (-not $hasList) { return $false }
    $fixed = New-Object System.Collections.Generic.List[string]
    $fixed.Add('# 由 backup-dsh.ps1 自动修复：原文件第 ' + ($emptyIndex + 1) + ' 行的“[]”与后续列表冲突，已移除该行。')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq $emptyIndex) { continue }
        $fixed.Add($lines[$i])
    }
    [System.IO.File]::WriteAllLines($FixedPath, [string[]]$fixed.ToArray(), $utf8)
    return $true
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

function Get-TreeStats {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $sum = [int64]0
    foreach ($f in $files) { $sum += $f.Length }
    return [pscustomobject]@{ fileCount = $files.Count; sizeBytes = $sum }
}

# ---------------------------------------------------------------------------
# 参数处理
# ---------------------------------------------------------------------------
if (-not $DshHome -or $DshHome.Trim().Length -eq 0) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
if (-not $OutputDir) {
    $parent = Split-Path -Parent $PSScriptRoot
    if (-not $parent) { $parent = (Get-Location).Path }
    $OutputDir = Join-Path $parent ('DSH-backup-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$DshHome = [System.IO.Path]::GetFullPath($DshHome)

Write-Step 'DSH 备份'
Write-Info ('DSH 数据目录 : ' + $DshHome)
Write-Info ('备份输出目录 : ' + $OutputDir)

if (-not (Test-Path -LiteralPath $DshHome)) { Fail ('DSH 数据目录不存在: ' + $DshHome) }
$profilesRoot = Join-Path $DshHome 'profiles'
if (-not (Test-Path -LiteralPath $profilesRoot)) { Fail ('未找到 profiles 目录: ' + $profilesRoot) }

$profileDirs = @(Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')
})
if ($profileDirs.Count -eq 0) { Fail 'profiles 下没有可备份的 profile（缺少 package.json）' }
$profileNames = @($profileDirs | ForEach-Object { $_.Name })

$installDir = Resolve-DshInstall
$desktopVersion = ''
if ($installDir) {
    $runtimeJson = Join-Path $installDir 'resources\runtime\primary-runtime\runtime.json'
    if (Test-Path -LiteralPath $runtimeJson) {
        try { $desktopVersion = (Get-Content -Raw -LiteralPath $runtimeJson | ConvertFrom-Json).desktopVersion } catch { }
    }
    if (-not $desktopVersion) {
        $exe = Join-Path $installDir 'DeepSeek Harness.exe'
        if (Test-Path -LiteralPath $exe) { $desktopVersion = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
    }
}
if (-not $desktopVersion) { $desktopVersion = 'unknown' }
Write-Info ('DSH 桌面版   : ' + $desktopVersion + '  (' + $installDir + ')')
Write-Info ('profiles     : ' + ($profileNames -join ', '))

if ((Test-Path -LiteralPath $OutputDir) -and (-not $Refresh)) {
    Fail ('输出目录已存在: ' + $OutputDir + [Environment]::NewLine + '如要刷新该备份，请加 -Refresh；或指定新的 -OutputDir。')
}

$configDir = Join-Path $OutputDir 'config'
$scriptsDir = Join-Path $OutputDir 'scripts'
$offlineRoot = Join-Path $OutputDir 'offline\profiles'
$userDataRoot = Join-Path $OutputDir 'user-data-optional'
$zipDir = Join-Path $OutputDir 'zips'
foreach ($d in @($configDir, (Join-Path $configDir 'profiles'), $scriptsDir, $offlineRoot, $userDataRoot, $zipDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ---------------------------------------------------------------------------
# 1. 配置与数据
# ---------------------------------------------------------------------------
Write-Step '复制配置与插件数据'
$excludedDirs = @('profiles', 'sessions', 'attachments', 'cache', 'dsh-runtimes', 'node_modules', '.pnpm-store')
$topDirs = @(Get-ChildItem -LiteralPath $DshHome -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
    $excludedDirs -notcontains $_.Name
})
foreach ($dir in $topDirs) {
    Write-Info ('目录 ' + $dir.Name)
    Copy-Tree -Source $dir.FullName -Destination (Join-Path $configDir $dir.Name)
}

$topFiles = @(Get-ChildItem -LiteralPath $DshHome -File -Force -ErrorAction SilentlyContinue)
foreach ($file in $topFiles) {
    if ($ExcludeCredentials -and $file.Name -eq '.credentials.yaml') { continue }
    if ($file.Name -like '*.log') { continue }
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $configDir $file.Name) -Force
}
if ($ExcludeCredentials) { Write-Warn '按参数要求未备份 .credentials.yaml（恢复后需重新登录并补配 API Key）' }

Write-Step '复制 profile 配置'
foreach ($profile in $profileDirs) {
    $dstProfile = Join-Path $configDir ('profiles\' + $profile.Name)
    New-Item -ItemType Directory -Force -Path $dstProfile | Out-Null
    foreach ($name in @('package.json', 'cordis.yml', 'cordis.patch.yml', 'pnpm-workspace.yaml', 'pnpm-lock.yaml', '.npmrc')) {
        $src = Join-Path $profile.FullName $name
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $dstProfile $name) -Force
            Write-Info ('profile ' + $profile.Name + '\' + $name)
        }
    }
    $patch = Join-Path $dstProfile 'cordis.patch.yml'
    if (Test-Path -LiteralPath $patch) {
        if (Repair-Overlay -Source $patch -FixedPath ($patch + '.fixed')) {
            Write-Info ('  已生成修复版 overlay: ' + $patch + '.fixed')
        }
    }
}

# ---------------------------------------------------------------------------
# 2. 离线依赖
# ---------------------------------------------------------------------------
if (-not $SkipOffline) {
    Write-Step '复制离线依赖（node_modules）'
    foreach ($name in $profileNames) {
        $srcNm = Join-Path $DshHome ('profiles\' + $name + '\node_modules')
        if (-not (Test-Path -LiteralPath $srcNm)) {
            Write-Info ('profile ' + $name + ': 没有 node_modules，跳过')
            continue
        }
        $dstNm = Join-Path $offlineRoot ($name + '\node_modules')
        if ($Refresh -and (Test-OfflineMarker -NodeModulesPath $dstNm)) {
            Write-Info ('profile ' + $name + ': 复用已存在的离线数据')
            continue
        }
        Write-Info ('profile ' + $name + ': 复制 node_modules（可能较慢，请耐心等待）')
        Copy-Tree -Source $srcNm -Destination $dstNm
    }
} else {
    Write-Info '已跳过离线依赖（-SkipOffline）'
}

# ---------------------------------------------------------------------------
# 3. 可选用户数据
# ---------------------------------------------------------------------------
if ($IncludeUserData) {
    Write-Step '复制用户数据（sessions / attachments）'
    foreach ($rel in @('sessions', 'attachments')) {
        $src = Join-Path $DshHome $rel
        if (Test-Path -LiteralPath $src) {
            Write-Info ('复制 ' + $rel)
            Copy-Tree -Source $src -Destination (Join-Path $userDataRoot $rel)
        }
    }
}

# ---------------------------------------------------------------------------
# 4. 复制脚本与说明
# ---------------------------------------------------------------------------
Write-Step '复制脚本与说明文档'
if ($PSScriptRoot) {
    Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File | ForEach-Object {
        $dstScript = [System.IO.Path]::GetFullPath((Join-Path $scriptsDir $_.Name))
        if ([System.IO.Path]::GetFullPath($_.FullName) -ne $dstScript) {
            Copy-Item -LiteralPath $_.FullName -Destination $scriptsDir -Force
        }
    }
}
$scriptParent = $PSScriptRoot
if ($scriptParent) { $scriptParent = Split-Path -Parent $scriptParent }
if (-not $scriptParent) { $scriptParent = (Get-Location).Path }
$readmeSrc = [System.IO.Path]::GetFullPath((Join-Path $scriptParent 'README.md'))
$readmeDst = [System.IO.Path]::GetFullPath((Join-Path $OutputDir 'README.md'))
if ((Test-Path -LiteralPath $readmeSrc) -and ($readmeSrc -ne $readmeDst)) {
    Copy-Item -LiteralPath $readmeSrc -Destination $readmeDst -Force
}
if (-not (Test-Path -LiteralPath (Join-Path $OutputDir 'README.md'))) {
    Write-Warn '未找到 README.md 模板，请手工补充恢复说明。'
}

# ---------------------------------------------------------------------------
# 5. manifest.json
# ---------------------------------------------------------------------------
Write-Step '生成 manifest.json'
$fileEntries = New-Object System.Collections.Generic.List[object]
$hashTargets = New-Object System.Collections.Generic.List[object]
foreach ($rel in @('config', 'scripts')) {
    $root = Join-Path $OutputDir $rel
    if (Test-Path -LiteralPath $root) {
        foreach ($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) { $hashTargets.Add($f) }
    }
}
$readmeFile = Join-Path $OutputDir 'README.md'
if (Test-Path -LiteralPath $readmeFile) { $hashTargets.Add((Get-Item -LiteralPath $readmeFile)) }
foreach ($f in $hashTargets) {
    $rel = $f.FullName.Substring($OutputDir.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
    $fileEntries.Add([pscustomobject]@{ path = $rel; size = [int64]$f.Length; sha256 = $hash })
}
Write-Info ('已计算哈希的文件数: ' + $fileEntries.Count)

$offlineEntries = New-Object System.Collections.Generic.List[object]
foreach ($name in $profileNames) {
    $nm = Join-Path $offlineRoot ($name + '\node_modules')
    if (Test-Path -LiteralPath $nm) {
        $stats = Get-TreeStats -Path $nm
        $offlineEntries.Add([pscustomobject]@{ profile = $name; fileCount = $stats.fileCount; sizeBytes = $stats.sizeBytes })
        Write-Info ('离线 ' + $name + ': ' + $stats.fileCount + ' 文件, ' + [math]::Round($stats.sizeBytes / 1MB, 1) + ' MB')
    }
}

$userData = $null
if ($IncludeUserData) {
    $userData = [pscustomobject]@{}
    foreach ($rel in @('sessions', 'attachments')) {
        $p = Join-Path $userDataRoot $rel
        if (Test-Path -LiteralPath $p) {
            $stats = Get-TreeStats -Path $p
            $userData | Add-Member -NotePropertyName $rel -NotePropertyValue ([pscustomobject]@{ fileCount = $stats.fileCount; sizeBytes = $stats.sizeBytes })
        }
    }
}

$depsCount = 0
$bundlesCount = 0
$desktopPkg = Join-Path $configDir 'profiles\desktop\package.json'
if (Test-Path -LiteralPath $desktopPkg) {
    try {
        $pkg = Get-Content -Raw -LiteralPath $desktopPkg | ConvertFrom-Json
        if ($pkg.dependencies) { $depsCount = @($pkg.dependencies.PSObject.Properties).Count }
        if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $bundlesCount = @($pkg.dsh.profile.bundles).Count }
    } catch { }
}

$manifest = [pscustomobject]@{
    format        = 'dsh-backup'
    formatVersion = 1
    createdAt     = (Get-Date).ToString('o')
    createdBy     = 'backup-dsh.ps1'
    host          = [pscustomobject]@{
        computerName = $env:COMPUTERNAME
        userName     = $env:USERNAME
        os           = [System.Environment]::OSVersion.VersionString
    }
    dsh           = [pscustomobject]@{
        desktopVersion = $desktopVersion
        installDir     = $installDir
        dshHome        = $DshHome
        profiles       = $profileNames
        dependencies   = $depsCount
        bundles        = $bundlesCount
    }
    options       = [pscustomobject]@{
        offline            = ($offlineEntries.Count -gt 0)
        includeUserData    = [bool]$IncludeUserData
        credentialsIncluded = (-not $ExcludeCredentials)
    }
    files         = $fileEntries
    offline       = [pscustomobject]@{ profiles = $offlineEntries }
    userData      = $userData
}
$manifestPath = Join-Path $OutputDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Info ('manifest: ' + $manifestPath)

# ---------------------------------------------------------------------------
# 6. zip 归档
# ---------------------------------------------------------------------------
if (-not $NoZip) {
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tarExe)) {
        Write-Warn '未找到 tar.exe，跳过 zip 生成（备份目录本身已可用）。'
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
        $baseName = 'DSH-' + $desktopVersion + '-' + $stamp
        $configZip = Join-Path $zipDir ($baseName + '-config.zip')
        Write-Step ('生成配置 zip: ' + $configZip)
        & $tarExe -a -c -f $configZip -C $OutputDir 'README.md' 'manifest.json' 'config' 'scripts'
        if ($LASTEXITCODE -ne 0) {
            Write-Warn ('配置 zip 生成失败（exit ' + $LASTEXITCODE + '）: ' + $configZip)
        } else {
            Write-Info ('配置 zip 大小: ' + [math]::Round((Get-Item -LiteralPath $configZip).Length / 1MB, 2) + ' MB')
        }
        if ($FullZip) {
            # 注意：PowerShell 变量名不区分大小写，不能把字符串赋给 $fullZip（会与 [switch]$FullZip 冲突）
            $fullZipPath = Join-Path $zipDir ($baseName + '-full.zip')
            Write-Step ('生成完整 zip（含离线依赖，可能需数分钟）: ' + $fullZipPath)
            & $tarExe -a -c -f $fullZipPath -C $OutputDir 'README.md' 'manifest.json' 'config' 'scripts' 'offline' 'user-data-optional'
            if ($LASTEXITCODE -ne 0) {
                Write-Warn ('完整 zip 生成失败（exit ' + $LASTEXITCODE + '）: ' + $fullZipPath)
                Write-Warn '（node_modules 路径较长时 tar 可能失败；可直接复制整个备份目录代替 zip。）'
            } else {
                Write-Info ('完整 zip 大小: ' + [math]::Round((Get-Item -LiteralPath $fullZipPath).Length / 1MB, 2) + ' MB')
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------
Write-Step '备份完成'
$configStats = Get-TreeStats -Path (Join-Path $OutputDir 'config')
Write-Info ('配置文件: ' + $configStats.fileCount + ' 个, ' + [math]::Round($configStats.sizeBytes / 1MB, 2) + ' MB')
foreach ($entry in $offlineEntries) {
    Write-Info ('离线依赖 ' + $entry.profile + ': ' + $entry.fileCount + ' 文件, ' + [math]::Round($entry.sizeBytes / 1MB, 1) + ' MB')
}
if ($userData) {
    foreach ($rel in @('sessions', 'attachments')) {
        if ($userData.PSObject.Properties.Name -contains $rel) {
            $u = $userData.$rel
            Write-Info ('用户数据 ' + $rel + ': ' + $u.fileCount + ' 文件, ' + [math]::Round($u.sizeBytes / 1MB, 1) + ' MB')
        }
    }
}
Write-Info ('备份目录: ' + $OutputDir)
Write-Host ''
if (-not $ExcludeCredentials) {
    Write-Warn '.credentials.yaml 含明文登录凭据与 API Key，请勿上传网盘/代码仓库，建议加密保管。'
}
Write-Host '恢复到另一台电脑：'
Write-Host '  1) 安装同一版本 DSH 桌面版并完全退出（含托盘图标）。'
Write-Host '  2) 运行  powershell -ExecutionPolicy Bypass -File .\scripts\restore-dsh.ps1'
Write-Host '     （默认恢复历史会话与附件；插件异常/会话打不开时再跑 .\scripts\fix-restored-dsh.ps1）'
Write-Host '  3) 启动 DSH，按 README.md 的自检清单核对插件与模型。'
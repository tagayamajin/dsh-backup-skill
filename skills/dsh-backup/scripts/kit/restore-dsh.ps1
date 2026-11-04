<#
.SYNOPSIS
    在另一台电脑（或重装后的同一台电脑）上恢复 DSH（DeepSeek Harness）的配置与插件。

.DESCRIPTION
    恢复流程：
        1. 检查 DSH 桌面版已安装且已完全退出（含任务栏托盘）；
        2. 把现有 DSH 数据目录改名保存为 .dsh.bak-<时间>，不会直接删除；
        3. 复制备份中的 config\ 到 DSH 数据目录；
        4. 修复 web profile 的非法 overlay（使用备份中的 cordis.patch.yml.fixed）；
        5. 恢复插件依赖：优先离线复制 node_modules，否则用 DSH 随附 node/pnpm 联网安装；
           复制后强制校验每个 profile 的依赖都能解析，不通过则中止并报错（不会“假成功”）；
        6. 恢复 sessions\ 与 attachments\（默认执行，-SkipUserData 可关闭）；
        7. 用 CLI 校验 web profile 的配置能正常加载。

    使用前必须完全退出 DSH（包括任务栏托盘里的图标）。

    典型用法：
        powershell -ExecutionPolicy Bypass -File .\scripts\restore-dsh.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\restore-dsh.ps1 -Plugins Offline
        powershell -ExecutionPolicy Bypass -File .\scripts\restore-dsh.ps1 -SkipUserData
        powershell -ExecutionPolicy Bypass -File .\scripts\restore-dsh.ps1 -DryRun

.PARAMETER BackupDir
    备份根目录（包含 config\ 的目录）。默认为脚本所在目录的上一级。
.PARAMETER DshHome
    目标 DSH 数据目录。默认为环境变量 DSH_HOME，否则 %USERPROFILE%\.dsh
.PARAMETER Plugins
    Auto（默认）：备份里有离线 node_modules 就离线恢复，否则联网安装；
    Offline：只使用备份中的离线 node_modules；
    Online：用 DSH 随附的 node/pnpm 执行 pnpm install（需要网络）。
.PARAMETER IncludeUserData
    已废弃：现在默认就会恢复 sessions\ 与 attachments\；保留该开关仅为兼容旧命令。
.PARAMETER SkipUserData
    不恢复会话记录与附件（只恢复配置、插件与凭据）。
.PARAMETER SkipCredentials
    不恢复 .credentials.yaml（需要在应用内重新登录，部分 API Key 需重新配置）。
.PARAMETER AllowVersionMismatch
    允许目标机 DSH 版本与备份版本不一致（不推荐）。
.PARAMETER SkipVerify
    跳过最后的 CLI 配置校验。
.PARAMETER DryRun
    只打印将要执行的操作，不修改任何文件。
.PARAMETER SkipProcessCheck
    仅供测试/自动化使用：跳过“DSH 是否已退出”的检查。正常恢复时不要使用本参数。
.PARAMETER WaitForExit
    如果检测到 DSH 仍在运行，先提示用户退出，并每 3 秒轮询等待，直到退出或超时后再继续恢复。
    这样可以在 DSH 内部启动一个后台恢复进程，用户随后关闭 DSH，恢复自动继续。
.PARAMETER WaitTimeoutMin
    配合 -WaitForExit：最长等待分钟数（默认 120）。
.PARAMETER RestartApp
    恢复成功后自动启动 DSH 桌面版。
.PARAMETER LogFile
    日志文件路径。默认写入 %TEMP%\dsh-restore-<时间戳>.log，并自动开启 PowerShell transcript。
#>
[CmdletBinding()]
param(
    [string]$BackupDir,
    [string]$DshHome,
    [ValidateSet('Auto', 'Offline', 'Online')]
    [string]$Plugins = 'Auto',
    [switch]$IncludeUserData,
    [switch]$SkipUserData,
    [switch]$SkipCredentials,
    [switch]$AllowVersionMismatch,
    [switch]$SkipVerify,
    [switch]$DryRun,
    [switch]$SkipProcessCheck,
    [switch]$WaitForExit,
    [int]$WaitTimeoutMin = 120,
    [switch]$RestartApp,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 日志：始终记录到文件，便于无人值守/后台恢复时排查
if (-not $LogFile -or $LogFile.Trim().Length -eq 0) {
    $LogFile = Join-Path $env:TEMP ('dsh-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}
$script:transcriptOn = $false
try {
    Start-Transcript -LiteralPath $LogFile -Append -ErrorAction Stop | Out-Null
    $script:transcriptOn = $true
} catch {
    Write-Host ('[警告] 无法开启日志 transcript: ' + $_.Exception.Message)
}

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

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Info ('跳过（不存在）: ' + $Source)
        return
    }
    if ($DryRun) {
        Write-Info ('[DryRun] robocopy ' + $Source + ' -> ' + $Destination)
        return
    }
    $rcArgs = @($Source, $Destination, '/E', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Fail ('robocopy 失败（exit ' + $LASTEXITCODE + '）: ' + $Source + ' -> ' + $Destination)
    }
}

function Test-ProfileModules {
    param([string]$Name, [string]$ProfileDir, [string]$NodeModules)
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath (Join-Path $NodeModules '.modules.yaml'))) {
        $problems.Add('.modules.yaml 缺失')
    }
    $deps = @()
    $pkgJson = Join-Path $ProfileDir 'package.json'
    if (Test-Path -LiteralPath $pkgJson) {
        try {
            $pkg = Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pkg.PSObject.Properties.Name -contains 'dependencies') {
                # 注意：dependencies 为空对象时 .PSObject.Properties.Name 返回 $null，
                # @($null) 会得到一个空元素，必须过滤掉，否则会误报“缺少依赖: ”。
                $deps = @($pkg.dependencies.PSObject.Properties.Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        } catch {
            $problems.Add('package.json 解析失败: ' + $_.Exception.Message)
        }
    } else {
        $problems.Add('package.json 缺失')
    }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($dep in $deps) {
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $NodeModules $dep) 'package.json'))) {
            $missing.Add($dep)
        }
    }
    if ($missing.Count -gt 0) {
        $problems.Add('缺少依赖: ' + (($missing | Sort-Object) -join ', '))
    }
    $topCount = 0
    if (Test-Path -LiteralPath $NodeModules) {
        $topCount = @(Get-ChildItem -LiteralPath $NodeModules -Directory -Force -ErrorAction SilentlyContinue).Count
    }
    return [pscustomobject]@{
        Name = $Name
        Problems = $problems
        DependencyCount = $deps.Count
        MissingCount = $missing.Count
        TopLevelCount = $topCount
    }
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

function Get-DshProcesses {
    param([string]$InstallDir)
    $result = New-Object System.Collections.Generic.List[object]

    # 优先用 Get-Process：在某些受限环境下 Get-CimInstance 会返回空列表（静默失败）
    $list = @()
    try { $list = @(Get-Process -ErrorAction SilentlyContinue) } catch { $list = @() }
    foreach ($p in $list) {
        $isDsh = $false
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        if ($InstallDir -and $path -and $path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { $isDsh = $true }
        if ($p.ProcessName -like 'DeepSeek Harness*') { $isDsh = $true }
        if ($isDsh) {
            $result.Add([pscustomobject]@{ Name = $p.ProcessName; ProcessId = $p.Id; ExecutablePath = $path })
        }
    }
    if ($result.Count -gt 0) { return $result }

    # 兜底：Get-Process 不可用或没查到时，再尝试 CIM
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)) {
        $isDsh = $false
        if ($InstallDir -and $p.ExecutablePath -and $p.ExecutablePath.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { $isDsh = $true }
        if ($p.Name -like 'DeepSeek Harness*') { $isDsh = $true }
        if ($isDsh) {
            $result.Add([pscustomobject]@{ Name = $p.Name; ProcessId = $p.ProcessId; ExecutablePath = $p.ExecutablePath })
        }
    }
    return $result
}

function Repair-ModulesYamlPaths {
    # pnpm 的 .modules.yaml 记录了源机的绝对路径（storeDir / virtualStoreDir）。
    # 原样拷到新机后，pnpm 会报 ERR_PNPM_UNEXPECTED_STORE，插件页的安装/更新/卸载全部失败。
    # 这里把两条路径改写为目标机的路径（文件是 JSON 风格，反斜杠需要转义）。
    param([string]$ProfileDir, [string]$NodeModules)
    $yaml = Join-Path $NodeModules '.modules.yaml'
    if (-not (Test-Path -LiteralPath $yaml)) {
        Write-Warn ('未找到 .modules.yaml，跳过 pnpm 路径改写: ' + $ProfileDir)
        return $false
    }
    $storeDir = Join-Path $env:LOCALAPPDATA 'pnpm\store\v11'
    $virtualStoreDir = Join-Path $ProfileDir 'node_modules\.pnpm'
    $escStore = $storeDir.Replace('\', '\\')
    $escVirtual = $virtualStoreDir.Replace('\', '\\')
    $lines = @(Get-Content -LiteralPath $yaml)
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?<indent>\s*)"storeDir"\s*:') {
            $new = $Matches['indent'] + '"storeDir": "' + $escStore + '",'
            if ($lines[$i] -ne $new) { $lines[$i] = $new; $changed = $true }
            continue
        }
        if ($lines[$i] -match '^(?<indent>\s*)"virtualStoreDir"\s*:') {
            $new = $Matches['indent'] + '"virtualStoreDir": "' + $escVirtual + '",'
            if ($lines[$i] -ne $new) { $lines[$i] = $new; $changed = $true }
            continue
        }
    }
    if ($changed) {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($yaml, $lines, $utf8)
        Write-Info ('已改写 .modules.yaml 的 pnpm 路径 -> ' + $storeDir)
        try { Get-Content -Raw -LiteralPath $yaml | ConvertFrom-Json | Out-Null }
        catch { Write-Warn ('改写后 .modules.yaml 无法按 JSON 解析（请检查该文件）: ' + $yaml) }
    } else {
        Write-Info ('.modules.yaml 路径无需改写: ' + $ProfileDir)
    }
    return $changed
}

function Get-ReferencedPlugins {
    # 从 profile 的 cordis.patch.yml 提取被引用的插件包名（name: 行）。
    # 用于提示“配置里引用了、但 node_modules 里没有实体包”的插件（如源机本身未安装的皮肤包）。
    param([string]$ProfileDir)
    $names = New-Object System.Collections.Generic.List[string]
    $patch = Join-Path $ProfileDir 'cordis.patch.yml'
    if (-not (Test-Path -LiteralPath $patch)) { return $names }
    foreach ($line in @(Get-Content -LiteralPath $patch -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*-?\s*name\s*:\s*[''"]?([^\s''"#]+)[''"]?\s*(#.*)?$') {
            $n = $Matches[1].Trim()
            # 只关心第三方插件：跳过应用内置的 @deepseek-ai/*（随 app.asar 分发）、
            # cordis:group 之类的内部引用、以及 GLM-5 等模型名（首字母大写）。
            if ($n -match '^@deepseek-ai/' -or $n -match ':' -or $n -cmatch '^[A-Z]') { continue }
            if ($n -and -not $names.Contains($n)) { $names.Add($n) }
        }
    }
    return $names
}

function Add-MissingWorkspaceDirs {
    # 历史会话记录了工作区路径（storages\session_projcache\sessions\*.json 的 record.identity.cwd）。
    # 新机没有这些目录时，会话列表能显示、点开会异常；这里默认补建空目录（项目代码不在迁移包内）。
    param([string]$HomeDir)
    $projcacheDir = Join-Path $HomeDir 'storages\session_projcache\sessions'
    if (-not (Test-Path -LiteralPath $projcacheDir)) {
        Write-Info '没有会话投影缓存，跳过工作区目录检查。'
        return
    }
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $projcacheDir -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
            $cwd = $null
            if ($j.record -and $j.record.identity -and $j.record.identity.cwd) { $cwd = [string]$j.record.identity.cwd }
            if ($cwd -and $cwd.Trim().Length -gt 0 -and -not $paths.Contains($cwd)) { $paths.Add($cwd) }
        } catch { }
    }
    if ($paths.Count -eq 0) {
        Write-Info '没有从会话缓存中找到工作区路径，跳过。'
        return
    }
    $created = 0
    foreach ($wp in $paths) {
        if (Test-Path -LiteralPath $wp) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $wp | Out-Null
            Write-Info ('已补建会话工作区目录: ' + $wp)
            $created++
        } catch {
            Write-Warn ('无法创建工作区目录（对应旧会话可能打不开）: ' + $wp)
        }
    }
    if ($created -eq 0) {
        Write-Info ('历史会话的 ' + $paths.Count + ' 个工作区目录均存在。')
    } else {
        Write-Info ('共补建 ' + $created + ' 个工作区目录。')
    }
}

# ---------------------------------------------------------------------------
# 参数与备份检查
# ---------------------------------------------------------------------------
if (-not $DshHome -or $DshHome.Trim().Length -eq 0) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME } else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
if (-not $BackupDir) {
    $parent = Split-Path -Parent $PSScriptRoot
    if (-not $parent) { $parent = (Get-Location).Path }
    $BackupDir = $parent
}
$BackupDir = [System.IO.Path]::GetFullPath($BackupDir)
$DshHome = [System.IO.Path]::GetFullPath($DshHome)

Write-Step 'DSH 恢复'
Write-Info ('日志文件   : ' + $LogFile)
Write-Info ('备份目录   : ' + $BackupDir)
Write-Info ('DSH 数据目录: ' + $DshHome)
Write-Info ('插件恢复方式: ' + $Plugins + $(if ($DryRun) { '  (DryRun)' } else { '' }))

$configDir = Join-Path $BackupDir 'config'
if (-not (Test-Path -LiteralPath $configDir)) {
    Fail ('备份不完整：未找到 ' + $configDir + [Environment]::NewLine + '请确认脚本位于备份目录的 scripts\ 下，或用 -BackupDir 指定备份根目录。')
}
$backupProfiles = @(Get-ChildItem -LiteralPath (Join-Path $configDir 'profiles') -Directory -ErrorAction SilentlyContinue)
if ($backupProfiles.Count -eq 0) { Fail '备份中没有 profile 配置（config\profiles 为空）。' }

$manifest = $null
$manifestPath = Join-Path $BackupDir 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    try { $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json } catch { Write-Warn 'manifest.json 解析失败，继续但不做版本校验。' }
}

$installDir = Resolve-DshInstall
if (-not $installDir) {
    Fail '未检测到已安装的 DSH 桌面版。请先安装同版本 DSH 后再恢复（安装器来自旧机或 DeepSeek 官网）。'
}
$targetVersion = ''
$runtimeJson = Join-Path $installDir 'resources\runtime\primary-runtime\runtime.json'
if (Test-Path -LiteralPath $runtimeJson) {
    try { $targetVersion = (Get-Content -Raw -LiteralPath $runtimeJson | ConvertFrom-Json).desktopVersion } catch { }
}
if (-not $targetVersion) { $targetVersion = (Get-Item -LiteralPath (Join-Path $installDir 'DeepSeek Harness.exe')).VersionInfo.ProductVersion }
$sourceVersion = ''
if ($manifest -and $manifest.dsh -and $manifest.dsh.desktopVersion) { $sourceVersion = [string]$manifest.dsh.desktopVersion }
Write-Info ('目标机 DSH : ' + $targetVersion)
Write-Info ('备份 DSH   : ' + $sourceVersion)
if ($sourceVersion -and $targetVersion -and ($sourceVersion -ne $targetVersion)) {
    if (-not $AllowVersionMismatch) {
        Fail ('版本不一致（备份 ' + $sourceVersion + '，目标机 ' + $targetVersion + '）。' + [Environment]::NewLine +
              '建议先在目标机安装与备份相同的版本；如坚持恢复，请加 -AllowVersionMismatch（插件可能无法加载）。')
    }
    Write-Warn '版本不一致，已按 -AllowVersionMismatch 继续。'
}

# ---------------------------------------------------------------------------
# 检查 DSH 是否已完全退出
# ---------------------------------------------------------------------------
$running = @(Get-DshProcesses -InstallDir $installDir)
if ($running.Count -gt 0) {
    $names = @($running | ForEach-Object { $_.Name + '(' + $_.ProcessId + ')' }) -join ', '
    if ($DryRun) {
        Write-Warn ('检测到 DSH 仍在运行: ' + $names + [Environment]::NewLine +
                    '（DryRun 仅提示，不修改文件；正式恢复前请完全退出 DSH。）')
    } elseif ($SkipProcessCheck) {
        Write-Warn ('已跳过进程检查（-SkipProcessCheck），但仍检测到 DSH 在运行: ' + $names + '。请确认这是测试环境。')
    } elseif ($WaitForExit) {
        Write-Warn ('检测到 DSH 仍在运行: ' + $names)
        Write-Host ''
        Write-Host '============================================================'
        Write-Host '  请在任务栏托盘右键 DSH 图标 -> 退出（完全退出应用）'
        Write-Host ('  脚本会自动等待，最多 ' + $WaitTimeoutMin + ' 分钟；退出后自动继续恢复，无需再操作。')
        Write-Host '============================================================'
        Write-Host ''
        $deadline = (Get-Date).AddMinutes($WaitTimeoutMin)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $running = @(Get-DshProcesses -InstallDir $installDir)
            if ($running.Count -eq 0) { break }
        }
        if ($running.Count -gt 0) {
            $still = @($running | ForEach-Object { $_.Name + '(' + $_.ProcessId + ')' }) -join ', '
            Fail ('等待超时：DSH 仍在运行: ' + $still + [Environment]::NewLine +
                  '请完全退出后重试，或用 -WaitTimeoutMin 延长等待时间。')
        }
        Write-Info 'DSH 已完全退出，继续恢复。'
    } else {
        Fail ('检测到 DSH 仍在运行: ' + $names + [Environment]::NewLine +
              '请完全退出 DSH（包括任务栏托盘图标 -> 退出），确认任务管理器中没有 DeepSeek Harness 进程后重试。' + [Environment]::NewLine +
              '提示：可加 -WaitForExit，让脚本等你退出后自动继续。')
    }
} else {
    Write-Info 'DSH 未在运行，可以继续。'
}

# 记录恢复开始前的 DSH 进程，配置复制前后比对，用于发现“恢复期间 DSH 被启动”。
$baselinePids = @(Get-DshProcesses -InstallDir $installDir | ForEach-Object { $_.ProcessId })

# ---------------------------------------------------------------------------
# 计划
# ---------------------------------------------------------------------------
$offlineProfiles = Join-Path $BackupDir 'offline\profiles'
$hasOffline = $false
if (Test-Path -LiteralPath $offlineProfiles) {
    foreach ($p in @(Get-ChildItem -LiteralPath $offlineProfiles -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $p.FullName 'node_modules\.modules.yaml')) { $hasOffline = $true }
    }
}
$effectivePlugins = $Plugins
if ($Plugins -eq 'Auto') {
    if ($hasOffline) { $effectivePlugins = 'Offline' } else { $effectivePlugins = 'Online' }
}
if ($effectivePlugins -eq 'Offline' -and -not $hasOffline) {
    Fail '按 -Plugins Offline 恢复，但备份中没有离线 node_modules（offline\profiles\*\node_modules\.modules.yaml 不存在）。'
}

$oldHome = ''
if (Test-Path -LiteralPath $DshHome) {
    $oldHome = $DshHome + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
}

if ($DryRun) {
    Write-Step 'DryRun：将执行以下操作'
    if ($oldHome) { Write-Info ('将把现有数据目录改名为: ' + $oldHome) } else { Write-Info '目标数据目录不存在，将新建。' }
    Write-Info ('复制配置: ' + $configDir + ' -> ' + $DshHome)
    Write-Info '修复 web profile 的 cordis.patch.yml（用 .fixed 文件替换原文件，原文件保留为 .broken）'
    Write-Info ('插件恢复方式: ' + $effectivePlugins)
    if (-not $SkipUserData) { Write-Info '恢复 sessions\ 与 attachments\（若备份中存在）' }
    Write-Info '复制后改写 desktop/web 的 .modules.yaml（pnpm storeDir/virtualStoreDir），适配本机路径'
    Write-Info '按历史会话记录的工作区路径补建缺失目录（空目录，不含项目代码）'
    Write-Info '复制配置前后比对 DSH 进程，若恢复期间 DSH 被启动则报错中止'
    if (-not $SkipVerify) { Write-Info '最后执行 dsh --profile web --dump-config 校验配置' }
    Write-Host ''
    Write-Info 'DryRun 结束，未修改任何文件。'
    exit 0
}

# ---------------------------------------------------------------------------
# 1. 保存现有数据目录
# ---------------------------------------------------------------------------
Write-Step '处理现有 DSH 数据目录'
if ($oldHome) {
    Write-Info ('改名: ' + $DshHome + '  ->  ' + $oldHome)
    Move-Item -LiteralPath $DshHome -Destination $oldHome
} else {
    Write-Info '目标数据目录不存在，将新建。'
}
New-Item -ItemType Directory -Force -Path $DshHome | Out-Null

# ---------------------------------------------------------------------------
# 2. 复制配置
# ---------------------------------------------------------------------------
Write-Step '复制配置与插件数据'
Copy-Tree -Source $configDir -Destination $DshHome

# 修复 web（或其它 profile）的非法 overlay
Write-Step '处理 cordis.patch.yml 修复文件'
foreach ($profileDir in @(Get-ChildItem -LiteralPath (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue)) {
    $fixed = Join-Path $profileDir.FullName 'cordis.patch.yml.fixed'
    $patch = Join-Path $profileDir.FullName 'cordis.patch.yml'
    if (Test-Path -LiteralPath $fixed) {
        if (Test-Path -LiteralPath $patch) {
            Move-Item -LiteralPath $patch -Destination ($patch + '.broken') -Force
        }
        Move-Item -LiteralPath $fixed -Destination $patch -Force
        Write-Info ('已修复: ' + $patch)
    }
}

if ($SkipCredentials) {
    $cred = Join-Path $DshHome '.credentials.yaml'
    if (Test-Path -LiteralPath $cred) {
        Remove-Item -LiteralPath $cred -Force
        Write-Warn '已按 -SkipCredentials 删除 .credentials.yaml，请在应用内重新登录。'
    }
}

# 恢复期间如果有人启动了 DSH，运行中的 DSH 会改写配置（cordis.patch.yml、profile 的 package.json
# 与插件状态等），导致恢复结果与备份不一致 —— 这是“新机恢复后配置莫名其妙变了”的常见原因。
# 配置复制完成后立即比对进程与关键文件，发现问题就中止并给出明确处置办法。
Write-Step '检查恢复期间 DSH 是否被启动'
$newProcs = @(Get-DshProcesses -InstallDir $installDir | Where-Object { $baselinePids -notcontains $_.ProcessId })
if ($newProcs.Count -gt 0) {
    $pidText = (@($newProcs | ForEach-Object { [string]$_.ProcessId }) -join ', ')
    Fail ('恢复期间检测到 DSH 被启动（新进程 PID: ' + $pidText + '）。' + [Environment]::NewLine +
          '运行中的 DSH 会改写配置（cordis.patch.yml、profile 的 package.json、插件状态等），恢复结果将不可靠。' + [Environment]::NewLine +
          '请完全退出 DSH（任务栏托盘 -> 退出）后重新运行恢复脚本。')
} else {
    Write-Info '未发现恢复期间新启动的 DSH 进程。'
}

$backupProfilesDir = Join-Path $configDir 'profiles'
if (Test-Path -LiteralPath $backupProfilesDir) {
    foreach ($bp in @(Get-ChildItem -LiteralPath $backupProfilesDir -Directory -ErrorAction SilentlyContinue)) {
        $srcJson = Join-Path $bp.FullName 'package.json'
        $dstJson = Join-Path (Join-Path $DshHome ('profiles\' + $bp.Name)) 'package.json'
        if (-not (Test-Path -LiteralPath $srcJson)) { continue }
        if (-not (Test-Path -LiteralPath $dstJson)) {
            Fail ('恢复后缺少 profiles\' + $bp.Name + '\package.json，配置可能未完整复制。')
        }
        $srcHash = (Get-FileHash -LiteralPath $srcJson -Algorithm SHA256).Hash
        $dstHash = (Get-FileHash -LiteralPath $dstJson -Algorithm SHA256).Hash
        if ($srcHash -ne $dstHash) {
            Fail ('profiles\' + $bp.Name + '\package.json 与备份不一致（bundles/dependencies 可能被运行时改写）。' + [Environment]::NewLine +
                  '最常见原因是恢复期间 DSH 被启动；请完全退出 DSH 后重新运行恢复脚本。')
        }
        Write-Info ('[OK] profile ' + $bp.Name + ': package.json 与备份一致（bundles/dependencies 未被改写）')
    }
}

# ---------------------------------------------------------------------------
# 3. 插件
# ---------------------------------------------------------------------------
if ($effectivePlugins -eq 'Offline') {
    Write-Step '恢复离线插件依赖（node_modules）'
    foreach ($p in @(Get-ChildItem -LiteralPath $offlineProfiles -Directory -ErrorAction SilentlyContinue)) {
        $srcNm = Join-Path $p.FullName 'node_modules'
        if (-not (Test-Path -LiteralPath (Join-Path $srcNm '.modules.yaml'))) {
            Write-Warn ('离线数据不完整，跳过 profile: ' + $p.Name)
            continue
        }
        $dstProfile = Join-Path $DshHome ('profiles\' + $p.Name)
        if (-not (Test-Path -LiteralPath (Join-Path $dstProfile 'package.json'))) {
            Write-Warn ('目标 profile 不存在，跳过: ' + $p.Name)
            continue
        }
        Write-Info ('复制 profile ' + $p.Name + ' 的 node_modules（可能较慢）')
        Copy-Tree -Source $srcNm -Destination (Join-Path $dstProfile 'node_modules')

        # .modules.yaml 里记录的是源机的 pnpm store 路径，必须改写成本机路径，否则插件页会报
        # ERR_PNPM_UNEXPECTED_STORE，安装/更新/卸载插件全部失败。
        Repair-ModulesYamlPaths -ProfileDir $dstProfile -NodeModules (Join-Path $dstProfile 'node_modules') | Out-Null

        # 配置里引用了、但 node_modules 里没有实体包的插件（常见于源机本身未安装的皮肤包）：
        # 只警告不阻断，避免“恢复看似成功、打开插件页却报错”时无从定位。
        $refNames = @(Get-ReferencedPlugins -ProfileDir $dstProfile)
        $reportedRefs = New-Object System.Collections.Generic.List[string]
        foreach ($refName in $refNames) {
            if ($reportedRefs.Contains($refName)) { continue }
            $refPkg = Join-Path (Join-Path (Join-Path $dstProfile 'node_modules') ($refName -replace '/', '\')) 'package.json'
            if (-not (Test-Path -LiteralPath $refPkg)) {
                $reportedRefs.Add($refName)
                Write-Warn ('profile ' + $p.Name + ' 的 cordis.patch.yml 引用了插件 "' + $refName + '"，但 node_modules 中没有实体包（源机可能也未安装）；需要时请联网安装该插件。')
            }
        }
    }
    # 复制后强制校验：确认离线插件真的可用，避免“显示恢复完成、插件却全部异常”
    $failedProfiles = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-ChildItem -LiteralPath $offlineProfiles -Directory -ErrorAction SilentlyContinue)) {
        $srcNm = Join-Path $p.FullName 'node_modules'
        if (-not (Test-Path -LiteralPath (Join-Path $srcNm '.modules.yaml'))) { continue }
        $dstProfile = Join-Path $DshHome ('profiles\' + $p.Name)
        if (-not (Test-Path -LiteralPath (Join-Path $dstProfile 'package.json'))) { continue }
        $dstNm = Join-Path $dstProfile 'node_modules'
        if (-not (Test-Path -LiteralPath $dstNm)) {
            $failedProfiles.Add($p.Name + ': node_modules 未复制成功')
            continue
        }
        $check = Test-ProfileModules -Name $p.Name -ProfileDir $dstProfile -NodeModules $dstNm
        if ($check.Problems.Count -gt 0) {
            $failedProfiles.Add($p.Name + ': ' + ($check.Problems -join '；'))
        } else {
            Write-Info ('[OK] profile ' + $p.Name + ': ' + $check.DependencyCount + ' 个依赖全部可解析（node_modules 顶层 ' + $check.TopLevelCount + ' 个目录）')
        }
    }
    if ($failedProfiles.Count -gt 0) {
        foreach ($f in $failedProfiles) { Write-Warn ('校验失败: ' + $f) }
        Fail '离线插件恢复不完整（依赖缺失或 node_modules 不完整）。请检查备份文件与磁盘空间后重试；也可运行 backup\scripts\fix-restored-dsh.ps1 修复。'
    }
} else {
    Write-Step '联网安装插件依赖（pnpm install --no-frozen-lockfile）'
    $nodeExe = Join-Path $installDir 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
    $pnpmCjs = Join-Path $installDir 'resources\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.cjs'
    if (-not (Test-Path -LiteralPath $nodeExe)) { Fail ('未找到 DSH 随附的 node: ' + $nodeExe) }
    if (-not (Test-Path -LiteralPath $pnpmCjs)) { Fail ('未找到 DSH 随附的 pnpm: ' + $pnpmCjs) }
    $installedAny = $false
    foreach ($profileDir in @(Get-ChildItem -LiteralPath (Join-Path $DshHome 'profiles') -Directory -ErrorAction SilentlyContinue)) {
        $pkg = Join-Path $profileDir.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $pkg)) { continue }
        Write-Info ('安装 profile ' + $profileDir.Name + ' 依赖（需要网络，可能需要数分钟）')
        Push-Location -LiteralPath $profileDir.FullName
        try {
            & $nodeExe $pnpmCjs install --no-frozen-lockfile
            if ($LASTEXITCODE -ne 0) {
                Write-Warn ('profile ' + $profileDir.Name + ' 的 pnpm install 失败（exit ' + $LASTEXITCODE + '）。可稍后在应用内通过插件市场重装，或改用离线备份。')
            } else {
                $installedAny = $true
            }
        } finally {
            Pop-Location
        }
    }
    if (-not $installedAny) { Write-Warn '没有成功安装任何 profile 依赖，请检查网络后重试。' }
}

# ---------------------------------------------------------------------------
# 4. 用户数据（默认恢复，-SkipUserData 关闭）
# ---------------------------------------------------------------------------
if (-not $SkipUserData) {
    Write-Step '恢复用户数据（sessions / attachments）'
    foreach ($rel in @('sessions', 'attachments')) {
        $src = Join-Path $BackupDir ('user-data-optional\' + $rel)
        if (Test-Path -LiteralPath $src) {
            Write-Info ('恢复 ' + $rel)
            Copy-Tree -Source $src -Destination (Join-Path $DshHome $rel)
        } else {
            Write-Info ('备份中没有 ' + $rel + '，跳过')
        }
    }
    $srcSessions = Join-Path $BackupDir 'user-data-optional\sessions'
    if (Test-Path -LiteralPath $srcSessions) {
        $srcCount = @(Get-ChildItem -LiteralPath $srcSessions -Recurse -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue).Count
        $dstSessions = Join-Path $DshHome 'sessions'
        $dstCount = 0
        if (Test-Path -LiteralPath $dstSessions) {
            $dstCount = @(Get-ChildItem -LiteralPath $dstSessions -Recurse -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue).Count
        }
        Write-Info ('会话日志: 备份中 ' + $srcCount + ' 个，已恢复 ' + $dstCount + ' 个')
        if ($srcCount -gt 0 -and $dstCount -eq 0) {
            Fail '会话日志恢复失败（目标目录没有会话文件）。请检查备份文件与磁盘空间后重试。'
        }
        if ($dstCount -lt $srcCount) {
            Write-Warn ('会话日志数量少于备份（' + $dstCount + ' < ' + $srcCount + '），可能有文件被跳过。')
        }
    }
}

# 历史会话的工作区目录：新机通常没有这些目录，会话列表能看到但点开会异常。
# 这里按会话缓存里记录的 cwd 默认补建空目录（迁移包不含项目代码，项目文件需另外拷贝）。
Write-Step '检查历史会话的工作区目录'
Add-MissingWorkspaceDirs -HomeDir $DshHome

# ---------------------------------------------------------------------------
# 5. 校验
# ---------------------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Step '校验配置'
    $dshCmd = Join-Path $installDir 'resources\runtime\cli\bin\dsh.cmd'
    if (Test-Path -LiteralPath $dshCmd) {
        Write-Info '执行: dsh --profile web --dump-config'
        $oldHomeEnv = $env:DSH_HOME
        $env:DSH_HOME = $DshHome
        try {
            $output = & $dshCmd --profile web --dump-config 2>&1
            $code = $LASTEXITCODE
        } finally {
            $env:DSH_HOME = $oldHomeEnv
        }
        if ($code -eq 0) {
            Write-Info '配置校验通过（desktop profile 由应用自身管理，CLI 不直接校验）。'
        } else {
            Write-Warn ('配置校验未通过（exit ' + $code + '）。若日志显示 YAML 解析错误，请检查 profiles\web\cordis.patch.yml。')
            if ($output) { Write-Info (($output | Select-Object -First 10) -join [Environment]::NewLine + '    ') }
        }
    } else {
        Write-Warn ('未找到 CLI: ' + $dshCmd + '，跳过校验。')
    }
}

# ---------------------------------------------------------------------------
# 6. 启动（可选）
# ---------------------------------------------------------------------------
if ($RestartApp) {
    $appExe = Join-Path $installDir 'DeepSeek Harness.exe'
    if (Test-Path -LiteralPath $appExe) {
        Write-Step '启动 DSH'
        try {
            Start-Process -FilePath $appExe -WorkingDirectory $installDir
            Write-Info '已请求启动 DSH 桌面版，请在任务栏托盘确认。'
        } catch {
            Write-Warn ('自动启动 DSH 失败: ' + $_.Exception.Message + '，请手动启动。')
        }
    } else {
        Write-Warn ('未找到 DSH 可执行文件: ' + $appExe + '，请手动启动。')
    }
}

# ---------------------------------------------------------------------------
# 7. 完成
# ---------------------------------------------------------------------------
Write-Step '恢复完成'
if ($oldHome) { Write-Info ('原数据目录已保存到: ' + $oldHome) }
Write-Info ('数据目录: ' + $DshHome)
Write-Host ''
Write-Host '接下来：'
Write-Host ('  1) 启动 DSH 桌面版（版本 ' + $targetVersion + '）。')
Write-Host '  2) 进入设置检查：插件列表应全部为“已启用/已安装”（不应出现“异常/包不可用”）；'
Write-Host '     再检查默认模型、皮肤、任务板、Web UI 是否与本机一致。'
Write-Host '  3) 会话列表应能看到恢复的历史会话（sessions 已随本次恢复写入）。'
Write-Host '  4) 若旧会话点开异常：多为工作区目录不存在（本次恢复已按会话记录补建空目录）；'
Write-Host '     迁移包不含项目代码，项目文件需自行另行拷贝。'
Write-Host '  5) 若插件仍异常：不要点插件页的在线“安装/修复”，先运行同目录下 fix-restored-dsh.ps1 修复；'
Write-Host '     或参考 RECOVERY-GUIDE.md 的“恢复后插件异常”章节。'
Write-Host '  6) 若登录失效：删除 %USERPROFILE%\.dsh\.credentials.yaml 后重新登录。'
Write-Host ''
if (-not $SkipCredentials -and (Test-Path -LiteralPath (Join-Path $DshHome '.credentials.yaml'))) {
    Write-Warn '.credentials.yaml 已被复制（明文凭据），如目标机由他人使用，请改用 -SkipCredentials 恢复或删除该文件。'
}
Write-Host ''
Write-Host ('日志文件: ' + $LogFile)
if ($script:transcriptOn) {
    try { Stop-Transcript | Out-Null } catch { }
}
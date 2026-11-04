<#
.SYNOPSIS
    修复“恢复后插件全部异常 / 旧会话可见但打不开”的新机 DSH。

.DESCRIPTION
    在另一台机器上用 DSH 迁移包恢复后，可能出现两类问题：
      1) 插件全部显示“异常 / 包不可用”，报
         dsh: cannot resolve profile bundle "xxx" from the dsh installation or <home>\profiles\desktop
         原因：迁移包里的离线插件目录 (backup\offline\profiles\*\node_modules) 没有被复制到
         %USERPROFILE%\.dsh\profiles\<profile>\node_modules。
      2) 旧会话出现在列表里但无法打开。
         原因：只恢复了配置里的会话投影缓存 (storages\session_projcache)，真正的会话日志
         (sessions\<projectKey>\<sessionId>\session.v4.jsonl.zstd) 没有恢复。

    本脚本会自动定位迁移包解压目录，补齐这两部分内容，并在复制后逐个校验依赖是否可解析；
    校验不通过时以非 0 退出，不会“假装成功”。

    必须在 DSH 完全退出后运行（脚本默认会等待你退出，最多 10 分钟）。

.PARAMETER BackupDir
    迁移包的 backup 目录（含 config\ 的目录）；也可以直接给 DSH-kit-* 解压目录。
    当本脚本位于迁移包的 backup\scripts\ 下时可省略（自动使用上一级 backup 目录）；
    否则省略时自动在桌面 / 下载 / 文档 / 各盘根目录下寻找 DSH-kit-*\backup。

.PARAMETER DshHome
    DSH 数据目录，默认 %USERPROFILE%\.dsh。

.PARAMETER WaitTimeoutMin
    等待 DSH 进程退出的最长分钟数，默认 10。

.PARAMETER SkipOffline
    不修复插件（只修会话）。

.PARAMETER SkipUserData
    不恢复会话日志与附件。

.PARAMETER RestartApp
    修复完成后自动启动桌面版 DSH。

.PARAMETER DryRun
    只诊断与打印将要执行的动作，不写任何文件。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-restored-dsh.ps1 -RestartApp 5
#>
[CmdletBinding()]
param(
    [string]$BackupDir,
    [string]$DshHome = '',
    [int]$WaitTimeoutMin = 10,
    [switch]$SkipOffline,
    [switch]$SkipUserData,
    [switch]$SkipProcessCheck,
    [switch]$RestartApp,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- 基础工具
function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ('=== ' + $Text) -ForegroundColor Cyan
}
function Write-Ok([string]$Text)   { Write-Host ('  [OK]   ' + $Text) -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host ('  [警告] ' + $Text) -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host ('  [错误] ' + $Text) -ForegroundColor Red }
function Write-Info2([string]$Text) { Write-Host ('  [信息] ' + $Text) -ForegroundColor Gray }
function Fail([string]$Text) {
    Write-Err2 $Text
    Write-Host ''
    Write-Host '修复未完成，请把上面的输出（以及日志文件）发回。'
    if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
    exit 1
}
function Copy-Tree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warn2 ('源目录不存在，跳过: ' + $Source)
        return $false
    }
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $rcArgs = @($Source, $Destination, '/E', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    & robocopy @rcArgs | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Fail ('robocopy 复制失败（exit ' + $LASTEXITCODE + '）: ' + $Source + ' -> ' + $Destination)
    }
    return $true
}
function Get-TopDirCount([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue).Count
}
function Get-DshProcesses([string]$InstallDir) {
    $result = @()
    try {
        $procs = @(Get-Process -ErrorAction SilentlyContinue)
        foreach ($p in $procs) {
            if ($p.ProcessName -like 'DeepSeek Harness*') { $result += $p; continue }
            try {
                if ($InstallDir -and $p.Path -and $p.Path.StartsWith($InstallDir, [System.StringComparison]::OrdinalIgnoreCase)) { $result += $p }
            } catch { }
        }
    } catch { }
    if ($result.Count -eq 0) {
        try {
            $cim = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'DeepSeek Harness*' })
            foreach ($c in $cim) { $result += [pscustomobject]@{ Id = $c.ProcessId; ProcessName = $c.Name } }
        } catch { }
    }
    return $result
}
function Repair-ModulesYamlPaths([string]$ProfileDir) {
    # pnpm 的 .modules.yaml 记录源机的 storeDir / virtualStoreDir；原样拷到新机后 pnpm 会报
    # ERR_PNPM_UNEXPECTED_STORE，插件页安装/更新/卸载全部失败。这里改写成本机路径。
    $nm = Join-Path $ProfileDir 'node_modules'
    $yaml = Join-Path $nm '.modules.yaml'
    if (-not (Test-Path -LiteralPath $yaml)) {
        Write-Warn2 ('未找到 .modules.yaml，跳过 pnpm 路径改写: ' + $ProfileDir)
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
        Write-Ok ('已改写 .modules.yaml 的 pnpm 路径: ' + $storeDir)
    }
    return $changed
}
function Add-MissingWorkspaceDirs([string]$HomeDir) {
    # 按会话缓存里记录的 cwd 补建缺失的工作区目录（空目录，不含项目代码），
    # 否则历史会话在列表里可见、点开却异常。
    $projcacheDir = Join-Path $HomeDir 'storages\session_projcache\sessions'
    if (-not (Test-Path -LiteralPath $projcacheDir)) {
        Write-Info2 '没有会话投影缓存，跳过工作区目录检查。'
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
    $created = 0
    foreach ($wp in $paths) {
        if (Test-Path -LiteralPath $wp) { continue }
        try {
            New-Item -ItemType Directory -Force -Path $wp | Out-Null
            Write-Ok ('已补建会话工作区目录: ' + $wp)
            $created++
        } catch { Write-Warn2 ('无法创建工作区目录: ' + $wp) }
    }
    if ($paths.Count -gt 0) {
        Write-Info2 ('工作区目录: 共 ' + $paths.Count + ' 个，本次补建 ' + $created + ' 个。')
    }
}
function Resolve-DshInstall {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
        (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'DeepSeek Harness.exe'))) { return $c }
    }
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        try {
            $items = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'DeepSeek Harness*' })
            foreach ($it in $items) {
                if ($it.InstallLocation -and (Test-Path -LiteralPath (Join-Path $it.InstallLocation 'DeepSeek Harness.exe'))) {
                    return $it.InstallLocation
                }
            }
        } catch { }
    }
    return $null
}
function Get-ProfileDeps([string]$ProfileDir) {
    $pkg = Join-Path $ProfileDir 'package.json'
    if (-not (Test-Path -LiteralPath $pkg)) { return @() }
    try {
        $json = Get-Content -LiteralPath $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @()
        if ($json.dependencies) {
            foreach ($p in $json.dependencies.PSObject.Properties) { $names += $p.Name }
        }
        return $names
    } catch {
        return @()
    }
}

# ---------------------------------------------------------------- 日志
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $LogFile -or $LogFile.Trim().Length -eq 0) {
    $LogFile = Join-Path $env:TEMP ('dsh-fix-' + $stamp + '.log')
}
$script:transcriptOn = $false
try {
    Start-Transcript -Path $LogFile -Force | Out-Null
    $script:transcriptOn = $true
} catch { }
Write-Host '============================================================'
Write-Host ' DSH 恢复后修复工具（插件不可用 / 旧会话打不开）'
Write-Host '============================================================'
Write-Host ('日志文件: ' + $LogFile)

# ---------------------------------------------------------------- 参数解析
if (-not $DshHome -or $DshHome.Trim().Length -eq 0) {
    if ($env:DSH_HOME -and $env:DSH_HOME.Trim().Length -gt 0) { $DshHome = $env:DSH_HOME }
    else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}
$DshHome = [System.IO.Path]::GetFullPath($DshHome)

if (-not (Test-Path -LiteralPath $DshHome)) {
    Fail ('DSH 数据目录不存在: ' + $DshHome + '（请先安装并启动一次 DSH）')
}
$profilesDir = Join-Path $DshHome 'profiles'

# 定位迁移包
$backupCandidates = @()
if ($BackupDir -and $BackupDir.Trim().Length -gt 0) {
    $backupCandidates += [System.IO.Path]::GetFullPath($BackupDir)
}
# 脚本位于迁移包的 backup\scripts\ 时，默认使用其上一级 backup 目录
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($scriptDir) {
    $scriptParent = Split-Path -Parent $scriptDir
    if ($scriptParent) { $backupCandidates += $scriptParent }
}
$searchRoots = @(
    (Join-Path $env:USERPROFILE 'Desktop'),
    (Join-Path $env:USERPROFILE 'Downloads'),
    (Join-Path $env:USERPROFILE 'Documents'),
    'C:\', 'D:\', 'E:\', 'F:\'
)
foreach ($root in $searchRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
        $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'DSH-kit-*' -ErrorAction SilentlyContinue)
        foreach ($d in $dirs) { $backupCandidates += $d.FullName }
    } catch { }
}
$resolvedBackup = $null
foreach ($cand in $backupCandidates) {
    foreach ($sub in @($cand, (Join-Path $cand 'backup'))) {
        if ((Test-Path -LiteralPath (Join-Path $sub 'config')) -and (Test-Path -LiteralPath (Join-Path $sub 'manifest.json'))) {
            $resolvedBackup = [System.IO.Path]::GetFullPath($sub)
            break
        }
        if ((Test-Path -LiteralPath (Join-Path $sub 'config'))) {
            $resolvedBackup = [System.IO.Path]::GetFullPath($sub)
        }
    }
    if ($resolvedBackup) { break }
}
if (-not $resolvedBackup) {
    Fail '未找到迁移包的 backup 目录。请用 -BackupDir 指定（例如 -BackupDir "C:\path\to\DSH-kit-<version>\backup"）。'
}
Write-Host ('DSH 数据目录: ' + $DshHome)
Write-Host ('迁移包备份区: ' + $resolvedBackup)

$installDir = Resolve-DshInstall
if (-not $installDir) {
    Write-Warn2 '未找到 DeepSeek Harness 安装目录（不影响插件/会话修复，但不会自动重启）。'
    $installDir = ''
} else {
    Write-Host ('DSH 安装目录: ' + $installDir)
}

# ---------------------------------------------------------------- 诊断
Write-Step '诊断当前状态'
$profileNames = @()
if (Test-Path -LiteralPath $profilesDir) {
    $profileNames = @(Get-ChildItem -LiteralPath $profilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}
if ($profileNames.Count -eq 0) {
    Fail ('未找到任何 profile: ' + $profilesDir)
}
foreach ($name in $profileNames) {
    $pdir = Join-Path $profilesDir $name
    $nm = Join-Path $pdir 'node_modules'
    $deps = Get-ProfileDeps $pdir
    $missing = @()
    foreach ($d in $deps) {
        $pj = Join-Path $nm ($d + '\package.json')
        if (-not (Test-Path -LiteralPath $pj)) { $missing += $d }
    }
    Write-Host ('  profile {0}: 依赖 {1} 个, node_modules {2} 个目录, 缺失 {3} 个' -f $name, $deps.Count, (Get-TopDirCount $nm), $missing.Count)
    if ($missing.Count -gt 0) { Write-Host ('    缺失: ' + ($missing -join ', ')) }
}
$sessionsDir = Join-Path $DshHome 'sessions'
$logCount = 0
try { $logCount = @(Get-ChildItem -LiteralPath $sessionsDir -Recurse -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue).Count } catch { }
Write-Host ('  已有会话日志: ' + $logCount + ' 个')
$projcacheDir = Join-Path $DshHome 'storages\session_projcache\sessions'
if (Test-Path -LiteralPath $projcacheDir) {
    Write-Host ('  会话投影缓存: ' + @(Get-ChildItem -LiteralPath $projcacheDir -File -ErrorAction SilentlyContinue).Count + ' 个')
}

if ($DryRun) {
    Write-Step 'DryRun 结束（未修改任何文件）'
    Write-Host ('  将复制插件: ' + (Join-Path $resolvedBackup 'offline\profiles') + ' -> ' + $profilesDir + '\<profile>\node_modules')
    Write-Host '  复制后改写各 profile 的 .modules.yaml（pnpm storeDir/virtualStoreDir）为本机路径'
    Write-Host ('  将恢复会话: ' + (Join-Path $resolvedBackup 'user-data-optional\sessions') + ' -> ' + $sessionsDir)
    Write-Host '  将按会话缓存补建缺失的工作区目录（空目录，不含项目代码）'
    if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

# ---------------------------------------------------------------- 等待 DSH 退出
Write-Step '检查 DSH 进程'
$procs = @(Get-DshProcesses $installDir)
if ($SkipProcessCheck) {
    Write-Warn2 '已指定 -SkipProcessCheck，跳过进程检查（建议只在确认 DSH 已退出时使用）。'
} elseif ($procs.Count -gt 0) {
    Write-Warn2 ('检测到 DSH 正在运行（PID: ' + (($procs | ForEach-Object { $_.Id }) -join ', ') + '）。')
    Write-Host '  请现在完全退出 DSH：任务栏托盘右键 DSH 图标 -> 退出。'
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMin)
    while ($true) {
        Start-Sleep -Seconds 3
        $procs = @(Get-DshProcesses $installDir)
        if ($procs.Count -eq 0) { Write-Ok 'DSH 已退出'; break }
        if ((Get-Date) -gt $deadline) { Fail ('等待 DSH 退出超时（' + $WaitTimeoutMin + ' 分钟）。请完全退出 DSH 后重新运行本脚本。') }
        Write-Host '  ...等待 DSH 退出'
    }
} else {
    Write-Ok 'DSH 未在运行'
}

# ---------------------------------------------------------------- 修复插件
if (-not $SkipOffline) {
    Write-Step '复制离线插件（node_modules）'
    $offlineProfiles = Join-Path $resolvedBackup 'offline\profiles'
    if (-not (Test-Path -LiteralPath $offlineProfiles)) {
        Fail ('迁移包里没有离线插件目录: ' + $offlineProfiles + '（可能解压不完整，请重新解压迁移包）')
    }
    $copied = @()
    $srcProfiles = @(Get-ChildItem -LiteralPath $offlineProfiles -Directory -ErrorAction SilentlyContinue)
    foreach ($sp in $srcProfiles) {
        $srcNm = Join-Path $sp.FullName 'node_modules'
        $yaml = Join-Path $srcNm '.modules.yaml'
        if (-not (Test-Path -LiteralPath $yaml)) {
            Write-Warn2 ('离线数据不完整，跳过 profile: ' + $sp.Name)
            continue
        }
        $dstProfile = Join-Path $profilesDir $sp.Name
        if (-not (Test-Path -LiteralPath $dstProfile)) {
            Write-Warn2 ('目标机器上没有 profile ' + $sp.Name + '，跳过（若该 profile 需要插件，请先在 DSH 里启用它）')
            continue
        }
        $dstNm = Join-Path $dstProfile 'node_modules'
        Write-Host ('  复制 ' + $sp.Name + ' ...（文件较多，请稍候）')
        Copy-Tree $srcNm $dstNm | Out-Null
        Repair-ModulesYamlPaths $dstProfile | Out-Null
        $copied += $sp.Name
    }
    if ($copied.Count -eq 0) { Fail '没有任何 profile 的离线插件被复制。' }

    Write-Step '校验插件依赖'
    $allOk = $true
    foreach ($name in $copied) {
        $pdir = Join-Path $profilesDir $name
        $nm = Join-Path $pdir 'node_modules'
        if (-not (Test-Path -LiteralPath (Join-Path $nm '.modules.yaml'))) {
            Write-Err2 ($name + ': 缺少 node_modules\.modules.yaml')
            $allOk = $false
            continue
        }
        $deps = Get-ProfileDeps $pdir
        $missing = @()
        foreach ($d in $deps) {
            if (-not (Test-Path -LiteralPath (Join-Path $nm ($d + '\package.json')))) { $missing += $d }
        }
        if ($missing.Count -gt 0) {
            Write-Err2 ($name + ': 仍有依赖缺失 -> ' + ($missing -join ', '))
            $allOk = $false
        } else {
            Write-Ok ($name + ': ' + $deps.Count + ' 个依赖全部可解析（node_modules 顶层 ' + (Get-TopDirCount $nm) + ' 个目录）')
        }
    }
    if (-not $allOk) { Fail '插件复制后校验未通过。请确认迁移包解压完整、磁盘空间足够，然后重新运行。' }
}

# ---------------------------------------------------------------- 恢复会话与附件
if (-not $SkipUserData) {
    Write-Step '恢复会话日志与附件'
    $srcSessions = Join-Path $resolvedBackup 'user-data-optional\sessions'
    $srcAttach = Join-Path $resolvedBackup 'user-data-optional\attachments'
    if (Test-Path -LiteralPath $srcSessions) {
        Copy-Tree $srcSessions $sessionsDir | Out-Null
        $after = 0
        try { $after = @(Get-ChildItem -LiteralPath $sessionsDir -Recurse -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue).Count } catch { }
        Write-Ok ('会话日志已恢复，当前共 ' + $after + ' 个')
    } else {
        Write-Warn2 ('迁移包里没有 user-data-optional\sessions，跳过')
    }
    if (Test-Path -LiteralPath $srcAttach) {
        Copy-Tree $srcAttach (Join-Path $DshHome 'attachments') | Out-Null
        Write-Ok '附件已恢复'
    } else {
        Write-Warn2 ('迁移包里没有 user-data-optional\attachments，跳过')
    }
}

# 补建历史会话的工作区目录（空目录），否则会话列表可见但点开异常。
Write-Step '检查历史会话的工作区目录'
Add-MissingWorkspaceDirs $DshHome

# ---------------------------------------------------------------- 收尾
Write-Step '修复完成'
Write-Host ('  数据目录: ' + $DshHome)
Write-Host ('  日志文件: ' + $LogFile)
Write-Host ''
Write-Host '  下一步：重新打开 DSH，检查：'
Write-Host '    1) 设置 -> 插件：异常提示应消失；'
Write-Host '    2) 侧边栏旧会话应可以打开（若个别会话仍打不开，说明它不在迁移包里）。'
Write-Host '  若仍有问题，请把本日志文件发回。'

if ($RestartApp -and $installDir) {
    $exe = Join-Path $installDir 'DeepSeek Harness.exe'
    if (Test-Path -LiteralPath $exe) {
        Start-Process -FilePath $exe -WorkingDirectory $installDir
        Write-Host '  已尝试重新启动 DSH。'
    }
}

if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch { } }
exit 0
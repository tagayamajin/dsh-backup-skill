<#
.SYNOPSIS
    校验 DSH 备份的完整性（manifest 与实际文件是否一致）。

.DESCRIPTION
    - 检查备份目录结构（config、profiles、manifest.json、脚本、README）；
    - 逐个校验 manifest.files 中记录的 大小/SHA256；
    - 检查离线插件目录（offline\profiles\*\node_modules\.modules.yaml）；
    - 可选 -RunCliCheck：用临时 DSH_HOME 让 DSH CLI 加载备份中的 web profile，确认配置能解析。

    退出码：0 = 全部通过；1 = 存在错误。

.PARAMETER BackupDir
    备份根目录（包含 config\ 的目录）。默认为脚本所在目录的上一级。
.PARAMETER RunCliCheck
    额外调用 DSH CLI 校验配置（需要目标机已安装 DSH）。
.PARAMETER Full
    对离线 node_modules 也做文件数/大小统计（较慢，约几十秒）。
#>
[CmdletBinding()]
param(
    [string]$BackupDir,
    [switch]$RunCliCheck,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:errors = 0
$script:warnings = 0

function Write-Step {
    param([string]$Message)
    Write-Host ''
    Write-Host ('==> ' + $Message) -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host ('  [OK]   ' + $Message) -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    $script:warnings++
    Write-Host ('  [警告] ' + $Message) -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Message)
    $script:errors++
    Write-Host ('  [错误] ' + $Message) -ForegroundColor Red
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Resolve-DshInstall {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'DeepSeek Harness')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'DeepSeek Harness.exe'))) { return $c }
    }
    return $null
}

if (-not $BackupDir) {
    $parent = Split-Path -Parent $PSScriptRoot
    if (-not $parent) { $parent = (Get-Location).Path }
    $BackupDir = $parent
}
$BackupDir = [System.IO.Path]::GetFullPath($BackupDir)

Write-Step 'DSH 备份完整性校验'
Write-Host ('备份目录: ' + $BackupDir)

# ---------------------------------------------------------------------------
# 1. 结构检查
# ---------------------------------------------------------------------------
Write-Step '结构检查'
$required = @(
    'config',
    'config\profiles',
    'manifest.json',
    'scripts\backup-dsh.ps1',
    'scripts\restore-dsh.ps1',
    'scripts\verify-backup.ps1',
    'README.md'
)
foreach ($rel in $required) {
    $p = Join-Path $BackupDir $rel
    if (Test-Path -LiteralPath $p) { Write-Ok $rel } else { Write-Err ('缺失: ' + $rel) }
}

$profileDirs = @(Get-ChildItem -LiteralPath (Join-Path $BackupDir 'config\profiles') -Directory -ErrorAction SilentlyContinue)
if ($profileDirs.Count -gt 0) {
    foreach ($pd in $profileDirs) {
        $pkg = Join-Path $pd.FullName 'package.json'
        if (Test-Path -LiteralPath $pkg) { Write-Ok ('profile ' + $pd.Name + ' 含 package.json') } else { Write-Warn ('profile ' + $pd.Name + ' 缺少 package.json') }
    }
} else {
    Write-Err 'config\profiles 下没有 profile 目录'
}

# ---------------------------------------------------------------------------
# 2. manifest 与 SHA256
# ---------------------------------------------------------------------------
Write-Step 'manifest 与文件哈希校验'
$manifestPath = Join-Path $BackupDir 'manifest.json'
$manifest = $null
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Err 'manifest.json 不存在，无法校验哈希（请运行 scripts\backup-dsh.ps1 -Refresh 生成）'
} else {
    try {
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
        Write-Ok 'manifest.json 解析成功'
    } catch {
        Write-Err ('manifest.json 解析失败: ' + $_.Exception.Message)
        $manifest = $null
    }
}

$checked = 0
if ($manifest -and $manifest.files) {
    foreach ($entry in $manifest.files) {
        $rel = [string]$entry.path
        if (-not $rel) { continue }
        $actual = Join-Path $BackupDir $rel
        if (-not (Test-Path -LiteralPath $actual)) {
            Write-Err ('文件缺失: ' + $rel)
            continue
        }
        $checked++
        if ($entry.size -ne $null) {
            $actualSize = (Get-Item -LiteralPath $actual).Length
            if ([long]$entry.size -ne [long]$actualSize) {
                Write-Err ('大小不一致: ' + $rel + '（manifest ' + $entry.size + '，实际 ' + $actualSize + '）')
            }
        }
        if ($entry.sha256) {
            $actualHash = Get-Sha256 -Path $actual
            if ($actualHash -ne ([string]$entry.sha256).ToLowerInvariant()) {
                Write-Err ('SHA256 不一致: ' + $rel)
            }
        }
    }
    Write-Ok ('已校验 ' + $checked + ' 个文件')
} else {
    if ($manifest) { Write-Warn 'manifest.json 中没有 files 列表，跳过哈希校验' }
}

# ---------------------------------------------------------------------------
# 3. 离线插件目录
# ---------------------------------------------------------------------------
Write-Step '离线插件目录检查'
$offlineRoot = Join-Path $BackupDir 'offline\profiles'
if (-not (Test-Path -LiteralPath $offlineRoot)) {
    Write-Warn '没有离线插件目录（offline\profiles），目标机恢复时需要联网安装插件'
} else {
    foreach ($od in @(Get-ChildItem -LiteralPath $offlineRoot -Directory -ErrorAction SilentlyContinue)) {
        $nm = Join-Path $od.FullName 'node_modules'
        $marker = Join-Path $nm '.modules.yaml'
        if (Test-Path -LiteralPath $marker) {
            if ($Full) {
                $files = @(Get-ChildItem -LiteralPath $nm -Recurse -File -Force -ErrorAction SilentlyContinue)
                $sizeMb = 0
                if ($files.Count -gt 0) { $sizeMb = [math]::Round((($files | Measure-Object -Property Length -Sum).Sum / 1MB), 1) }
                Write-Ok ('profile ' + $od.Name + ' 离线 node_modules: ' + $files.Count + ' 文件 / ' + $sizeMb + 'MB')
            } else {
                Write-Ok ('profile ' + $od.Name + ' 离线 node_modules 存在（.modules.yaml 正常）')
            }
            # 源机绝对路径检查：.modules.yaml 的 storeDir/virtualStoreDir 记录的是备份时的绝对路径，
            # 恢复脚本会自动改写；这里提示非本机用户目录的路径，便于排查插件页 pnpm 报错。
            try {
                $yamlText = Get-Content -LiteralPath $marker -Raw -Encoding UTF8
                foreach ($m in @([regex]::Matches($yamlText, '"(?<k>storeDir|virtualStoreDir)"\s*:\s*"(?<v>[^"]+)"'))) {
                    $v = $m.Groups['v'].Value
                    if ($v -match '^[A-Za-z]:\\' -and $v -notlike ($env:USERPROFILE + '*')) {
                        Write-Warn ('profile ' + $od.Name + ' 的 .modules.yaml 记录源机绝对路径（' + $m.Groups['k'].Value + ' = ' + $v + '），恢复脚本会自动改写为本机路径')
                        break
                    }
                }
            } catch { }
            # 插件引用检查：cordis.patch.yml 里引用了、但离线 node_modules 中没有实体包的插件
            $patchFile = Join-Path (Join-Path $BackupDir ('config\profiles\' + $od.Name)) 'cordis.patch.yml'
            if (Test-Path -LiteralPath $patchFile) {
                $refs = New-Object System.Collections.Generic.List[string]
                foreach ($line in @(Get-Content -LiteralPath $patchFile -ErrorAction SilentlyContinue)) {
                    if ($line -match '^\s*-?\s*name\s*:\s*[''"]?([^\s''"#]+)[''"]?\s*(#.*)?$') {
                        $n = $Matches[1].Trim()
                        # 只检查第三方插件：跳过应用内置的 @deepseek-ai/*（随 app.asar 分发）、
                        # cordis:group 之类的内部引用、以及 GLM-5 等模型名（首字母大写）。
                        if ($n -match '^@deepseek-ai/' -or $n -match ':' -or $n -cmatch '^[A-Z]') { continue }
                        if ($n -and -not $refs.Contains($n)) { $refs.Add($n) }
                    }
                }
                $missRefs = @()
                foreach ($n in $refs) {
                    $refPkg = Join-Path (Join-Path $nm ($n -replace '/', '\')) 'package.json'
                    if (-not (Test-Path -LiteralPath $refPkg)) { $missRefs += $n }
                }
                if ($missRefs.Count -gt 0) {
                    Write-Warn ('profile ' + $od.Name + ' 的 cordis.patch.yml 引用了 node_modules 中不存在的插件: ' + (($missRefs | Sort-Object) -join ', ') + '（源机可能也未安装；恢复后插件页可能提示异常，需要时联网安装）')
                }
            }
            # 依赖完整性：按备份 config 中该 profile 的 package.json 逐个校验
            $pkgJson = Join-Path (Join-Path $BackupDir ('config\profiles\' + $od.Name)) 'package.json'
            if (Test-Path -LiteralPath $pkgJson) {
                try {
                    $pkg = Get-Content -LiteralPath $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    $deps = @()
                    if ($pkg.PSObject.Properties.Name -contains 'dependencies') { $deps = @($pkg.dependencies.PSObject.Properties.Name) }
                    $missing = New-Object System.Collections.Generic.List[string]
                    foreach ($dep in $deps) {
                        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $nm $dep) 'package.json'))) { $missing.Add($dep) }
                    }
                    if ($missing.Count -gt 0) {
                        Write-Err ('profile ' + $od.Name + ' 离线 node_modules 缺少依赖: ' + (($missing | Sort-Object) -join ', '))
                    } elseif ($deps.Count -gt 0) {
                        Write-Ok ('profile ' + $od.Name + ': ' + $deps.Count + ' 个依赖在离线 node_modules 中全部存在')
                    }
                } catch {
                    Write-Err ('profile ' + $od.Name + ' 的 package.json 解析失败: ' + $_.Exception.Message)
                }
            } else {
                Write-Warn ('profile ' + $od.Name + ' 缺少 config\profiles\' + $od.Name + '\package.json，跳过依赖完整性校验')
            }
        } else {
            Write-Err ('profile ' + $od.Name + ' 离线 node_modules 不完整（缺少 .modules.yaml）')
        }
    }
}

# ---------------------------------------------------------------------------
# 4. 用户数据（会话 / 附件）
# ---------------------------------------------------------------------------
Write-Step '用户数据检查'
$udRoot = Join-Path $BackupDir 'user-data-optional'
if (-not (Test-Path -LiteralPath $udRoot)) {
    Write-Warn '备份中没有 user-data-optional，恢复后不会有历史会话与附件'
} else {
    $sessRoot = Join-Path $udRoot 'sessions'
    if (Test-Path -LiteralPath $sessRoot) {
        $logs = @(Get-ChildItem -LiteralPath $sessRoot -Recurse -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue)
        if ($logs.Count -gt 0) {
            Write-Ok ('历史会话日志: ' + $logs.Count + ' 个')
        } else {
            Write-Warn 'user-data-optional\sessions 中没有会话日志文件'
        }
    } else {
        Write-Warn 'user-data-optional\sessions 不存在'
    }
    $attRoot = Join-Path $udRoot 'attachments'
    if (Test-Path -LiteralPath $attRoot) {
        $attCount = @(Get-ChildItem -LiteralPath $attRoot -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Ok ('附件文件: ' + $attCount + ' 个')
    } else {
        Write-Warn 'user-data-optional\attachments 不存在'
    }
}

# ---------------------------------------------------------------------------
# 5. 安全提示
# ---------------------------------------------------------------------------
Write-Step '安全提示'
$cred = Join-Path $BackupDir 'config\.credentials.yaml'
if (Test-Path -LiteralPath $cred) {
    Write-Warn '.credentials.yaml 包含明文凭据/API Key。请妥善保管本备份（加密、限制访问），不要外发。'
} else {
    Write-Ok '备份中不含 .credentials.yaml'
}

# ---------------------------------------------------------------------------
# 6. 可选 CLI 校验
# ---------------------------------------------------------------------------
if ($RunCliCheck) {
    Write-Step 'CLI 配置校验（web profile）'
    $installDir = Resolve-DshInstall
    if (-not $installDir) {
        Write-Err '未检测到已安装的 DSH，无法执行 CLI 校验'
    } else {
        $dshCmd = Join-Path $installDir 'resources\runtime\cli\bin\dsh.cmd'
        if (-not (Test-Path -LiteralPath $dshCmd)) {
            Write-Err ('未找到 CLI: ' + $dshCmd)
        } else {
            $tempHome = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-verify-' + [guid]::NewGuid().ToString('N'))
            try {
                $tempWeb = Join-Path $tempHome 'profiles\web'
                New-Item -ItemType Directory -Force -Path $tempWeb | Out-Null
                $srcWeb = Join-Path $BackupDir 'config\profiles\web'
                if (-not (Test-Path -LiteralPath $srcWeb)) {
                    Write-Err '备份中缺少 config\profiles\web'
                } else {
                    Copy-Item -Path (Join-Path $srcWeb '*') -Destination $tempWeb -Recurse -Force
                    $fixed = Join-Path $tempWeb 'cordis.patch.yml.fixed'
                    $patch = Join-Path $tempWeb 'cordis.patch.yml'
                    if (Test-Path -LiteralPath $fixed) {
                        Move-Item -LiteralPath $patch -Destination ($patch + '.broken') -Force -ErrorAction SilentlyContinue
                        Move-Item -LiteralPath $fixed -Destination $patch -Force
                    }
                    $oldHome = $env:DSH_HOME
                    $env:DSH_HOME = $tempHome
                    try {
                        $out = & $dshCmd --profile web --dump-config 2>&1
                        $code = $LASTEXITCODE
                    } finally {
                        $env:DSH_HOME = $oldHome
                    }
                    if ($code -eq 0) {
                        Write-Ok 'dsh --profile web --dump-config 成功（配置可正常加载）'
                    } else {
                        Write-Err ('dsh --profile web --dump-config 失败（exit ' + $code + '）')
                        if ($out) { Write-Host (($out | Select-Object -First 10) -join [Environment]::NewLine) -ForegroundColor DarkGray }
                    }
                }
            } finally {
                Remove-Item -LiteralPath $tempHome -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
Write-Step '校验结果'
Write-Host ('  错误: ' + $script:errors + ' 个；警告: ' + $script:warnings + ' 个')
if ($script:errors -gt 0) {
    Write-Host '  结果: 未通过，请根据上面的 [错误] 修复后重试。' -ForegroundColor Red
    exit 1
}
Write-Host '  结果: 通过。该备份可用于恢复。' -ForegroundColor Green
if ($script:warnings -gt 0) {
    Write-Host '  （存在警告，请人工确认是否需要在目标机处理。）' -ForegroundColor Yellow
}
exit 0
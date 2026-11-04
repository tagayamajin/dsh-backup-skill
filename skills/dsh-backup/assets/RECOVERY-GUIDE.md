# DSH 迁移包 · 恢复指南（0.2.1-rc.5）

> **这份文档是写给「新机上运行的 DSH 会话（AI agent）」看的操作说明。**
> 用户会把解压后的目录路径告诉你，请按本文顺序执行。整个过程不需要用户懂技术，但需要用户做两个动作：安装安装器、在托盘退出 DSH。

- 目标版本：**DeepSeek Harness 0.2.1-rc.5（Windows x64）**
- 包内自带同版本安装器：`installer\DeepSeek-Harness-0.2.1-rc.5-win-x64.exe`
- 请**不要**用官网最新版或其它版本替代，否则插件可能与宿主版本不匹配。

---

## 0. 包内容

```
DSH-kit-0.2.1-rc.5\
├─ README-FIRST.txt                  ← 给用户的 3 句话速览
├─ RECOVERY-GUIDE.md                 ← 本文件（恢复指南）
├─ kit-manifest.json                 ← 版本、哈希、备份统计
├─ installer\
│  ├─ DeepSeek-Harness-0.2.1-rc.5-win-x64.exe
│  └─ installer.sha256.txt
└─ backup\                           ← 备份根目录（restore 的 -BackupDir 指向这里）
   ├─ README.md                      ← 本指南副本（备份脚本会自动带上）
   ├─ manifest.json                  ← 备份文件清单 + 每个文件 sha256
   ├─ config\                        ← DSH 配置（profiles、技能、皮肤、设置等）
   │  ├─ profiles\desktop\           ← 桌面版插件清单 + cordis.patch.yml + pnpm-lock
   │  ├─ profiles\web\               ← web 终端 profile（含 .fixed 修正版 YAML）
   │  └─ skills\ skins\ storages\ task-board\ ...（用户配置与设置）
   ├─ offline\profiles\{desktop,web}\node_modules\   ← 离线插件依赖（约 1.7GB）
   ├─ user-data-optional\            ← 会话历史与附件（可选）
   │  ├─ sessions\
   │  └─ attachments\
   └─ scripts\
      ├─ start-restore.ps1           ← ★ agent 用这个（后台恢复 + 等用户退出 + 自动重启）
      ├─ restore-dsh.ps1             ← 真正的恢复脚本（也可手动运行）
      ├─ fix-restored-dsh.ps1        ← ★ 恢复后插件异常 / 会话打不开时的修复工具
      ├─ backup-dsh.ps1              ← 以后重新制作备份用
      └─ verify-backup.ps1           ← 校验备份完整性用
```

说明：本包**不包含** `.credentials.yaml`、API Key 等凭据（用户要求不带）。恢复后需要重新登录。

> **v3 包（2026-11-04 起）新增行为**：恢复时自动改写 `.modules.yaml` 的 pnpm 路径（适配新机，避免 `ERR_PNPM_UNEXPECTED_STORE`）；复制配置前后比对 DSH 进程，**恢复期间若 DSH 被启动会报错中止**（防止配置被运行中的 DSH 覆盖）；校验 `profiles\*\package.json` 与备份一致；按历史会话补建缺失的工作区目录；检查 `cordis.patch.yml` 引用的插件是否有实体包。

---

## 1. 解压（先决条件）

1. 把本压缩包解压到**本地磁盘**（例如 `C:\DSH-kit`），不要直接在压缩包里运行脚本。
   - 解压后约占用 **4.5–5 GB** 磁盘；请确保至少有 **6 GB** 空闲。
2. 路径尽量不含中文/空格（避免少数工具路径问题）；如果已经含中文也能用，本文示例用 `<kit>` 表示解压目录。

---

## 2. 安装 DSH（用户操作）

1. 双击 `installer\DeepSeek-Harness-0.2.1-rc.5-win-x64.exe`，按默认选项安装（默认安装到当前用户目录即可）。
2. 安装路径通常是 `%LOCALAPPDATA%\Programs\DeepSeek Harness`。
3. 安装完成后**可以先打开 DSH**（本指南就是要在新会话里执行），但进入恢复阶段后必须完全退出。
4. 版本自检（可选，agent 可执行）：

```powershell
(Get-Item "$env:LOCALAPPDATA\Programs\DeepSeek Harness\DeepSeek Harness.exe").VersionInfo.ProductVersion
```

应输出 `0.2.1-rc.5`。若版本不一致，请停止并告知用户重新获取正确版本的安装器。

---

## 3. 恢复前须知（关键）

- 恢复会把当前 `%USERPROFILE%\.dsh` 目录改名为 `.dsh.bak-<时间戳>`（**不会直接删除**），然后把包内 `backup\config\` 复制过去，并还原离线插件目录。
- **DSH 必须完全退出**才能恢复；否则脚本会拒绝执行（这是保护机制）。
- **恢复开始后不要让用户再点 DSH 图标**：脚本会在复制配置前后比对进程，一旦发现恢复期间有新 DSH 进程启动，会立即报错中止（运行中的 DSH 会改写 `cordis.patch.yml`、profile 的 `package.json`、插件状态，导致恢复结果不可靠）；此时让用户完全退出 DSH 后重跑即可。
- **你（agent）现在就运行在 DSH 里**：如果你直接运行 `restore-dsh.ps1`，会因「检测到 DSH 仍在运行」失败，而且 DSH 退出时你的会话也会中断。所以请用第 4 步的「后台恢复」：它先把恢复脚本作为独立进程拉起来，再等用户退出 DSH，退出后由该进程完成恢复并自动重启 DSH。
- 恢复过程中 DSH 会话会中断，这是**预期行为**，不是失败。

---

## 4. 一键恢复（推荐，agent 执行）

在 DSH 的内置终端里执行（把 `<kit>` 换成实际解压路径）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<kit>\backup\scripts\start-restore.ps1"
```

预期输出：

```
后台恢复进程已启动，PID=xxxx。
日志文件: C:\Users\<user>\AppData\Local\Temp\dsh-restore-*.log
请立刻退出 DSH（任务栏托盘 -> 退出）。
```

**然后立即通知用户：**

> 请在任务栏托盘右键 DSH 图标 → 选择「退出」，让 DSH 完全退出。恢复会自动开始，完成后会重新打开 DSH。

之后后台 `restore-dsh.ps1 -WaitForExit -RestartApp` 会自动执行：

1. 等待 DSH 进程全部退出（默认最长 120 分钟，每 3 秒检查一次）；
2. 旧 `.dsh` → `.dsh.bak-<yyyyMMdd-HHmmss>`；
3. 复制 `backup\config\` → `%USERPROFILE%\.dsh`；
4. 修复 web profile 的 `cordis.patch.yml`（用 `.fixed` 替换，原文件保留为 `.broken`）；
5. **竞态检查**：比对恢复开始前记录的 DSH 进程，若恢复期间有新 DSH 进程出现，立即 `exit 1` 并提示“恢复期间检测到 DSH 被启动，配置可能被覆盖，请完全退出后重跑”；
6. **一致性校验**：逐个 `profiles\*\package.json` 与备份中对应文件比 SHA256，不一致即报错退出（防止 bundles/dependencies 被运行中的 DSH 改写）；
7. 离线复制 `backup\offline\profiles\desktop\node_modules` 与 `...\web\node_modules`（插件及依赖，与备份机完全一致），并逐个校验依赖能否解析；任一缺失会报错退出（exit 1），**不会“假装成功”**；
8. **改写 pnpm 路径**：把 desktop/web 两个 `.modules.yaml` 的 `storeDir` 改为本机 `%LOCALAPPDATA%\pnpm\store\v11`、`virtualStoreDir` 改为本机 `<profile>\node_modules\.pnpm`（否则新机插件页会报 `ERR_PNPM_UNEXPECTED_STORE`）；
9. **插件引用检查**：扫描 `cordis.patch.yml` 引用的插件名，`node_modules` 中没有实体包的只打印警告（如皮肤插件源机本身没装），不阻断恢复；
10. 恢复 `user-data-optional\` 中的 `sessions\` 与 `attachments\`（默认执行，加 `-SkipUserData` 可关闭；恢复后会核对会话文件数量）；
11. **补建工作区目录**：按 `storages\session_projcache\sessions\*.json` 里记录的 `record.identity.cwd`，把已缺失的历史会话工作区补建成空目录（旧会话才能正常打开；**项目代码不在迁移包里，需另拷**）；
12. 用 `dsh --profile web --dump-config` 校验配置（exit 0 即通过）；
13. 重新启动 DSH 桌面版。

- 预计耗时 **2–10 分钟**（主要是复制约 1.7GB 插件文件 + 3.5 万个小文件，杀毒软件可能拖慢）。
- 日志：`%TEMP%\dsh-restore-<时间>.log`。若失败，先读日志最后 40 行再处理。

---

## 5. 手动兜底（后台进程被回收 / 用户想自己来）

极少数环境下，后台恢复进程可能随 DSH 退出被一起结束。此时：

1. 让用户**完全退出 DSH**（托盘 → 退出）。
2. 用户打开 PowerShell（开始菜单搜 `PowerShell`），运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<kit>\backup\scripts\restore-dsh.ps1" -BackupDir "<kit>\backup" -WaitForExit -RestartApp
```

- 只想先看计划、不修改文件：追加 `-DryRun`。
- 不想自动重启：把 `-RestartApp` 去掉。
- 恢复过程中不要关闭 PowerShell 窗口；建议暂时关闭杀毒软件对 `robocopy` / 大量小文件复制的拦截。

---

## 6. 恢复后校验清单（agent 执行）

```powershell
# 1) 配置目录存在
Get-ChildItem "$env:USERPROFILE\.dsh\profiles\desktop" | Select-Object Name, Length
# 应看到 package.json、cordis.patch.yml、pnpm-lock.yaml、node_modules 等

# 2) 桌面版插件数量（应为 13 个 dependencies）
(Get-Content "$env:USERPROFILE\.dsh\profiles\desktop\package.json" -Raw | ConvertFrom-Json).dependencies.PSObject.Properties.Count

# 3) web profile 配置可解析
& "$env:LOCALAPPDATA\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd" --profile web --dump-config
# exit 0，输出 > 80KB

# 4) 离线插件是否就位
Test-Path "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\.modules.yaml"
Test-Path "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\dsh-plugin"

# 5) 会话历史（如果有 user-data-optional）
(Get-ChildItem "$env:USERPROFILE\.dsh\sessions" -File -Recurse | Measure-Object).Count

# 6) .modules.yaml 应指向本机路径（不应再有 C:\Users\<备份机用户>\...）
Select-String -Path "$env:USERPROFILE\.dsh\profiles\desktop\node_modules\.modules.yaml" -Pattern 'storeDir|virtualStoreDir'
# 期望：storeDir = %LOCALAPPDATA%\pnpm\store\v11；virtualStoreDir = %USERPROFILE%\.dsh\profiles\desktop\node_modules\.pnpm

# 7) 历史会话工作区目录（恢复脚本已按 projcache 补建，Exists 应为 True）
Get-ChildItem "$env:USERPROFILE\.dsh\storages\session_projcache\sessions\*.json" -ErrorAction SilentlyContinue | ForEach-Object {
  $cwd = (Get-Content $_.FullName -Raw | ConvertFrom-Json).record.identity.cwd
  [pscustomobject]@{ Session = $_.BaseName; Cwd = $cwd; Exists = (Test-Path -LiteralPath $cwd) }
}
```

再让用户确认（图形界面）：

- 设置/插件页面能看到已安装插件（保存令牌、ego 浏览器、billion-context、pilot、whale widget 等）；
- 你安装的主题/皮肤插件仍在生效（取决于备份机是否安装）；
- 默认模型与备份机一致（若备份机用的是第三方 provider，需重新填写对应 API Key）；
- 左侧会话列表中出现历史会话（如包内带了 sessions），点开不报错（恢复脚本已补建缺失的工作区空目录；项目文件仍需另拷）。

---

## 7. 恢复后需要用户手动完成的（本包无凭据）

1. **重新登录** DSH 账号（设置 → 账号/登录，或按提示登录 DeepSeek）。
2. **重新配置环境变量或 API Key**：
   - 第三方 provider 的 API Key（例如备份机配置过的任意模型服务商；恢复后到 设置 → 模型 重新填写）；
   - 设置 → 模型/环境变量（或系统环境变量）中重新填写；
   - 其它插件 secret（browser session、approval gate 等）按需重新登录/授权。
3. 确认 `%USERPROFILE%\.dsh\.credentials.yaml` **不存在**（本包故意未包含）；首次使用新账号登录后会自行生成。
4. 恢复后首次启动可能提示插件需要初始化：按页面提示允许即可。

---

## 8. 排错 FAQ

| 现象 | 处理 |
| --- | --- |
| `未检测到已安装的 DSH 桌面版` | 先运行 `installer\` 里的安装器并装到默认路径；或检查注册表 `HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall` 中 `DeepSeek Harness*` 的 InstallLocation |
| `版本不一致` | 安装包必须是 0.2.1-rc.5；用第 2 步自检 `ProductVersion`。确认后再试；仍有问题才考虑 `-AllowVersionMismatch`（不推荐） |
| `检测到 DSH 仍在运行` | 托盘 → 退出；任务管理器结束 `DeepSeek Harness.exe`；或加 `-WaitForExit` 让脚本等待 |
| 旧会话出现在列表但打不开 | 先看工作区目录：v3 恢复脚本已按 projcache 自动补建空目录；若仍异常，DSH 完全退出后运行 `backup\scripts\fix-restored-dsh.ps1`（默认补回 `sessions\`、`attachments\` 并补建工作区目录）。项目代码不在迁移包里，需另拷 |
| `web profile 的 cordis.patch.yml 解析失败` | 恢复脚本会自动用 `.fixed` 覆盖；若手动恢复，请把 `config\profiles\web\cordis.patch.yml.fixed` 复制为 `cordis.patch.yml` |
| 插件没有加载 / 设置页空白 / 提示“包不可用” | **先在 DSH 完全退出后运行 `backup\scripts\fix-restored-dsh.ps1`**（加 `-RestartApp` 会自动重启），它会补齐离线 `node_modules` 并逐个校验依赖；不要点插件页上的在线“安装 / 修复”（会触发 pnpm 联网重装 + node-gyp 原生编译，极易失败）。仅当 fix 脚本仍报依赖缺失时，才考虑 `-Plugins Online` 联网重装（需 VS Build Tools + Python） |
| 插件页报 `ERR_PNPM_UNEXPECTED_STORE` / 安装·更新·卸载插件失败 | `.modules.yaml` 还指向备份机的 pnpm 路径。v3 恢复脚本会自动改写（`storeDir` → 本机 `%LOCALAPPDATA%\pnpm\store\v11`，`virtualStoreDir` → 本机 profile 的 `node_modules\.pnpm`）；若手动恢复或用了旧包，DSH 完全退出后运行 `backup\scripts\fix-restored-dsh.ps1` 修复 |
| 日志出现“恢复期间检测到 DSH 被启动” | 恢复中途 DSH 又被打开，配置可能被运行中的 DSH 覆盖：让用户完全退出 DSH（托盘 → 退出）后重跑恢复；已有 `.dsh.bak-*` 回滚点保留。|
| `dump-config` 失败 | 读日志与终端输出；确认 `%USERPROFILE%\.dsh\profiles\` 下文件完整，必要时用 `-DryRun` 复核计划 |
| 磁盘不足 | 至少预留 6GB；确认旧的 `.dsh.bak-*` 目录可在验证成功后删除 |
| 杀毒软件报毒/拦截 | 对 robocopy/小文件复制的误报，恢复期间暂时放行；安装器来自官方签名 |

---

## 9. 安全与分享

- 本包**不含** `.credentials.yaml`、API Key、登录 token；但**包含**用户会话记录、附件、插件配置、皮肤等隐私数据。
- **请勿公开分享、上传公共网盘或提交到代码仓库**；建议用加密压缩包或私有渠道传输。
- `installer\` 内的安装器为 DeepSeek 官方签名（Hangzhou DeepSeek Artificial Intelligence Co., Ltd.），运行前可校验 `installer.sha256.txt`。

---

## 附录 A. 恢复原理（为什么必须整目录复制）

- DSH 桌面版使用名为 `desktop` 的 profile，该 profile **由 Electron 应用独占管理**：CLI 对 `--profile desktop` 一律报 `error: profile "desktop" is managed exclusively by the Electron application`，因此无法用 `dsh plugin install` 在 desktop profile 上装插件，只能**原样复制整个 profile 目录**（含 `package.json`、`cordis.patch.yml`、`pnpm-lock.yaml` 与 `node_modules`）。
- 桌面版插件依赖为 pnpm `hoisted` 布局、全树无软链接（junction/symlink），所以 `node_modules` 可以直接跨机复制，实现**完全离线**还原。
- `cordis.yml` 恒为注释 + `[]`（不要编辑）；实际配置在 `cordis.patch.yml`（叠加层）。web profile 的原始 YAML 存在 `[]` 后接列表项的语法问题，包内已附修正版 `.fixed`。
- 备份与恢复脚本均为 PowerShell 5.1 兼容；脚本必须保留 UTF-8 BOM，否则中文会被按 GBK 解析。
- `node_modules\.modules.yaml` 记录的是**备份机**的 pnpm `storeDir`/`virtualStoreDir` 绝对路径（pnpm 用它判断 store 位置）。跨机不改写会在插件页报 `ERR_PNPM_UNEXPECTED_STORE`，v3 恢复脚本在复制后自动改写为本机路径。
- 恢复期间启动 DSH，运行中的进程会改写 `.dsh`（`cordis.patch.yml`、profile 的 `package.json`、插件状态等）。v3 用「记录恢复前进程 → 复制后比对 → 校验 `package.json` SHA256」三重保护，发现异常立即中止。
- 历史会话的工作区路径记录在 `storages\session_projcache\sessions\*.json` 的 `record.identity.cwd`；目录缺失时会话可见但点开异常，v3 自动补建空目录（项目文件需另拷）。

## 附录 B. 版本与哈希

| 项 | 值 |
| --- | --- |
| DSH 桌面版版本 | 0.2.1-rc.5 |
| 安装器文件名 | DeepSeek-Harness-0.2.1-rc.5-win-x64.exe |
| 安装器 SHA256 | 50A2FEDF234199E3319CDD6B89C4F0AEA601A19FE48259C6E3000883F0D2C6F0 |
| 签名主体 | CN=Hangzhou DeepSeek Artificial Intelligence Co., Ltd. |
| 平台 | Windows x64 |

备份文件清单与逐文件 sha256 见 `backup\manifest.json`；包级统计见 `kit-manifest.json`。
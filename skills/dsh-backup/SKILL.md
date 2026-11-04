---
name: dsh-backup
description: 备份本机 DeepSeek Harness（DSH）的插件与配置，生成一个带备份日期、可直接在新机恢复的“迁移包”zip（内置同版本安装包、去凭据备份、恢复指南与脚本），成功后自动删除旧备份。用户说“备份 DSH / 打包 DSH 配置 / 做 DSH 迁移包 / 备份插件 / 把 DSH 迁移到新电脑”时使用。
---

# DSH 备份与迁移包（dsh-backup）

把当前 DSH 桌面版变成可搬家的一整个 zip：**同版本安装包 + 去凭据的配置/插件备份 + 面向新会话 AI 的恢复指南**，并在打包成功后自动清理旧备份（默认只留最新一份）。备份文件名带备份日期时间，例如：

```
DSH-migration-kit-0.2.1-rc.5-20261104-203015.zip
DSH-migration-kit-0.2.1-rc.5-20261104-203015.zip.sha256
```

## 何时使用

- 用户要求备份 DSH 的插件/配置/皮肤/会话，或要求“做到新电脑能一键恢复”；
- 用户想把 DSH 迁移到另一台机器、或担心本机 DSH 宕机后无法还原；
- 用户要求定期备份、只保留最新的 N 份。

## 前置条件

- Windows，已安装 DSH 桌面版（本机 `DeepSeek Harness.exe` 可被发现）；
- 磁盘可用空间 ≥ 6 GB（迁移包约 2 GB，组装时临时目录再占约 1.8 GB）。

## 一键用法

本技能固定安装于 `%USERPROFILE%\.dsh\skills\dsh-backup`。在 DSH 会话中直接执行（PowerShell 5.1+）：

```powershell
$skill = Join-Path $env:USERPROFILE '.dsh\skills\dsh-backup'
powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $skill 'scripts\make-kit.ps1')
```

如果技能被复制到了别的目录，把 `$skill` 改成实际路径即可。

默认输出到 `桌面\DSH备份\zips`。常用示例：

```powershell
# 指定输出目录
... -File make-kit.ps1 -OutputDir "D:\DSH备份\zips"

# 保留最近 3 份（默认 1 份）
... -File make-kit.ps1 -Keep 3

# 不备份会话/附件（包更小、更快）
... -File make-kit.ps1 -SkipUserData

# 只组装不上包（验证配置，不产生大 zip，也跳过清理）
... -File make-kit.ps1 -NoZip

# 指定安装包（自动找不到或版本不一致时）
... -File make-kit.ps1 -Installer "D:\下载\DeepSeek-Harness-0.2.1-rc.5-win-x64.exe"
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-OutputDir` | `桌面\DSH备份\zips` | zip 输出目录 |
| `-WorkDir` | `%TEMP%\dsh-kit-build-<stamp>` | 临时组装目录，成功后删除 |
| `-Installer` | 自动查找 electron-updater 缓存 | DSH 安装包路径 |
| `-Keep` | `1` | 成功后保留的备份数量（含本次）；`<=0` 不清理 |
| `-SkipUserData` | 否 | 不备份会话记录与附件 |
| `-KeepStaging` | 否 | 保留临时组装目录，便于排查 |
| `-NoZip` | 否 | 只组装不打包；跳过旧备份清理 |
| `-AllowVersionMismatch` | 否 | 安装包版本与当前 DSH 不一致时仍继续 |
| `-NoPrune` | 否 | 不删除旧备份 |

## 执行流程（脚本自动完成）

1. 解析本机 DSH 安装目录与版本（`resources\runtime\primary-runtime\runtime.json` 的 `desktopVersion`）；
2. 找到**同版本**官方安装包（默认取 `%LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\installer.exe`，校验版本与数字签名）；
3. 临时目录组装 `DSH-kit-<版本>\`：
   - `installer\`：安装包 + `installer.sha256.txt`；
   - `backup\config\`：profiles（desktop 含 13 个插件依赖与 24 个 bundles、web）、皮肤、技能、storages、任务板等；
   - `backup\offline\`：两个 profile 的 `node_modules`（离线可还原插件，无需联网重装）；
   - `backup\user-data-optional\`：sessions + attachments（除非 `-SkipUserData`）；
   - `backup\scripts\`：`start-restore.ps1`、`restore-dsh.ps1`、`fix-restored-dsh.ps1`、`verify-backup.ps1`、`backup-dsh.ps1`；
   - `backup\manifest.json`：所有配置文件的 SHA256 清单（数量随插件/技能数变化，本机实测 80 个）；
   - `RECOVERY-GUIDE.md`、`README-FIRST.txt`、`kit-manifest.json`；
4. **强制去凭据**：备份时传 `-ExcludeCredentials`，打包前再次扫描，若发现 `.credentials.yaml` 立即中止；
5. 用系统 `tar.exe` 以 store 模式打包成单个 zip，写 `.sha256`，并用 `tar -t` 校验关键条目齐全；
6. **成功后自动删除旧备份**：只在 `-OutputDir` 里保留最新 `-Keep` 个 `DSH-migration-kit-*.zip`（连同其 `.sha256`），清理孤立的 `.sha256`，最后删除临时目录。

## 新机恢复（把这段告诉新会话 AI）

1. 解压到本地磁盘（例如 `C:\DSH-kit`，预留 6 GB）；
2. 双击 `DSH-kit-<版本>\installer\DeepSeek-Harness-<版本>-win-x64.exe` 安装同版本 DSH；
3. 打开 DSH，新建会话，发消息：「迁移包解压在 `C:\DSH-kit\DSH-kit-<版本>`，请按其中 `RECOVERY-GUIDE.md` 恢复」；
4. 该会话运行 `backup\scripts\start-restore.ps1`，按提示在任务栏托盘「退出 DSH」；
5. 脚本自动复制配置与离线插件：先校验 `profiles\*\package.json` 与备份逐字节一致（防止被运行中的 DSH 改写）、逐个校验依赖能否解析（缺依赖报错退出，不会“假成功”），再把 desktop/web 的 `.modules.yaml` 改写成**本机** pnpm 路径（`storeDir` → `%LOCALAPPDATA%\pnpm\store\v11`，否则插件页报 `ERR_PNPM_UNEXPECTED_STORE`），恢复历史会话与附件（默认执行，`-SkipUserData` 可关），按会话缓存补建缺失的工作区目录，`dump-config` 校验后重启 DSH；**恢复期间若 DSH 被再次启动会报错中止**（配置可能被运行中的 DSH 覆盖，退出后重跑即可）；
6. 重启后检查插件列表（应全部“已启用/已安装”）与历史会话；若插件异常/包不可用，**不要点在线“安装/修复”**，改为在 DSH 退出后运行 `backup\scripts\fix-restored-dsh.ps1 -RestartApp`（见 RECOVERY-GUIDE 排错表）；旧会话点开异常多为工作区目录缺失，恢复脚本已自动补建空目录，项目代码需另拷；
7. 重新登录 DSH 并重填 对应 provider 的 API Key（迁移包不含任何凭据/API Key）。

手动兜底：完全退出 DSH 后执行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<包目录>\backup\scripts\restore-dsh.ps1" -BackupDir "<包目录>\backup" -WaitForExit -RestartApp
```

## 校验备份

```powershell
# 迁移包完整性
Get-FileHash -Algorithm SHA256 "<zip 路径>"

# 用 tar 查看/校验条目
C:\Windows\System32\tar.exe -t -f "<zip 路径>"

# 校验备份目录自身
powershell -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\kit\verify-backup.ps1" -BackupDir "<解压出的 backup 目录>"
```

## 排错

| 现象 | 原因/处理 |
|---|---|
| `未检测到已安装的 DSH 桌面版` | DSH 未安装或安装到非常规位置；确认 `DeepSeek Harness.exe` 存在 |
| `找不到 DSH 安装包` | 用 `-Installer` 指定同版本安装器 |
| `安装包版本不一致` | 装同版本 DSH，或临时加 `-AllowVersionMismatch` |
| `备份中检测到凭据文件` | 备份脚本参数被改动；恢复默认 `-ExcludeCredentials` 流程 |
| 打包失败 `tar exit ...` | 检查输出目录磁盘空间，或加 `-NoZip` 保留组装目录后重试 |
| 删除旧备份失败 | 文件被占用/只读；脚本会告警并继续，不影响新备份 |
| 备份很慢 | 主要耗时在复制 node_modules（约 2-4 分钟）与打包（约 10-20 分钟） |
| 恢复后插件全部异常 / “包不可用” | 离线依赖没复制完整。DSH 完全退出后运行 `backup\scripts\fix-restored-dsh.ps1 -RestartApp` 补齐；不要点插件页在线“安装/修复” |
| 恢复后旧会话可见但打不开 | 多为工作区目录缺失：恢复脚本已按 projcache 自动补建空目录；仍异常则运行 `backup\scripts\fix-restored-dsh.ps1`（默认补回 sessions\、attachments\ 并补建工作区目录）。项目代码需另拷 |
| 插件页报 `ERR_PNPM_UNEXPECTED_STORE` | `.modules.yaml` 还指向备份机 pnpm 路径；v3 恢复已自动改写，旧包/手动恢复则退出 DSH 后跑 `backup\scripts\fix-restored-dsh.ps1` |
| 日志出现“恢复期间检测到 DSH 被启动” | 恢复中途 DSH 又被打开，配置可能被覆盖：完全退出 DSH（托盘 → 退出）后重跑恢复 |

## 注意

- **备份文件含未加密的用户会话与插件配置**，请存放在受控位置；
- 不要手工修改 `backup\config\profiles\desktop\*`（desktop profile 被 DSH CLI 独占管理，只能由应用自身写入）；`cordis.yml` 保持 `[]`，配置写在 `cordis.patch.yml`；
- web profile 原始 `cordis.patch.yml` 可能非法，备份中会生成 `.fixed`，恢复脚本会自动替换；
- 若要转存/分享迁移包，只分享 zip；zip 已确认不含 `.credentials.yaml`。
# dsh-backup — DeepSeek Harness backup & migration kit

A [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) **skill** that packages your
DSH plugins, profiles, plugin settings and chat data into a single, restorable migration kit — so a broken
machine (or a brand-new one) can be turned into a copy of the current setup.

Everything is plain PowerShell 5.1 + 7-Zip-free `tar`, no build step, no node dependency.

## What it does

`make-kit.ps1` produces one `.zip` containing:

| Path in zip | Content |
| --- | --- |
| `installer/` | the **same-version DSH desktop installer** (from the electron-updater cache), so the target machine runs an identical build |
| `backup/config/` | `%USERPROFILE%\.dsh` config: `profiles/{desktop,web}` (`package.json`, `cordis.patch.yml`, `pnpm-lock.yaml`), settings, plugin config, `dsh-claude-style`-style per-plugin data |
| `backup/offline/profiles/*/node_modules/` | the full offline plugin `node_modules` (hoisted, symlink-free), so plugins work without network |
| `backup/user-data-optional/` | chat history `sessions/` and `attachments/` (opt-out) |
| `backup/scripts/` | restore / verify / repair scripts |
| `manifest.json` + `kit-manifest.json` | per-file SHA-256 manifest and kit metadata (version, installer hash, signature check) |

`restore-dsh.ps1` on the new machine:

1. checks the target DSH is **not running**, and records running process IDs as a baseline;
2. renames the existing `%USERPROFILE%\.dsh` to `.dsh.bak-<timestamp>` (rollback point);
3. copies the backed-up config;
4. compares `profiles\*\package.json` with the backup (detects a DSH that was launched mid-restore and
   rewrote `dsh.profile.bundles`);
5. copies the offline `node_modules` and verifies **every declared dependency resolves** — no fake success;
6. **rewrites `.modules.yaml`** `storeDir` / `virtualStoreDir` to the local pnpm paths (otherwise pnpm fails
   with `ERR_PNPM_UNEXPECTED_STORE` on a different machine);
7. restores `sessions/` + `attachments/` by default, then recreates missing workspace folders recorded in the
   session project cache;
8. validates the config with `dsh --dump-config`, then optionally relaunches DSH.

If anything is still off after a restore, `fix-restored-dsh.ps1` trims the repair: it re-copies plugin
`node_modules`, rewrites `.modules.yaml`, restores sessions/attachments and recreates workspace folders.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (bundled) — no extra runtime;
- DSH **desktop** app installed (the skill drives the desktop profile);
- the same-version DSH installer for the target machine: found automatically in
  `%LOCALAPPDATA%\@deepseek-aidsh-desktop-updater\installer.exe` (written by DSH's own updater), otherwise
  pass `-Installer <path>`;
- **quit DSH completely before backup/restore** (including the tray icon). Plugins and config files are
  rewritten by a running app.

## Install (as a DSH skill)

Copy the `skills/dsh-backup` folder into your DSH skills directory:

```powershell
# from the repository root
Copy-Item -Recurse -Force .\skills\dsh-backup "$env:USERPROFILE\.dsh\skills\dsh-backup"
```

DSH discovers it on the next launch (`Settings → Skills` should list **dsh-backup**). You can also copy the
folder manually — a skill is just a directory with `SKILL.md`.

## Usage

**Backup (inside DSH chat).** Ask the assistant:

> 备份当前 DSH 配置，生成迁移包

The skill runs `scripts\make-kit.ps1`, which writes
`%USERPROFILE%\Desktop\DSH备份\zips\DSH-migration-kit-<dsh-version>-<yyyyMMdd-HHmmss>.zip` plus a `.sha256`
sidecar, and prunes older kits (keep the newest one by default).

**Backup (standalone PowerShell).**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\make-kit.ps1
# optional: -OutputDir <dir> -Installer <exe> -Keep 2 -SkipUserData
```

**Restore on another machine.**

1. Install the **same DSH version** from `installer/` in the zip; launch once, then quit (tray → Exit).
2. Extract the zip, then run:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\DSH-kit-<ver>\backup\scripts\start-restore.ps1
   ```

   (or `restore-dsh.ps1` directly; `-DryRun` previews the plan)
3. Do **not** launch DSH while the restore is running — the script aborts if it detects a new DSH process.
4. After the restore: check the plugin list and open an old conversation. Then log in again and re-enter any
   third-party provider API key (the kit deliberately contains **no credentials**).
5. If plugins show "package unavailable" or old sessions fail to open:
   `backup\scripts\fix-restored-dsh.ps1 -RestartApp`.

Full details: [`skills/dsh-backup/assets/RECOVERY-GUIDE.md`](skills/dsh-backup/assets/RECOVERY-GUIDE.md)
(Chinese) and [`skills/dsh-backup/SKILL.md`](skills/dsh-backup/SKILL.md).

## Safety & privacy notes

- The kit contains **your personal chat history and attachments** by default. Treat the zip as private; use
  `-SkipUserData` to exclude them.
- No credentials, API keys or `.credentials.yaml` are ever included.
- The restore script **moves** `%USERPROFILE%\.dsh` to `.dsh.bak-<timestamp>`; delete that folder after you
  have verified the restore.
- Project source code / workspaces are **not** included — only the config knows their paths; the restore
  script recreates missing workspace folders as empty directories.
- This is a community project, not an official DeepSeek tool. Test on a disposable machine first.

## Repository layout

```
skills/dsh-backup/
  SKILL.md                    # skill manifest (DSH auto-discovery)
  assets/
    README-FIRST.txt          # quick start for non-technical users
    RECOVERY-GUIDE.md         # full recovery guide (Chinese, 13 steps + troubleshooting)
  scripts/
    README.md                 # copy of RECOVERY-GUIDE (shipped inside the kit as backup/README.md)
    make-kit.ps1              # 1) build the migration kit zip
    kit/
      start-restore.ps1       # 2) wrapper: restore with prompts/wait
      restore-dsh.ps1         # 3) the actual restore
      fix-restored-dsh.ps1    # 4) post-restore repair helper
      backup-dsh.ps1          # backing up (called by make-kit)
      verify-backup.ps1       # verify a kit/backup folder
```

## License

MIT — see [LICENSE](LICENSE).

---

# dsh-backup — DeepSeek Harness 备份与迁移技能（中文）

把一个 DeepSeek Harness（DSH）的**插件、profile、插件配置和会话数据**打包成单个可恢复的迁移包，
让“本机 DSH 宕机/换机”之后能在一台全新机器上还原成基本一致的 DSH。

## 它能做什么

`make-kit.ps1` 生成一个 zip，内含：同版本 DSH 桌面安装包、`.dsh` 配置（profiles/插件清单/插件配置）、
**离线插件 node_modules**（与备份机完全一致）、会话与附件（默认包含，可用 `-SkipUserData` 排除）、恢复
脚本、逐文件 SHA-256 清单。

新机运行 `restore-dsh.ps1` 会：确认 DSH 已退出 → 把原 `.dsh` 改名为 `.dsh.bak-<时间>` 备份 → 复制配置 →
比对 `profiles\*\package.json`（防止恢复期间 DSH 被启动改写 bundles）→ 复制离线插件并**逐个校验依赖
能否解析** → **改写 `.modules.yaml` 的 pnpm 路径**（否则报 `ERR_PNPM_UNEXPECTED_STORE`）→ 默认恢复会话
与附件 → 按会话缓存补建工作区目录 → `--dump-config` 校验 → 可选重启 DSH。恢复后仍异常时用
`fix-restored-dsh.ps1` 兜底修复。

## 安装（作为 DSH 技能）

```powershell
Copy-Item -Recurse -Force .\skills\dsh-backup "$env:USERPROFILE\.dsh\skills\dsh-backup"
```

重启 DSH 后，在 设置 → 技能 中应能看到 **dsh-backup**（技能就是一个含 `SKILL.md` 的目录，可直接拷贝）。

## 使用

- **备份**：在 DSH 聊天里说“备份当前 DSH 配置，生成迁移包”，或直接运行
  `powershell -File .\scripts\make-kit.ps1`。产物在 `桌面\DSH备份\zips\`，含 `.sha256`。
- **恢复到新机**：①先装 zip 内同版本 DSH，启动一次后从托盘退出；②解压后运行
  `backup\scripts\start-restore.ps1`；③恢复过程中**不要**再启动 DSH（脚本检测到新进程会中止）；
  ④恢复后重新登录、重填第三方 provider 的 API Key（包内不含凭据）；⑤插件异常/旧会话打不开时运行
  `fix-restored-dsh.ps1 -RestartApp`。

## 注意

- 迁移包默认包含**个人会话记录与附件**，请当作隐私文件保管；不需要时用 `-SkipUserData`。
- 不含任何凭据/API Key。
- 恢复会**移动** `%USERPROFILE%\.dsh` 到 `.dsh.bak-<时间>`（回滚点），确认无误后可自行删除。
- **不含项目源代码**；脚本只会按历史会话补建缺失的工作区空目录。
- 非官方项目，使用前先在可丢弃的机器上验证。

完整步骤与排错见 `skills/dsh-backup/assets/RECOVERY-GUIDE.md`。

## 许可证

MIT。
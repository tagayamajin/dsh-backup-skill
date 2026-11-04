DSH 迁移包（DeepSeek Harness 0.2.1-rc.5，Windows x64）
=====================================================================

使用步骤（给用户）：

1. 把整个压缩包解压到本地磁盘，例如 C:\DSH-kit（解压后约 4.5 GB，请预留 6 GB）。
2. 双击 installer\DeepSeek-Harness-0.2.1-rc.5-win-x64.exe 安装 DSH（默认选项即可）。
3. 打开 DSH，新建一个会话，把下面的内容发给 AI：

      我的 DSH 迁移包解压在：C:\DSH-kit
      请阅读并按照 C:\DSH-kit\RECOVERY-GUIDE.md 恢复本机 DSH 配置。

4. AI 会让你在任务栏托盘右键 DSH 图标 -> 退出。退出后恢复会自动进行（约 2-10 分钟），
   完成后自动重新打开 DSH。恢复默认会包含历史会话与附件；若某步校验失败会明确报错。
   注意：恢复开始后不要再打开 DSH——脚本会检测到并中止恢复（运行中的 DSH 会改写配置）。
5. 本包（v3，2026-11-04 起）恢复时会自动：校验配置未被改写、改写 .modules.yaml 里的 pnpm
   路径（避免插件页报 ERR_PNPM_UNEXPECTED_STORE）、补建历史会话缺失的工作区空目录。
   项目代码不在包内，需要另外拷贝。
6. 恢复后需要重新登录 DSH 账号、重新填写 API Key（包内不含任何凭据）。
7. 若恢复后插件显示“异常/包不可用”或旧会话打不开：完全退出 DSH 后，运行
   backup\scripts\fix-restored-dsh.ps1 -RestartApp（详见 RECOVERY-GUIDE 第 8 节），
   不要在插件页点在线“安装/修复”。

备注：
- 包内 backup\README.md 与 RECOVERY-GUIDE.md 是同一份恢复指南（agent 可执行版本）。
- 恢复会把旧的 %USERPROFILE%\.dsh 改名备份为 .dsh.bak-<时间>，不会直接删除。
- 详细排错见 RECOVERY-GUIDE.md 第 8 节。
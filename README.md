# disk-cleanup：让 AI 帮你清理 Windows 磁盘

> **English:** An agent skill for Claude Code, Codex and other tools that read `SKILL.md`. It finds out what is filling a Windows drive and cleans it safely: WizTree scans with reusable snapshots, leftovers of uninstalled software, stray and fake installers, duplicates, regenerable project artifacts, crash dumps and browser caches. Findings are grouped into "safe to delete / needs your action / your call / don't touch", and nothing is deleted before you confirm. It also stops and reports suspicious files instead of deleting them as junk. The skill is written in English; this README is in Chinese.

**C 盘又满了？** 直接告诉 AI 助手"C 盘满了"，它会按这个 skill 的流程处理：
1. 用 WizTree 在几十秒内扫完整个盘；
2. 找出空间被谁占了、哪些能删、为什么能删；
3. 分组列给你看，你确认之后再动手。

这个 skill 是在一台真实电脑上反复清理时一点点总结出来的，每条规则都对应一次踩过的坑。在那台电脑上：
- C 盘剩余空间从 **2.3 GB 增加到 15 GB**；
- 顺带**发现并清除了一个伪装成系统文件的后门程序**。

---

## 能做什么

| 方面 | 具体内容 |
|---|---|
| **快速扫描** | 用 [WizTree](https://diskanalyzer.com) 直接读取 NTFS 文件索引，整个盘 10～25 秒。结果存成快照，后续提问直接查快照，不重复扫描 |
| **看变化** | 每个盘保留最近 3 份快照，告诉你"这段时间哪个文件夹涨了多少" |
| **软件残留** | 已卸载软件留下的文件夹、失效的开始菜单快捷方式和开机启动项、"应用"里卸载时报"找不到文件"的条目 |
| **安装包** | 不只看文件名，还会读 exe 的描述信息，识别安装程序的打包框架（NSIS、Inno Setup、WiX……），并核对对应软件是否已装、版本是新是旧。也能识别"旧版本的免安装副本" |
| **冒充的程序** | 文件名声称是某个软件，文件里的信息却对不上（比如名为 `SomeApp_2.4.4.exe`，描述却是"FormCeo"、没有签名），会单独标出来做安全检查 |
| **重复文件** | 大小相同的文件用哈希确认；压缩包和旁边已解压的文件夹**逐个文件**比对，不会因为总大小一样就判定重复 |
| **旧项目瘦身** | 识别 Unity、Unreal、Node、Python、Gradle、Visual Studio、Premiere 项目里能重新生成的部分（`node_modules`、`.venv`、`Library`、`Intermediate`……），只清理长期没动过的项目 |
| **系统角落** | 崩溃转储（包括系统服务目录里的）、浏览器各配置的缓存、回收站、WSL 虚拟磁盘、休眠文件、Windows 更新缓存 |
| **国内软件** | 微信新旧版数据迁移核对、网盘临时文件、厂商电脑管家日志、捆绑软件残留（见 `references/china-apps.md`） |
| **中文环境** | 报告分组和备忘标题统一用固定的中文名称；提示的设置路径和中文 Windows 界面一致；GBK 编码的 zip 文件名不会乱码 |

## 安全设计

- **先汇报，后删除**：结果分为"可以直接删 / 需要你操作 / 你来决定 / 不要动"四组，每一项都写明依据，你确认后才删。
- **个人资料默认进回收站**，判断错了还能找回。只有缓存和已经核实能重新生成的内容才直接删除。
- **删除脚本内置保护**，不会删 `C:\Windows`、用户目录根等关键位置。
- **判断"残留"要有证据**：核对注册表、开始菜单、正在运行的进程和最近写入时间，不只看名字。
- **可疑文件不当垃圾删**：遇到名字随机、冒充系统程序、管理员都打不开的文件，会停下清理，先只读核查（签名、哈希、计划任务、服务、网络连接、Defender 记录），单独报告。处理时先隔离，并保留证据。
- **查不到不等于没有**：读不到、没权限时，结果标为"无法确认"，不会当成"没有垃圾"或"已删除"。
- **报告里给个人信息打码**：文件名中的学号、身份证号、手机号、姓名都会打码。
- **本地备忘**会记住你的决定，比如哪些要保留、哪些已经处理过。换一个会话或换一个模型，也不会重复问你，更不会误删你说过要留的东西。

## 环境要求

- Windows 10/11，Windows PowerShell 5.1（系统自带）
- [WizTree](https://diskanalyzer.com)：个人使用免费，**商业用途需要购买授权**
- 扫描磁盘、删除系统目录时需要管理员权限，会弹出 UAC 提示
- 一个支持 Agent Skills（`SKILL.md`）的 AI 工具，例如 Claude Code、Codex

> **注意**：AI 工具如果在沙箱里运行命令（比如 Codex 的默认沙箱），命令会以另一个账户执行，看不到你的用户文件夹和注册表，结果不可信。请在沙箱外使用这个 skill。

## 安装

```powershell
git clone https://github.com/guxudong0917/disk-cleanup-skill.git "$env:USERPROFILE\.claude\skills\disk-cleanup"
```

| 工具 | 位置 |
|---|---|
| Claude Code | `%USERPROFILE%\.claude\skills\disk-cleanup\` |
| Codex 等读取通用目录的工具 | `%USERPROFILE%\.agents\skills\disk-cleanup\` |

多个工具同时用时，建议只保留一份，其他位置用目录链接指过去：

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.agents\skills\disk-cleanup" -Target "$env:USERPROFILE\.claude\skills\disk-cleanup"
```

## 本地配置（可选）

本机特有的设置放在 skill **外面**，不会进入仓库：`%USERPROFILE%\.disk-cleanup\config.json`，格式参考 `config.example.json`：

```json
{ "ScanDir": "D:\\WizTreeScans", "WizTreePath": "D:\\Tools\\WizTree\\WizTree64.exe", "Keep": 3, "ZipCodePages": [936] }
```

| 字段 | 作用 |
|---|---|
| `ScanDir` | 快照和备忘存放的位置。默认是第一个非系统盘下的 `WizTreeScans`，**不建议放在 C 盘** |
| `WizTreePath` | WizTree 不在默认安装位置时填写 |
| `Keep` | 每个盘、每种快照保留几份，默认 3 |
| `ZipCodePages` | 读 zip 内文件名时优先尝试的编码。国内常见的 zip 用 GBK（936）；系统开启了"使用 Unicode UTF-8 提供全球语言支持"时尤其需要。不填会自动尝试几种常见编码 |

运行后，`ScanDir` 里会出现：
- `C_folders_*.csv`、`D_files_*.csv` 等快照，每份文件快照约 150～200 MB；
- `disk-notes.md`：记录你的决定和本机情况，由 AI 维护，你也可以自己改。

## 怎么用

直接对 AI 说，比如：

- "C 盘满了，帮我看看能清理什么"
- "D 盘最近多了什么？"
- "这个文件夹能删吗：`D:\xxx`"
- "设置里卸载某个软件，提示找不到文件"
- "帮我看看 D 盘里很久没碰过的项目"

一次典型的报告长这样（节选）：

| 大小 | 路径 | 是什么 | 依据 |
|---|---|---|---|
| 23 MB | `Downloads\ChromeSetup.exe` 等 3 个 | 已安装软件的安装包 | Test-Installer：安装程序；Chrome 已装更高版本，其余两个已装同版本 |
| 2.29 GB | `Chrome\User Data\各配置\Cache` | 浏览器缓存 | 需要你操作：在每个 Chrome 配置里清除"缓存的图片和文件" |
| 264 MB | `Socket Programming.zip` | 课程压缩包 | 你来决定：其中 2 个文件和已解压出来的版本内容不同，压缩包里是原版 |

## 目录结构

```
disk-cleanup/
├── SKILL.md                         # 给 AI 的工作流程和规则（英文）
├── references/
│   ├── known-locations.md           # 常见缓存、不要动的位置、项目可重建部分、中英文设置路径
│   └── china-apps.md                # 国内常见软件的清理要点
└── scripts/                         # Windows PowerShell 5.1
    ├── Invoke-WizTreeScan.ps1       # 扫描并管理快照
    ├── Get-FolderSizes.ps1          # 查子文件夹大小（读快照）
    ├── Compare-Scans.ps1            # 对比两次快照
    ├── Find-Leftovers.ps1           # 软件残留、失效快捷方式和开机启动项、根目录零散文件
    ├── Find-OldFiles.ps1            # 安装包、压缩包、重复文件、崩溃转储、很久没动的大文件
    ├── Find-ProjectArtifacts.ps1    # 项目里可重建的部分
    ├── Test-Installer.ps1           # exe/msi 是安装包、程序本体、旧副本，还是冒充的程序
    ├── Find-BrokenUninstallEntries.ps1  # 失效的卸载条目
    ├── Remove-Paths.ps1             # 按清单删除（个人资料进回收站）
    ├── WizTreeCsv.ps1               # 公共函数：C# 加速读快照、读 zip、压缩包比对、剩余空间
    ├── InstallerRules.ps1           # 安装包命名规则
    └── Config.ps1                   # 读取本地配置
```

## 贡献者

- **XUDONG GU**（[@guxudong0917](https://github.com/guxudong0917)）：提出需求，在自己的电脑上实际使用和检验，决定每一项该不该删，审核规则
- **Claude**（Anthropic）：编写 skill 和脚本，从每次清理中总结规则，并用子代理和 Codex 做测试

欢迎提 Issue 和 PR，尤其是：
- 新的软件残留和缓存位置；
- 误判案例，也就是不该删却被列成可删的情况。

## 免责声明

删除文件有风险。这个 skill 会尽量核实，并在删除前征求你的确认，但最终决定在你。重要资料请先备份。

## 许可证

MIT，见 [LICENSE](LICENSE)。

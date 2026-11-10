# Apps common in mainland China

Software that is everywhere on Chinese Windows PCs but rarely covered by English cleanup guides. UI labels are kept in Chinese because that is what the user sees on screen.

## Chat apps: use their own storage management

| App | Data location | Cleanup |
|---|---|---|
| WeChat 4.x (微信 / Weixin) | path in `<U>\AppData\Roaming\Tencent\xwechat\config\*.ini`, usually `...\xwechat_files\<wxid>_xxxx\` on a non-system drive (`msg\file`, `msg\video`, `msg\attach` = files, videos, images; `db_storage` = the chat database - never touch) | 设置 → 存储空间: clean per chat; "历史版本冗余数据" one-click removes old 3.x data **including the old version's images, videos and files** |
| WeChat 3.x (old version) | `<U>\AppData\Roaming\Tencent\WeChat` (plugins, logs), `C:\ProgramData\Tencent\WeChat` (updater, patches), `<Documents>\WeChat Files\<wxid>\` (chat data: `FileStorage\{File,Video,MsgAttach}`, `Msg`) | When 3.x and 4.x coexist, the first two folders can go once 4.x is in use; the chat data needs the migration check below. Older PCs may have a second `WeChat Files` elsewhere (e.g. `D:\WeChat Files`) holding years of history the new version never received - treat as keep unless the user decides otherwise |
| QQ / QQ频道 / TIM | `<Documents>\Tencent Files\<qq>\`, `<U>\AppData\Roaming\Tencent\QQ\Temp\QQInstallSoftware` (downloaded installers) | QQ settings → 文件管理; installers in `QQInstallSoftware` are removable |

**WeChat migration check** before deleting old-version data: compare old `WeChat Files\<wxid>\FileStorage\{File,Video,MsgAttach}` with new `xwechat_files\<wxid>_xxxx\msg\{file,video,attach,migrate}` by "month folder + file name" or by file size (the new version renames videos). Count full images and thumbnails separately (new thumbnails end with `_t`), otherwise thousands of images look "missing". Copy anything that exists only in the old location to a safe folder first. Files that could not be linked to a message during migration land in `msg\migrate`.

Images/videos never opened on this PC exist only as thumbnails; the server keeps originals for a limited time ("图片已过期或被清理"). WeChat's "自动下载" settings decide what gets saved locally.

## Cloud drives

| App | Location | How |
|---|---|---|
| Baidu Netdisk (百度网盘) | `<Documents>\BaiduNetdiskTmp\*.tmp.node` (hundreds of ~3 MB modules unpacked at every start), `<install>\module\...\*.old*` (update backups) | quit Baidu Netdisk first (its `YunDetectService` locks files), then delete the `.tmp.node` files; or clear in its settings. The installer's ProductName is "BaiduYunguanjia" while the uninstall entry is "百度网盘" - match by install path |

## OEM PC managers and diagnostics

| App | Location | How |
|---|---|---|
| Huawei PC Manager (华为电脑管家) / Hiview | `C:\ProgramData\Comms` (logs and diagnostic databases, several GB, grows continuously) | clean inside 电脑管家; do not delete the folder |
| Huawei Share | `<drive>:\Huawei Share\Backup\...\Camera` | phone photo/video backups - personal data |
| HuaweiMoveData | `<drive>:\HuaweiMoveData\Users\<user>\` | created by Huawei's data-migration tool; user folders (Desktop, Documents...) are often redirected here - this is the user's data, not a leftover |

## Bundleware and their leftovers

- `C:\temporaryfiles\` with `2345*_silence.exe`: silent installers dropped by 2345 bundles - delete.
- `AlibabaProtect` (comes with 千牛 / 淘宝 tools): self-protecting service, its uninstaller often fails. As admin: `sc config AlibabaProtect start= disabled`, `sc delete AlibabaProtect`, end the process, delete `Program Files (x86)\AlibabaProtect`; locked DLLs after a reboot.
- Browser-extension "explorers"/"new tab" tools installed silently (e.g. TabX-style), "DeepSeek 本地部署助手"-style wrappers sharing the same files (`netul.dll`, `updatecfg.ini`, `Utils\`): uninstall; if the uninstaller is blocked, back up and delete the uninstall registry key, then delete the folder and its Start Menu entries.
- Game anti-cheat folders (`<U>\AppData\Roaming\ACLOS` for 无畏契约), game launcher leftovers (WeGame), 4399 game clients: remove once the game is gone.
- Download managers (迅雷 Thunder): `C:\ProgramData\Thunder Network\...\Download\*.exe` are auto-downloaded upgrade packages - removable.
- Driver tools (驱动精灵 / MyDrivers) leave `C:\MyDrivers`; Kingsoft leaves `C:\KRECYCLE`; Xunlei player leaves `C:\XmpCache`.
- Start Menu shortcuts with invisible characters in the name pointing into random-looking folders (e.g. `C:\<Logs>\<random>\...\*setup.exe`) - point them out to the user.

## Others

- Repacked "green" software archives (`*-ikuuu.zip`, `*_portable.7z`) often sit in a drive root next to an installed newer version or a replacement (e.g. an old proxy client replaced by another one that is running) - list under "your call" as "replaced by X".
- VPN clients for campus/company networks (e.g. Sangfor EasyConnect/aTrust) write crash dumps to `<U>\AppData\Roaming\Sangfor\...\Dump`.

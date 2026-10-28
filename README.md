# Neat Download Manager 简体中文汉化补丁 🇨🇳

[![Platform](https://img.shields.io/badge/platform-Windows-blue.svg)](https://www.neatdownloadmanager.com/)
[![Language](https://img.shields.io/badge/language-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-brightgreen.svg)](https://github.com/DaXiGua732/neatdownloadmanager-chinese)
[![License](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

为 [Neat Download Manager](https://www.neatdownloadmanager.com/) **1.4.24** 制作的简体中文汉化补丁（非官方）。NDM 没有语言包机制，补丁直接把 exe 里的 UTF-16LE 界面字符串原地覆写为中文，不改变 PE 结构、下载逻辑或数据库。

- **适用版本**：Neat Download Manager 1.4.24
- **词条**：241 条；另有 49 条 keep-English 清单
- **平台**：Windows；PowerShell 5.1 或 7
- **仓库不含**：`NeatDM.exe`、原版备份、个人下载截图

---

## 特点

- 主界面、分类树、工具栏、右键菜单、设置、属性、浏览器扩展、错误提示全部汉化。
- 覆盖 SSL / SOCKS / FTP / HLS / MKV / 分段 / 代理认证等表外错误句。
- 按版本和哈希保存原版备份；恢复只匹配当前版本，避免降级。
- 精确匹配，不做模糊替换；部分匹配会列出未匹配/超长/重叠项。
- 覆盖审计模式，可列出尚未分类的 UI 候选。
- 125% / 100% / 150% 三档 DPI 布局验收。
- Windows PowerShell 5.1 与 PowerShell 7 均可运行。

## 快速开始

1. 从[官网](https://www.neatdownloadmanager.com/)安装 **Neat Download Manager 1.4.24**。
2. 在系统托盘中右键 **NeatDM** 图标 → **退出**。
3. 下载或克隆本仓库，双击 `汉化工具.cmd`。
4. 输入 `1` 回车，重新启动 NeatDM。

想恢复英文：再次运行 `汉化工具.cmd`，输入 `2`。

> 首次应用会从已安装的原版 exe 生成 `originals/` 备份。仓库不附带原版 exe。

## 刻意保留英文

- 状态列 `Complete` / `Paused` / `Error`：数据库字段且被 SQL 比较。
- 日期月份：走 Windows 区域设置。
- About 的更新状态、`Contact` / `Website`：等长字符填充实测无法修复 NDM 的像素布局，按约定回退英文。
- 浏览器名、产品名、版本号、协议名、排序标记：专有名词/格式标记。
- 属性里的 `Bytes` 单位：嵌在复合格式串中，精确替换无法单独命中。

详见 [使用说明.md](使用说明.md)。

## 更新与回滚

NDM 自动更新会覆盖汉化。更新后重新运行 `汉化工具.cmd` → `1`：

- 版本不匹配会提示。
- 只应用精确匹配的条目；缺失项会列出。
- 原版备份按版本保存在 `originals/`，旧备份不会被覆盖。
- 如果修改了已经应用过的中文译文，请先 `restore` 再 `apply`。

退出码和备份细节见 [docs/exit-codes.md](docs/exit-codes.md)。

## 验证

```powershell
pwsh -NoProfile -File tests/run.ps1
```

检查覆盖完整补丁循环、字节差分、版本不匹配、拒绝降级、超长词条、PowerShell 5.1/7。当前结果：241/241 命中，0 未匹配、0 超长。

> 测试需要一份英文原版 exe 作为 fixture：首次 `apply` 生成的 `originals/`，或保留 `NeatDM.英文原版.exe.bak`。仓库不附带该文件。

## 目录

| 文件 | 说明 |
|---|---|
| `汉化工具.cmd` / `menu.ps1` | 双击菜单 |
| `ndm_patch.ps1` | 补丁引擎 |
| `translations.txt` | 词条表 |
| `keep_english.txt` | 明确不翻译的字符串 |
| `verify_diff.ps1` | 字节级差分 |
| `tests/run.ps1` | 隔离检查脚本 |
| `docs/` | 覆盖分类、布局清单、退出码、ADR |
| `GLOSSARY.md` | 项目术语 |

## 说明

- 本项目是非官方汉化，与 Neat Download Manager 作者无关。
- 补丁只修改界面显示文案，不涉及下载逻辑、协议解析或文件校验。
- 原版 exe 未签名；修改后的 exe 可能被杀毒软件误报。
- 仓库不附带 NDM 原版 exe 或备份；请从官网安装。

## License

[MIT](LICENSE)

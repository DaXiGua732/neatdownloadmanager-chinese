# 覆盖分类

## 规则

- 翻译 UI 标签和用户可见错误。
- 保持英文：日志、SQL、扩展协议内部、内部标识、区域名、日期格式、协议名、产品名和专有名词。
- 状态列 `Complete` / `Paused` / `Error` 和日期月份保持英文，原因见用户指南。
- About 的四条更新状态、`Contact` / `Website` 保持英文：ticket 04 的等长填充原型失败，按约定回退。

## 审计命令

```powershell
pwsh -NoProfile -File ndm_patch.ps1 -Mode audit `
  -Exe NeatDM.英文原版.exe.bak `
  -Table translations.txt `
  -KeepFile keep_english.txt
```

审计只读，不修改 exe。它扫描 `.rdata` 字符串字面量，减去词条表和 keep-English 清单，再输出疑似 UI 的候选（地址 + 文本）。

## 当前结果

- 词条表：241 条。
- keep-English：49 条。
- UI 候选：0。
- 未分类字面量：6173 条；均为非 UI / 内部字符串，不需要翻译。

## keep-English 的类别

- 日期格式和区域名。
- SSPI 提供程序名、窗口类名、内部能力标识、字符集常量。
- 动态拼接片段（`Proxy `、` Auth , `、`Although other Connections have passed `、` Http-Redirect ).`）。
- 浏览器扩展协议内部（`Invalid Opcode Received.` 等）。
- 协议名、命令行开关、产品名、版本字符串、浏览器专有名词。
- About / Contact / Website 的英文回退项，以及排序标记。

## 备注

- 新增的错误译文保留了源字符串的首尾空格，供动态拼接使用；没有给动态消息补空格。
- `Segment` 统一为“分段”，临时目录文案改为“临时分段文件”。
- 两条偏移词条：`Download Properties`（0x16640C）和 `Download`（0x1670C0），用于嵌在更长字面量里的窗口标题/按钮。

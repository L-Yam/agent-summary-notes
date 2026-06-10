# 流程 - Codex 轻自动沉淀

## 适用场景

我每天和 Codex 聊很多，希望系统自动把高价值内容先捞出来，写进 Obsidian 每日页，但不直接污染正式知识页。

## 当前实现

- 数据源：`C:\Users\33055\.codex\sessions`
- 索引：`C:\Users\33055\.codex\session_index.jsonl`
- 输出位置：`E:\Agent总结笔记\00-收件箱\每日记录`
- 脚本：`E:\Agent总结笔记\tools\codex_light_auto.py`
- 启动器：`E:\Agent总结笔记\tools\Update-CodexDailyCandidates.ps1`

## 它会自动做什么

1. 扫描指定日期的 Codex 会话 JSONL
2. 提取用户消息和该轮最终结论
3. 按规则筛掉寒暄、过短内容和低价值片段
4. 自动分类为：
   - 配置候选
   - 问题候选
   - 工作流候选
   - 专题候选
5. 把结果写入当天每日页的“自动候选内容”区块

## 它不会自动做什么

- 不会直接改写正式知识页
- 不会自动判断所有内容都一定正确
- 不会替代人工筛选长期价值

## 如何运行

```powershell
powershell -ExecutionPolicy Bypass -File "E:\Agent总结笔记\tools\Update-CodexDailyCandidates.ps1"
```

指定日期：

```powershell
powershell -ExecutionPolicy Bypass -File "E:\Agent总结笔记\tools\Update-CodexDailyCandidates.ps1" -Date 2026-06-10
```

只预览不写入：

```powershell
powershell -ExecutionPolicy Bypass -File "E:\Agent总结笔记\tools\Update-CodexDailyCandidates.ps1" -DryRun
```

## 推荐使用方式

- 白天先让脚本自动写入候选内容
- 晚上快速浏览每日页
- 只把真正稳定的内容升级到正式知识页

## 后续可继续增强

- 增加更细的分类规则
- 增加正式页草稿输出
- 再接一个 Windows 定时任务，实现每天自动跑

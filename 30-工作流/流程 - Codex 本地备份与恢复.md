# 流程 - Codex 本地备份与恢复

## 适用场景

- 重装 Codex 前备份
- 担心本地对话、记忆或配置丢失
- 只想恢复旧对话，不想覆盖当前新配置

## 完整备份流程

1. 退出 Codex，避免 SQLite 和日志文件正在写入
2. 备份整个 `C:\Users\33055\.codex`
3. 备份时给目录加时间戳，便于区分版本
4. 备份后重点确认 `sessions`、`archived_sessions`、`session_index.jsonl`、`state_*.sqlite*`、`memories_*.sqlite*` 是否存在

## 只恢复旧对话的建议流程

1. 先备份当前 `.codex`
2. 只恢复会话与记忆相关文件
3. 不覆盖 `auth.json`、`config.toml`、`skills`、`plugins`
4. 如果当前安装后已经产生新对话，恢复前先考虑索引合并，避免覆盖掉新入口

## 关键路径

- `C:\Users\33055\.codex`
- `sessions`
- `archived_sessions`
- `session_index.jsonl`
- `state_*.sqlite*`
- `memories_*.sqlite*`

## 推荐原则

- 先完整备份，再做恢复
- 要区分“恢复对话”与“恢复整个环境”
- 覆盖类操作前一定先保留当前状态

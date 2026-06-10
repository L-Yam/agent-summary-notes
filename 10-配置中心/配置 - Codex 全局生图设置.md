# 配置 - Codex 全局生图设置

## 目的

让之后的生图或改图请求默认走 KG API 网关，并优先使用 `gpt-image-2`。

## 当前配置

- 网关地址：`https://api.kgapi.net/v1`
- 默认生图模型：`gpt-image-2`
- 生效范围：全局默认

## 落地位置

- `C:\Users\33055\.codex\config.toml`
- `C:\Users\33055\.codex\AGENTS.md`

## 关键说明

- 全局 `config.toml` 中已将 `base_url` 固定为 `https://api.kgapi.net/v1`
- 全局 `AGENTS.md` 中已写入中文规则：生图请求默认走 KG API，并优先使用 `gpt-image-2`
- 该网关的生图接口可能返回异步任务，需要继续轮询 `poll_url`

## 维护建议

- 如果以后更换网关，优先同时更新 `config.toml` 和 `AGENTS.md`
- 如果只是临时换模型，直接在当次对话中明确说明即可，不必改全局

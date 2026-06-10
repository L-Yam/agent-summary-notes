#!/usr/bin/env python3
"""Lightweight Codex -> Obsidian candidate note sync."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable


TRIVIAL_USER_MESSAGES = {
    "继续",
    "可以",
    "同意",
    "好的",
    "好",
    "嗯",
    "收到",
    "谢谢",
    "你好",
    "hi",
    "hello",
}

CATEGORY_KEYWORDS = {
    "配置候选": {
        "配置": 3,
        "config": 3,
        "base_url": 4,
        "api key": 4,
        "网关": 3,
        "模型": 2,
        "默认": 2,
        "global": 2,
        "auth": 3,
        "provider": 3,
        "环境变量": 3,
        "ag e nts.md": 2,
    },
    "问题候选": {
        "报错": 4,
        "错误": 4,
        "失败": 3,
        "无法": 3,
        "排查": 3,
        "修复": 4,
        "恢复": 3,
        "403": 4,
        "404": 4,
        "202": 3,
        "超时": 3,
        "problem": 2,
        "bug": 3,
    },
    "工作流候选": {
        "流程": 4,
        "工作流": 4,
        "步骤": 3,
        "自动": 3,
        "联动": 3,
        "搭建": 2,
        "脚本": 3,
        "模板": 2,
        "daily": 2,
        "obsidian": 3,
        "codex": 2,
    },
    "专题候选": {
        "专题": 4,
        "研究": 3,
        "知识库": 4,
        "论文": 3,
        "方案": 2,
        "对比": 2,
        "思路": 2,
        "karpathy": 4,
        "wiki": 3,
    },
}

AUTO_SECTION_START = "<!-- codex-auto:start -->"
AUTO_SECTION_END = "<!-- codex-auto:end -->"


@dataclass
class Exchange:
    session_id: str
    thread_name: str
    turn_id: str
    timestamp_utc: str
    local_time: str
    user_text: str
    agent_text: str
    score: int
    category: str
    title: str
    summary: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write Codex candidate notes into Obsidian daily notes.")
    parser.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"), help="Target local date, YYYY-MM-DD.")
    parser.add_argument(
        "--sessions-root",
        default=r"C:\Users\33055\.codex\sessions",
        help="Root directory of Codex session JSONL files.",
    )
    parser.add_argument(
        "--session-index",
        default=r"C:\Users\33055\.codex\session_index.jsonl",
        help="Path to Codex session index JSONL.",
    )
    parser.add_argument(
        "--vault-root",
        default=r"E:\Agent总结笔记",
        help="Root directory of the Obsidian vault.",
    )
    parser.add_argument("--min-score", type=int, default=6, help="Minimum score required to keep a candidate.")
    parser.add_argument("--max-items", type=int, default=12, help="Maximum number of candidate items to emit.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the generated section instead of writing the note.",
    )
    return parser.parse_args()


def load_thread_names(index_path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not index_path.exists():
        return result
    with index_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            session_id = payload.get("id")
            if session_id:
                result[session_id] = payload.get("thread_name") or "未命名线程"
    return result


def iter_session_files(sessions_root: Path, target_date: str) -> Iterable[Path]:
    try:
        dt = datetime.strptime(target_date, "%Y-%m-%d")
    except ValueError as exc:
        raise SystemExit(f"Invalid --date: {target_date}") from exc
    dated_dir = sessions_root / f"{dt.year:04d}" / f"{dt.month:02d}" / f"{dt.day:02d}"
    if not dated_dir.exists():
        return []
    return sorted(dated_dir.glob("*.jsonl"))


def sanitize_text(text: str) -> str:
    text = re.sub(r"sk-[A-Za-z0-9_-]{8,}", "sk-***", text)
    text = re.sub(r"Bearer\s+[A-Za-z0-9._-]{16,}", "Bearer ***", text, flags=re.IGNORECASE)
    text = re.sub(r"https?://[^\s)]+", lambda m: m.group(0)[:80], text)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = text.replace("\r", "")
    return text.strip()


def clean_for_display(text: str) -> str:
    text = sanitize_text(text)
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


def is_trivial_user_message(text: str) -> bool:
    normalized = clean_for_display(text).lower().strip("。.!?？！，, ")
    if not normalized:
        return True
    if normalized in TRIVIAL_USER_MESSAGES:
        return True
    if len(normalized) <= 2:
        return True
    if re.fullmatch(r"[\d.\s:-]+", normalized):
        return True
    return False


def choose_title(user_text: str, agent_text: str, thread_name: str) -> str:
    for raw_line in user_text.splitlines():
        line = clean_for_display(raw_line).strip("-*1234567890. ")
        line = re.sub(r"https?://\S+", "", line).strip(" ：:，,")
        if not line or len(line) < 4:
            continue
        if line.startswith("# Files mentioned by the user"):
            continue
        if line.lower().startswith("sk-"):
            continue
        if re.match(r"^[A-Z]:\\", line):
            continue
        if re.fullmatch(r"[A-Za-z0-9._-]+", line):
            continue
        if len(line) > 36:
            line = line[:36].rstrip() + "..."
        return line
    summary = extract_summary(agent_text, limit=36)
    if summary:
        return summary
    thread_name = clean_for_display(thread_name)
    return thread_name[:36] if thread_name else "待整理候选内容"


def extract_summary(text: str, limit: int = 110) -> str:
    cleaned = sanitize_text(text)
    paragraphs = [clean_for_display(part) for part in re.split(r"\n\s*\n", cleaned) if part.strip()]
    preferred = ""
    for paragraph in paragraphs:
        if len(paragraph) >= 20 and "如果你愿意" not in paragraph:
            preferred = paragraph
            break
    if not preferred:
        preferred = clean_for_display(cleaned)
    if len(preferred) > limit:
        preferred = preferred[:limit].rstrip() + "..."
    return preferred


def classify_exchange(text: str) -> tuple[str, int]:
    lowered = text.lower()
    best_category = "工作流候选"
    best_score = 0
    for category, keywords in CATEGORY_KEYWORDS.items():
        score = 0
        for keyword, weight in keywords.items():
            if keyword in lowered:
                score += weight
        if score > best_score:
            best_category = category
            best_score = score
    return best_category, best_score


def score_exchange(user_text: str, agent_text: str) -> int:
    combined = clean_for_display(user_text + "\n" + agent_text).lower()
    score = 0
    length = len(clean_for_display(agent_text))
    if length >= 80:
        score += 3
    if length >= 180:
        score += 2
    if "```" in agent_text or "`" in agent_text:
        score += 2
    if re.search(r"[A-Z]:\\", agent_text):
        score += 2
    if any(token in combined for token in ("配置", "修复", "流程", "安装", "问题", "知识库", "网关", "模型", "脚本", "obsidian", "codex")):
        score += 3
    if re.search(r"\b(403|404|202|500)\b", combined):
        score += 2
    if is_trivial_user_message(user_text):
        score -= 3
    if len(clean_for_display(user_text)) <= 6:
        score -= 1
    return score


def parse_iso_timestamp(value: str) -> datetime:
    if value.endswith("Z"):
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    dt = datetime.fromisoformat(value)
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


def parse_session_file(path: Path, thread_names: dict[str, str], min_score: int) -> list[Exchange]:
    session_id = ""
    thread_name = "未命名线程"
    session_topic = ""
    current_turn_id = ""
    pending: dict[str, dict[str, str]] = {}
    exchanges: list[Exchange] = []

    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            record_type = record.get("type")
            if record_type == "session_meta":
                session_id = record.get("payload", {}).get("id", "")
                thread_name = thread_names.get(session_id) or thread_name
                continue
            if record_type == "turn_context":
                current_turn_id = record.get("payload", {}).get("turn_id", "")
                if current_turn_id:
                    pending.setdefault(current_turn_id, {})
                continue
            if record_type != "event_msg":
                continue

            payload = record.get("payload", {})
            event_type = payload.get("type")
            if event_type == "user_message":
                if current_turn_id:
                    entry = pending.setdefault(current_turn_id, {})
                    entry["user_text"] = payload.get("message", "")
                    entry["user_ts"] = record.get("timestamp", "")
                    if not session_topic and not is_trivial_user_message(entry["user_text"]):
                        session_topic = choose_title(entry["user_text"], "", "")
            elif event_type == "task_complete":
                turn_id = payload.get("turn_id", "")
                if not turn_id:
                    continue
                entry = pending.get(turn_id, {})
                user_text = entry.get("user_text", "")
                agent_text = payload.get("last_agent_message") or ""
                if not user_text or not agent_text:
                    continue
                total_score = score_exchange(user_text, agent_text)
                category, category_score = classify_exchange(user_text + "\n" + agent_text)
                total_score += category_score
                if total_score < min_score:
                    continue
                timestamp = payload.get("completed_at")
                event_ts = record.get("timestamp", "")
                local_time = ""
                if event_ts:
                    local_time = parse_iso_timestamp(event_ts).astimezone().strftime("%H:%M")
                title = choose_title(user_text, agent_text, thread_name)
                display_thread_name = thread_name
                if display_thread_name == "未命名线程" and session_topic:
                    display_thread_name = session_topic
                summary = extract_summary(agent_text)
                exchanges.append(
                    Exchange(
                        session_id=session_id or path.stem,
                        thread_name=display_thread_name,
                        turn_id=turn_id,
                        timestamp_utc=event_ts,
                        local_time=local_time or "00:00",
                        user_text=sanitize_text(user_text),
                        agent_text=sanitize_text(agent_text),
                        score=total_score,
                        category=category,
                        title=title,
                        summary=summary,
                    )
                )
    return exchanges


def ensure_daily_note(note_path: Path, target_date: str) -> None:
    if note_path.exists():
        return
    content = "\n".join(
        [
            f"# {target_date} - 待整理",
            "",
            "## 今天值得沉淀的内容",
            "",
            "- ",
            "",
            "## 待整理到配置中心",
            "",
            "- ",
            "",
            "## 待整理到问题修复",
            "",
            "- ",
            "",
            "## 待整理到工作流",
            "",
            "- ",
            "",
            "## 待整理到专题研究",
            "",
            "- ",
            "",
        ]
    )
    note_path.parent.mkdir(parents=True, exist_ok=True)
    note_path.write_text(content, encoding="utf-8")


def build_auto_section(exchanges: list[Exchange], target_date: str) -> str:
    generated_at = datetime.now().strftime("%Y-%m-%d %H:%M")
    lines = [AUTO_SECTION_START, "## 自动候选内容", "", f"_更新时间：{generated_at}_", "_这部分会在脚本重新运行时覆盖；手动补充请写在其他章节。_", ""]
    if not exchanges:
        lines.extend(["- 今天没有识别到达到阈值的候选内容。", "", AUTO_SECTION_END])
        return "\n".join(lines)

    grouped: dict[str, list[Exchange]] = {key: [] for key in CATEGORY_KEYWORDS}
    for exchange in exchanges:
        grouped.setdefault(exchange.category, []).append(exchange)

    for category in ("配置候选", "问题候选", "工作流候选", "专题候选"):
        items = grouped.get(category) or []
        if not items:
            continue
        lines.append(f"### {category}")
        lines.append("")
        for item in items:
            lines.append(
                f"- `{item.local_time}` {item.title}：{item.summary} 线程：{clean_for_display(item.thread_name)}。"
            )
        lines.append("")
    lines.append(AUTO_SECTION_END)
    return "\n".join(lines)


def upsert_auto_section(note_path: Path, auto_section: str) -> None:
    content = note_path.read_text(encoding="utf-8")
    pattern = re.compile(
        rf"{re.escape(AUTO_SECTION_START)}.*?{re.escape(AUTO_SECTION_END)}",
        flags=re.DOTALL,
    )
    if pattern.search(content):
        updated = pattern.sub(lambda _: auto_section, content)
    else:
        updated = content.rstrip() + "\n\n" + auto_section + "\n"
    note_path.write_text(updated, encoding="utf-8")


def main() -> None:
    args = parse_args()
    sessions_root = Path(args.sessions_root)
    session_index = Path(args.session_index)
    vault_root = Path(args.vault_root)
    thread_names = load_thread_names(session_index)

    all_exchanges: list[Exchange] = []
    for session_file in iter_session_files(sessions_root, args.date):
        all_exchanges.extend(parse_session_file(session_file, thread_names, args.min_score))

    all_exchanges.sort(key=lambda item: (item.score, item.local_time), reverse=True)
    all_exchanges = all_exchanges[: args.max_items]

    auto_section = build_auto_section(all_exchanges, args.date)
    if args.dry_run:
        print(auto_section)
        return

    note_path = vault_root / "00-收件箱" / "每日记录" / f"{args.date} - 待整理.md"
    ensure_daily_note(note_path, args.date)
    upsert_auto_section(note_path, auto_section)
    print(f"Wrote {len(all_exchanges)} candidate items to: {note_path}")


if __name__ == "__main__":
    main()

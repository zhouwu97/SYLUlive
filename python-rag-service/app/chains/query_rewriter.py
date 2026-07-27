from __future__ import annotations

import re
from typing import Any

from langchain_core.messages import AIMessage, BaseMessage, HumanMessage
from langchain_core.prompt_values import ChatPromptValue
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.runnables import Runnable, RunnableLambda

from app.schemas import PolicyHistoryMessage, PolicyRAGInput


POLICY_QUERY_REWRITE_VERSION = "bounded-context-v1"
POLICY_HISTORY_MAX_ROUNDS = 4
POLICY_HISTORY_MAX_MESSAGES = POLICY_HISTORY_MAX_ROUNDS * 2
POLICY_HISTORY_MAX_CHARS = 2_400
POLICY_HISTORY_MAX_USER_CHARS = 300
POLICY_HISTORY_MAX_ASSISTANT_CHARS = 600
POLICY_REWRITTEN_QUERY_MAX_CHARS = 300

_FOLLOW_UP_PREFIXES = (
    "那",
    "那么",
    "这个",
    "这种",
    "这类",
    "它",
    "其",
    "还有",
    "再问",
)
_FOLLOW_UP_SUFFIXES = ("呢", "怎么办", "怎么算", "可以吗", "行吗", "如何处理")
_WHITESPACE_PATTERN = re.compile(r"\s+")


def _bounded_content(content: str, limit: int) -> str:
    normalized = _WHITESPACE_PATTERN.sub(" ", content.strip())
    return normalized[:limit]


def bound_policy_history(
    history: list[PolicyHistoryMessage],
) -> list[PolicyHistoryMessage]:
    """对 Go 传入的副本做独立上限校验，只保留完整问答轮次。"""

    rounds: list[tuple[PolicyHistoryMessage, PolicyHistoryMessage]] = []
    pending_user: PolicyHistoryMessage | None = None
    for item in history[-POLICY_HISTORY_MAX_MESSAGES:]:
        limit = (
            POLICY_HISTORY_MAX_USER_CHARS
            if item.role == "user"
            else POLICY_HISTORY_MAX_ASSISTANT_CHARS
        )
        content = _bounded_content(item.content, limit)
        if not content:
            continue
        normalized = item.model_copy(update={"content": content})
        if item.role == "user":
            pending_user = normalized
        elif pending_user is not None:
            rounds.append((pending_user, normalized))
            pending_user = None

    selected: list[tuple[PolicyHistoryMessage, PolicyHistoryMessage]] = []
    total_chars = 0
    for user_message, assistant_message in reversed(rounds[-POLICY_HISTORY_MAX_ROUNDS:]):
        round_chars = len(user_message.content) + len(assistant_message.content)
        if total_chars + round_chars > POLICY_HISTORY_MAX_CHARS:
            break
        selected.append((user_message, assistant_message))
        total_chars += round_chars

    bounded: list[PolicyHistoryMessage] = []
    for user_message, assistant_message in reversed(selected):
        bounded.extend((user_message, assistant_message))
    return bounded


def history_messages(history: list[PolicyHistoryMessage]) -> list[BaseMessage]:
    return [
        HumanMessage(content=item.content)
        if item.role == "user"
        else AIMessage(content=item.content)
        for item in history
    ]


def build_policy_query_rewrite_prompt() -> ChatPromptTemplate:
    return ChatPromptTemplate.from_messages(
        [
            (
                "system",
                "仅补全当前校园政策追问中的必要指代，不添加事实、个人数据或工具结果。",
            ),
            MessagesPlaceholder(variable_name="history", optional=True),
            ("human", "{question}"),
        ]
    )


def _rewrite_prompt_input(request: PolicyRAGInput) -> dict[str, Any]:
    return {
        "history": history_messages(request.history),
        "question": request.question,
    }


def _message_text(message: BaseMessage) -> str:
    if isinstance(message.content, str):
        return message.content.strip()
    return "".join(
        str(part.get("text", "")) if isinstance(part, dict) else str(part)
        for part in message.content
    ).strip()


def _requires_context(question: str) -> bool:
    compact = question.strip("？?。！! ")
    return len(compact) <= 24 and (
        compact.startswith(_FOLLOW_UP_PREFIXES) or compact.endswith(_FOLLOW_UP_SUFFIXES)
    )


def _rewrite_prompt_value(prompt_value: ChatPromptValue) -> str:
    user_messages = [
        _message_text(message)
        for message in prompt_value.to_messages()
        if isinstance(message, HumanMessage) and _message_text(message)
    ]
    if not user_messages:
        raise ValueError("query rewrite has no current question")
    current = user_messages[-1]
    if len(user_messages) < 2 or not _requires_context(current):
        return current[:POLICY_REWRITTEN_QUERY_MAX_CHARS]

    previous = user_messages[-2].strip("？?。！! ")
    if not previous or previous == current:
        return current[:POLICY_REWRITTEN_QUERY_MAX_CHARS]
    separator = "；追问："
    previous_limit = max(
        0,
        POLICY_REWRITTEN_QUERY_MAX_CHARS - len(separator) - len(current),
    )
    if previous_limit == 0:
        return current[:POLICY_REWRITTEN_QUERY_MAX_CHARS]
    return f"{previous[:previous_limit]}{separator}{current}"[:POLICY_REWRITTEN_QUERY_MAX_CHARS]


def build_policy_query_rewriter() -> Runnable[PolicyRAGInput, str]:
    """构造无状态 Query Rewrite Runnable；不会持久化或主动读取任何会话。"""

    prompt = build_policy_query_rewrite_prompt().with_config(
        run_name="policy_query_rewrite_prompt"
    )
    return (
        RunnableLambda(_rewrite_prompt_input)
        | prompt
        | RunnableLambda(_rewrite_prompt_value)
    ).with_config(
        run_name="policy_query_rewrite",
        tags=[f"query_rewrite_version:{POLICY_QUERY_REWRITE_VERSION}"],
    )

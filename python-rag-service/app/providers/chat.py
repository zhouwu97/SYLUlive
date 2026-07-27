from __future__ import annotations

import os
from collections.abc import Iterator
from dataclasses import dataclass
from urllib.parse import urlsplit, urlunsplit

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, AIMessageChunk, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatGenerationChunk, ChatResult
from langchain_openai import ChatOpenAI


def _normalized_base_url(value: str) -> str:
    parsed = urlsplit(value.strip())
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username:
        raise ValueError("invalid provider base URL")
    path = parsed.path.rstrip("/")
    return urlunsplit((parsed.scheme.lower(), parsed.netloc.lower(), path, "", ""))


@dataclass(frozen=True)
class PolicyChatProvider:
    model: BaseChatModel
    provider_name: str
    model_name: str
    ready: bool


class UnavailablePolicyChatModel(BaseChatModel):
    reason: str = "provider_not_ready"

    @property
    def _llm_type(self) -> str:
        return "unavailable-policy-chat"

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        raise RuntimeError(self.reason)


class FakePolicyChatModel(BaseChatModel):
    """固定 usage 的离线 ChatModel，确保结算协议也能被测试。"""

    response_text: str
    input_tokens: int = 12
    output_tokens: int = 6
    cache_hit_tokens: int = 0

    @property
    def _llm_type(self) -> str:
        return "fake-policy-chat"

    @property
    def _identifying_params(self) -> dict[str, object]:
        return {"model": "fake-policy-chat-v1"}

    def _usage(self) -> dict[str, int]:
        return {
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "total_tokens": self.input_tokens + self.output_tokens,
        }

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> ChatResult:
        message = AIMessage(
            content=self.response_text,
            usage_metadata=self._usage(),
            response_metadata={"cache_hit_tokens": self.cache_hit_tokens},
        )
        return ChatResult(generations=[ChatGeneration(message=message)])

    def _stream(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: object,
    ) -> Iterator[ChatGenerationChunk]:
        yield ChatGenerationChunk(message=AIMessageChunk(content=self.response_text))
        yield ChatGenerationChunk(
            message=AIMessageChunk(
                content="",
                usage_metadata=self._usage(),
                response_metadata={"cache_hit_tokens": self.cache_hit_tokens},
            )
        )


def build_policy_chat_provider() -> PolicyChatProvider:
    provider_name = os.environ.get("RAG_CHAT_PROVIDER", "openai-compatible").strip()
    model_name = os.environ.get("RAG_CHAT_MODEL", "").strip()
    api_key = os.environ.get("RAG_PROVIDER_API_KEY", "").strip()
    base_url_value = os.environ.get("RAG_PROVIDER_BASE_URL", "https://api.deepseek.com").strip()
    allowed_values = os.environ.get(
        "RAG_PROVIDER_ALLOWED_BASE_URLS", "https://api.deepseek.com"
    ).split(",")
    try:
        base_url = _normalized_base_url(base_url_value)
        allowed = {_normalized_base_url(value) for value in allowed_values if value.strip()}
    except ValueError:
        return PolicyChatProvider(
            UnavailablePolicyChatModel(), provider_name or "unavailable", model_name or "unconfigured", False
        )
    if provider_name != "openai-compatible" or not model_name or not api_key or base_url not in allowed:
        return PolicyChatProvider(
            UnavailablePolicyChatModel(), provider_name or "unavailable", model_name or "unconfigured", False
        )
    timeout = max(5, min(int(os.environ.get("RAG_PROVIDER_TIMEOUT_SECONDS", "45")), 120))
    model = ChatOpenAI(
        model=model_name,
        api_key=api_key,
        base_url=base_url,
        timeout=timeout,
        max_retries=1,
        streaming=True,
        stream_usage=True,
    )
    return PolicyChatProvider(model, provider_name, model_name, True)

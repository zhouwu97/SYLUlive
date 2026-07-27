import asyncio
import io
import json
import os
import re
from contextlib import asynccontextmanager
from typing import Annotated

import jieba
from bs4 import BeautifulSoup
from docx import Document
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastembed import TextEmbedding
from langchain_core.runnables import Runnable
from pydantic import BaseModel, Field
from pypdf import PdfReader

from app.chains import (
    POLICY_RAG_CHAIN_NAME,
    POLICY_RAG_CHAIN_VERSION,
    astream_policy_events,
    build_policy_rag_chain,
)
from app.providers import build_policy_chat_provider
from app.retrievers import FoundationPolicyRetriever
from app.schemas import PolicyRAGEvent, PolicyRAGInput, PolicyRAGResult


SERVICE_TOKEN = os.environ.get("RAG_SERVICE_TOKEN", "").strip()
MODEL_NAME = os.environ.get(
    "RAG_EMBEDDING_MODEL", "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
).strip()
MODEL_VERSION = os.environ.get(
    "RAG_EMBEDDING_MODEL_VERSION", "paraphrase-multilingual-minilm-l12-v2-padded-1536-v1"
).strip()
MAX_BATCH = max(1, min(int(os.environ.get("RAG_MAX_BATCH", "32")), 64))
MAX_CONCURRENCY = max(1, min(int(os.environ.get("RAG_MAX_CONCURRENCY", "2")), 4))
QUERY_TIMEOUT_SECONDS = max(5, min(int(os.environ.get("RAG_QUERY_TIMEOUT_SECONDS", "60")), 120))
MAX_TEXT_CHARS = 100_000
TARGET_DIMENSIONS = 1536
MAX_POLICY_RESPONSE_BYTES = 1 << 20

model: TextEmbedding | None = None
model_error = ""
semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
query_semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
policy_chain: Runnable[PolicyRAGInput, PolicyRAGResult] | None = None
policy_provider_ready = False
policy_provider_name = "unconfigured"
policy_model_name = "unconfigured"


@asynccontextmanager
async def lifespan(_: FastAPI):
    global model, model_error, policy_chain, policy_provider_ready, policy_provider_name, policy_model_name
    if not SERVICE_TOKEN:
        model_error = "RAG_SERVICE_TOKEN is not configured"
    else:
        try:
            model = await asyncio.to_thread(TextEmbedding, model_name=MODEL_NAME)
        except Exception as exc:  # 健康接口仅返回分类，不泄露下载路径或请求细节。
            model_error = type(exc).__name__
    provider = build_policy_chat_provider()
    policy_provider_ready = provider.ready
    policy_provider_name = provider.provider_name
    policy_model_name = provider.model_name
    policy_chain = build_policy_rag_chain(
        FoundationPolicyRetriever(),
        provider.model,
        provider_name=provider.provider_name,
        model_name=provider.model_name,
    )
    yield


app = FastAPI(title="Shenliyuan RAG Service", docs_url=None, redoc_url=None, lifespan=lifespan)


def require_internal_service(
    x_internal_service_token: Annotated[str | None, Header()] = None,
) -> None:
    if not SERVICE_TOKEN or x_internal_service_token != SERVICE_TOKEN:
        raise HTTPException(status_code=401, detail="internal service authentication failed")


class EmbedRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARS)


class EmbedBatchRequest(BaseModel):
    texts: list[str] = Field(min_length=1, max_length=MAX_BATCH)


class AnalyzeRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARS)


class ParseRequest(BaseModel):
    source_type: str
    content_base64: str = Field(max_length=12_000_000)
    file_name: str = Field(default="", max_length=255)


def _ready_model() -> TextEmbedding:
    if model is None:
        raise HTTPException(status_code=503, detail="embedding model unavailable")
    return model


def _padded_embedding(values) -> list[float]:
    vector = [float(value) for value in values]
    if len(vector) > TARGET_DIMENSIONS:
        raise ValueError("embedding dimensions exceed database contract")
    vector.extend([0.0] * (TARGET_DIMENSIONS - len(vector)))
    return vector


async def _embed(texts: list[str]) -> list[list[float]]:
    if any(not value.strip() or len(value) > MAX_TEXT_CHARS for value in texts):
        raise HTTPException(status_code=422, detail="invalid embedding text")
    current = _ready_model()
    async with semaphore:
        try:
            vectors = await asyncio.to_thread(lambda: list(current.embed(texts)))
            return [_padded_embedding(vector) for vector in vectors]
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=503, detail="embedding failed") from exc


@app.get("/health", dependencies=[Depends(require_internal_service)])
async def health():
    if model is None:
        raise HTTPException(status_code=503, detail={"status": "error", "class": model_error})
    return {
        "status": "ok",
        "model_version": MODEL_VERSION,
        "dimensions": TARGET_DIMENSIONS,
        "max_batch": MAX_BATCH,
        "chain_name": POLICY_RAG_CHAIN_NAME,
        "chain_version": POLICY_RAG_CHAIN_VERSION,
        "dependencies_ready": {
            "embedding": model is not None,
            "lcel": policy_chain is not None,
            "chat_provider": policy_provider_ready,
        },
    }


def _ready_policy_chain(request: Request) -> Runnable[PolicyRAGInput, PolicyRAGResult]:
    injected = getattr(request.app.state, "policy_chain", None)
    current = injected or policy_chain
    if current is None:
        raise HTTPException(status_code=503, detail="policy RAG chain unavailable")
    return current


@app.post(
    "/internal/rag/policy/query",
    response_model=PolicyRAGResult,
    dependencies=[Depends(require_internal_service)],
)
async def policy_query(payload: PolicyRAGInput, request: Request):
    chain = _ready_policy_chain(request)
    try:
        async with query_semaphore:
            async with asyncio.timeout(QUERY_TIMEOUT_SECONDS):
                result = await chain.ainvoke(payload)
        validated = result if isinstance(result, PolicyRAGResult) else PolicyRAGResult.model_validate(result)
        if len(validated.model_dump_json().encode("utf-8")) > MAX_POLICY_RESPONSE_BYTES:
            raise ValueError("policy response exceeds limit")
        return validated
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="policy RAG timeout") from exc
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail="policy RAG failed") from exc


@app.post(
    "/internal/rag/policy/query/stream",
    dependencies=[Depends(require_internal_service)],
)
async def policy_query_stream(payload: PolicyRAGInput, request: Request):
    chain = _ready_policy_chain(request)

    async def event_source():
        total_bytes = 0
        last_sequence = 0
        try:
            async with query_semaphore:
                async with asyncio.timeout(QUERY_TIMEOUT_SECONDS):
                    async for event in astream_policy_events(chain, payload):
                        if await request.is_disconnected():
                            raise asyncio.CancelledError
                        encoded = json.dumps(event.model_dump(mode="json"), ensure_ascii=False)
                        last_sequence = event.sequence
                        frame = f"event: policy_rag\ndata: {encoded}\n\n".encode("utf-8")
                        total_bytes += len(frame)
                        if total_bytes > MAX_POLICY_RESPONSE_BYTES:
                            raise ValueError("policy stream exceeds limit")
                        yield frame
        except TimeoutError:
            # 流已开始后只能通过稳定事件报告超时，不能再改变 HTTP 状态码。
            error = PolicyRAGEvent(
                request_id=payload.request_id,
                chain_name=POLICY_RAG_CHAIN_NAME,
                chain_version=POLICY_RAG_CHAIN_VERSION,
                sequence=last_sequence + 1,
                type="failed",
                error_code="rag_timeout",
            )
            encoded = json.dumps(error.model_dump(mode="json"), ensure_ascii=False)
            yield f"event: policy_rag\ndata: {encoded}\n\n".encode("utf-8")

    return StreamingResponse(
        event_source(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


@app.post("/internal/rag/embed", dependencies=[Depends(require_internal_service)])
async def embed(request: EmbedRequest):
    vectors = await _embed([request.text])
    return {"embeddings": vectors, "model_version": MODEL_VERSION, "dimensions": TARGET_DIMENSIONS}


@app.post("/internal/rag/embed-batch", dependencies=[Depends(require_internal_service)])
async def embed_batch(request: EmbedBatchRequest):
    vectors = await _embed(request.texts)
    return {"embeddings": vectors, "model_version": MODEL_VERSION, "dimensions": TARGET_DIMENSIONS}


@app.post("/internal/rag/analyze", dependencies=[Depends(require_internal_service)])
async def analyze(request: AnalyzeRequest):
    normalized = re.sub(r"\s+", " ", request.text.strip())
    tokens = [token.strip() for token in jieba.cut_for_search(normalized) if token.strip()]
    tokens = list(dict.fromkeys(tokens))[:256]
    return {
        "tokens": tokens,
        "search_string": " ".join(tokens) or normalized,
        "model_version": MODEL_VERSION,
    }


def _parse_document(source_type: str, raw: bytes) -> str:
    normalized_type = source_type.lower().strip()
    if normalized_type in {"text", "txt", "plain"}:
        return raw.decode("utf-8-sig")
    if normalized_type in {"html", "htm"}:
        return BeautifulSoup(raw, "html.parser").get_text("\n", strip=True)
    if normalized_type == "pdf":
        reader = PdfReader(io.BytesIO(raw))
        return "\n\n".join((page.extract_text() or "") for page in reader.pages)
    if normalized_type == "docx":
        document = Document(io.BytesIO(raw))
        return "\n".join(paragraph.text for paragraph in document.paragraphs)
    raise ValueError("unsupported source type")


@app.post("/internal/rag/parse", dependencies=[Depends(require_internal_service)])
async def parse_document(request: ParseRequest):
    import base64

    try:
        raw = base64.b64decode(request.content_base64, validate=True)
        if len(raw) > 8 * 1024 * 1024:
            raise ValueError("document exceeds limit")
        text = await asyncio.to_thread(_parse_document, request.source_type, raw)
        text = re.sub(r"\r\n?", "\n", text).strip()
        if not text or len(text) > 2 * 1024 * 1024:
            raise ValueError("document has no supported text")
        return {"text": text, "source_type": request.source_type.lower(), "file_name": request.file_name}
    except Exception as exc:
        raise HTTPException(status_code=422, detail="document parsing failed") from exc

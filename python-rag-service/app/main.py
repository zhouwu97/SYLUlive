import asyncio
import io
import json
import os
import re
from contextlib import asynccontextmanager
from typing import Annotated

import jieba
from bs4 import BeautifulSoup
from docx import Document as DocxDocument
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.responses import StreamingResponse
from fastembed import TextEmbedding
from langchain_core.runnables import Runnable
from pydantic import BaseModel, Field
from pypdf import PdfReader

from app.chains import (
    POLICY_RAG_CHAIN_NAME,
    POLICY_RAG_CHAIN_VERSION,
    PolicyQueryPlanner,
    astream_policy_events,
    build_policy_rag_chain,
)
from app.ingestion import FastEmbedLangChainEmbeddings, chunk_policy_document
from app.providers import build_policy_chat_provider
from app.rerankers import (
    FastEmbedCrossEncoderRerankModel,
    POLICY_DOCUMENT_TYPE_LABEL_VERSION,
    PolicyReranker,
    UnavailablePolicyRerankModel,
)
from app.retrievers import HybridPolicyRetriever, PostgresPolicySearchStore, UnavailablePolicySearchStore
from app.schemas import (
    KnowledgeChunkRequest,
    KnowledgeChunkResult,
    PolicyQueryPlan,
    PolicyRAGEvent,
    PolicyRAGInput,
    PolicyRAGResult,
)


def _env_enabled(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


SERVICE_TOKEN = os.environ.get("RAG_SERVICE_TOKEN", "").strip()
MODEL_NAME = os.environ.get(
    "RAG_EMBEDDING_MODEL", "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
).strip()
MODEL_VERSION = os.environ.get(
    "RAG_EMBEDDING_MODEL_VERSION", "paraphrase-multilingual-minilm-l12-v2-384-v1"
).strip()
EXPECTED_DIMENSIONS = max(1, min(int(os.environ.get("RAG_EMBEDDING_DIMENSIONS", "384")), 2_000))
MAX_BATCH = max(1, min(int(os.environ.get("RAG_MAX_BATCH", "32")), 64))
MAX_CONCURRENCY = max(1, min(int(os.environ.get("RAG_MAX_CONCURRENCY", "2")), 4))
QUERY_TIMEOUT_SECONDS = max(5, min(int(os.environ.get("RAG_QUERY_TIMEOUT_SECONDS", "60")), 120))
MAX_TEXT_CHARS = 100_000
MAX_POLICY_RESPONSE_BYTES = 1 << 20
RERANKER_ENABLED = _env_enabled("RAG_RERANKER_ENABLED")
RERANKER_ALLOW_MODEL_DOWNLOAD = _env_enabled("RAG_RERANKER_ALLOW_MODEL_DOWNLOAD")
RERANKER_MODEL_NAME = os.environ.get(
    "RAG_RERANKER_MODEL", "BAAI/bge-reranker-base"
).strip()
RERANKER_MODEL_VERSION = os.environ.get(
    "RAG_RERANKER_MODEL_VERSION", "bge-reranker-base-fastembed-v1"
).strip()
RERANKER_RELEVANCE_THRESHOLD = max(
    0.0,
    min(
        float(os.environ.get("RAG_RERANKER_RELEVANCE_THRESHOLD", "0.689045")),
        1.0,
    ),
)
RERANKER_TIMEOUT_SECONDS = max(
    0.1, min(float(os.environ.get("RAG_RERANKER_TIMEOUT_SECONDS", "5")), 30.0)
)
RERANKER_BATCH_SIZE = max(1, min(int(os.environ.get("RAG_RERANKER_BATCH_SIZE", "16")), 64))
RERANKER_MAX_DOCUMENT_CHARS = max(
    128, min(int(os.environ.get("RAG_RERANKER_MAX_DOCUMENT_CHARS", "4000")), 8_000)
)

model: FastEmbedLangChainEmbeddings | None = None
model_error = ""
semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
query_semaphore = asyncio.Semaphore(MAX_CONCURRENCY)
policy_chain: Runnable[PolicyRAGInput, PolicyRAGResult] | None = None
policy_provider_ready = False
policy_provider_name = "unconfigured"
policy_model_name = "unconfigured"
policy_query_planner = PolicyQueryPlanner()
retrieval_ready = False
retrieval_error = "missing_database_dsn"
reranker_ready = False
reranker_error = "disabled"


def _planned_reranker_query(question: str) -> str:
    return policy_query_planner.invoke(question).retrieval_query


@asynccontextmanager
async def lifespan(_: FastAPI):
    global model, model_error, policy_chain, policy_provider_ready, policy_provider_name, policy_model_name
    global retrieval_ready, retrieval_error, reranker_ready, reranker_error
    model = None
    model_error = ""
    if not SERVICE_TOKEN:
        model_error = "RAG_SERVICE_TOKEN is not configured"
    else:
        try:
            client = await asyncio.to_thread(TextEmbedding, model_name=MODEL_NAME)
            candidate = FastEmbedLangChainEmbeddings(
                client,
                model_name=MODEL_NAME,
                model_version=MODEL_VERSION,
                expected_dimensions=EXPECTED_DIMENSIONS,
            )
            # 启动时用固定非敏感文本核验真实维度，健康检查不能把配置值冒充模型输出。
            await candidate.aembed_query("向量维度校验")
            model = candidate
        except Exception as exc:  # 健康接口仅返回分类，不泄露下载路径或请求细节。
            model_error = type(exc).__name__
    provider = build_policy_chat_provider()
    policy_provider_ready = provider.ready
    policy_provider_name = provider.provider_name
    policy_model_name = provider.model_name
    channel_timeout = max(
        0.1,
        min(float(os.environ.get("RAG_RETRIEVAL_CHANNEL_TIMEOUT_SECONDS", "2.5")), 30),
    )
    database_dsn = os.environ.get("RAG_DATABASE_DSN", "").strip()
    search_store: PostgresPolicySearchStore | UnavailablePolicySearchStore
    retrieval_ready = False
    if database_dsn:
        try:
            search_store = PostgresPolicySearchStore(
                database_dsn,
                statement_timeout_seconds=channel_timeout,
            )
            await asyncio.to_thread(search_store.check_read_only_permissions)
            retrieval_ready = True
            retrieval_error = ""
        except Exception as exc:
            search_store = UnavailablePolicySearchStore()
            retrieval_error = type(exc).__name__
    else:
        search_store = UnavailablePolicySearchStore()
        retrieval_error = "missing_database_dsn"
    retriever = HybridPolicyRetriever(
        planner=policy_query_planner,
        search_store=search_store,
        embeddings=model,
        embedding_model_version=MODEL_VERSION,
        channel_timeout_seconds=channel_timeout,
    )
    reranker: PolicyReranker | None = None
    reranker_ready = False
    reranker_error = "disabled"
    if RERANKER_ENABLED:
        try:
            rerank_model = FastEmbedCrossEncoderRerankModel(
                model_name=RERANKER_MODEL_NAME,
                model_version=RERANKER_MODEL_VERSION,
                allow_model_download=RERANKER_ALLOW_MODEL_DOWNLOAD,
                cache_dir=os.environ.get("FASTEMBED_CACHE_PATH", "").strip() or None,
                batch_size=RERANKER_BATCH_SIZE,
                max_concurrency=MAX_CONCURRENCY,
            )
            reranker_ready = True
            reranker_error = ""
        except Exception as exc:
            rerank_model = UnavailablePolicyRerankModel()
            reranker_error = type(exc).__name__
        reranker = PolicyReranker(
            rerank_model=rerank_model,
            model_name=RERANKER_MODEL_NAME,
            model_version=RERANKER_MODEL_VERSION,
            top_n=10,
            max_candidates=20,
            timeout_seconds=RERANKER_TIMEOUT_SECONDS,
            max_document_chars=RERANKER_MAX_DOCUMENT_CHARS,
            max_concurrency=MAX_CONCURRENCY,
            query_transform=_planned_reranker_query,
            query_strategy="policy-planned-query-v1",
        )
    policy_chain = build_policy_rag_chain(
        retriever,
        provider.model,
        provider_name=provider.provider_name,
        model_name=provider.model_name,
        reranker=reranker,
        relevance_threshold=RERANKER_RELEVANCE_THRESHOLD,
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


class PolicyPlanRequest(BaseModel):
    text: str = Field(min_length=1, max_length=300)


class ParseRequest(BaseModel):
    source_type: str
    content_base64: str = Field(max_length=12_000_000)
    file_name: str = Field(default="", max_length=255)


def _ready_model() -> FastEmbedLangChainEmbeddings:
    if model is None:
        raise HTTPException(status_code=503, detail="embedding model unavailable")
    return model


async def _embed(texts: list[str]) -> list[list[float]]:
    if any(not value.strip() or len(value) > MAX_TEXT_CHARS for value in texts):
        raise HTTPException(status_code=422, detail="invalid embedding text")
    current = _ready_model()
    async with semaphore:
        try:
            return await current.aembed_documents(texts)
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
        "model_name": MODEL_NAME,
        "model_version": MODEL_VERSION,
        "dimensions": model.dimensions,
        "max_batch": MAX_BATCH,
        "chain_name": POLICY_RAG_CHAIN_NAME,
        "chain_version": POLICY_RAG_CHAIN_VERSION,
        "dependencies_ready": {
            "embedding": model is not None,
            "lcel": policy_chain is not None,
            "chat_provider": policy_provider_ready,
            "policy_database": retrieval_ready,
            "hybrid_retriever": retrieval_ready and model is not None,
            "reranker_enabled": RERANKER_ENABLED,
            "reranker": reranker_ready if RERANKER_ENABLED else False,
        },
        "reranker": {
            "enabled": RERANKER_ENABLED,
            "ready": reranker_ready,
            "model": RERANKER_MODEL_NAME if RERANKER_ENABLED else "disabled",
            "model_version": RERANKER_MODEL_VERSION if RERANKER_ENABLED else "disabled",
            "relevance_threshold": RERANKER_RELEVANCE_THRESHOLD,
            "model_download_allowed": RERANKER_ALLOW_MODEL_DOWNLOAD,
            "query_strategy": "policy-planned-query-v1",
            "document_type_label_version": POLICY_DOCUMENT_TYPE_LABEL_VERSION,
            "error_class": reranker_error,
        },
    }


def _ready_policy_chain(request: Request) -> Runnable[PolicyRAGInput, PolicyRAGResult]:
    injected = getattr(request.app.state, "policy_chain", None)
    current = injected or policy_chain
    if current is None:
        raise HTTPException(status_code=503, detail="policy RAG chain unavailable")
    return current


@app.post(
    "/internal/rag/policy/plan",
    response_model=PolicyQueryPlan,
    dependencies=[Depends(require_internal_service)],
)
async def policy_query_plan(payload: PolicyPlanRequest) -> PolicyQueryPlan:
    """兼容旧 Go 检索链路；查询规划规则只在 Python 维护。"""

    return await policy_query_planner.ainvoke(payload.text)


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
    return {
        "embeddings": vectors,
        "model_name": MODEL_NAME,
        "model_version": MODEL_VERSION,
        "dimensions": len(vectors[0]),
    }


@app.post("/internal/rag/embed-batch", dependencies=[Depends(require_internal_service)])
async def embed_batch(request: EmbedBatchRequest):
    vectors = await _embed(request.texts)
    return {
        "embeddings": vectors,
        "model_name": MODEL_NAME,
        "model_version": MODEL_VERSION,
        "dimensions": len(vectors[0]),
    }


@app.post(
    "/internal/rag/knowledge/chunk",
    response_model=KnowledgeChunkResult,
    dependencies=[Depends(require_internal_service)],
)
async def chunk_knowledge_document(request: KnowledgeChunkRequest):
    try:
        return await asyncio.to_thread(chunk_policy_document, request)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="knowledge document chunking failed") from exc


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
        document = DocxDocument(io.BytesIO(raw))
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

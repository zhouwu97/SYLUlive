"""Opt-in real-model evaluation against frozen, independent public-policy questions."""
from __future__ import annotations

import argparse
import asyncio
from collections import Counter
import hashlib
import json
import logging
import math
from pathlib import Path
import re
import time
import unicodedata

import httpx
import jieba
import jieba.posseg
from langchain_core.documents import Document
from langchain_core.retrievers import BaseRetriever
from langchain_core.callbacks import BaseCallbackHandler
from langchain_openai import ChatOpenAI
from pydantic import PrivateAttr

from app.chains import PolicyQueryPlanner, build_policy_rag_chain
from app.evaluation import evaluate_reranker_fixture, _calibrate_threshold
from app.rerankers import FastEmbedCrossEncoderRerankModel, PolicyReranker
from app.ingestion.policy import chunk_policy_document
from app.schemas import KnowledgeChunkRequest
from app.chains.policy import _bounded_documents, _citation_quote_is_supported


RERANK_MODEL = "BAAI/bge-reranker-v2-m3-int8"
RERANK_VERSION = "bge-v2-m3-int8-fastembed-0.9.1"
RERANK_PROFILE = 'cpu-512-chars-batch2-top10-candidates20-planned-v4'
RETRIEVAL_VERSION = 'production-policy-chunks-scoped-bm25-diverse-v8'
EVALUATOR_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


class ValidationMetrics(logging.Handler):
    """Keep only bounded failure categories, never model prose or exception payloads."""
    def __init__(self):
        super().__init__()
        self.codes: Counter[str] = Counter()

    def emit(self, record):
        message = record.getMessage()
        for prefix, code in (
            ('calculation claim lacks cited evidence', 'calculation_evidence_missing'),
            ('citation quote is not in source evidence', 'quote_not_in_evidence'),
            ('declared citations and cited rules differ', 'citation_rule_mismatch'),
            ('historical', 'historical_boundary_invalid'),
            ('model forged', 'unknown_reference'),
        ):
            if prefix in message:
                self.codes[code] += 1
                return
        self.codes['other_validation_failure'] += 1


class PublicAuditCapture(BaseCallbackHandler):
    """Optional inspection for this frozen public corpus, never production tracing."""
    def __init__(self):
        self.documents = []
        self.attempts = []

    def on_chain_end(self, outputs, **_):
        if isinstance(outputs, dict) and all(key in outputs for key in ('request','query_plan','documents')):
            self.documents = _bounded_documents(outputs)

    def on_llm_end(self, response, **_):
        for group in response.generations:
            for generation in group:
                content = getattr(getattr(generation,'message',None),'content','')
                if not isinstance(content,str):
                    continue
                try:
                    parsed = json.loads(re.sub(r'^```(?:json)?\s*|\s*```$', '', content.strip()))
                except ValueError:
                    continue
                if not isinstance(parsed,dict):
                    continue
                self.attempts.append({key:parsed[key] for key in ('answer','current_rules','historical_rules','citations','warnings','confidence') if key in parsed})


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(question: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKC", question).casefold() if c.isalnum())


def load_cases(manifest: Path, calibration: Path) -> dict:
    data = json.loads(manifest.read_text(encoding="utf-8"))
    seen = {normalized(json.loads(line)["question"]) for line in calibration.read_text(encoding="utf-8").splitlines() if line.strip()}
    ids: set[str] = set()
    questions: set[str] = set()
    for case in data["cases"]:
        key = normalized(case["question"])
        if case["id"] in ids or key in questions or key in seen:
            raise ValueError("holdout overlaps calibration or contains duplicates")
        if "answer" in case or "fixture" in case:
            raise ValueError("holdout cannot contain generated answers or replay fixtures")
        ids.add(case["id"])
        questions.add(key)
    if not ids:
        raise ValueError("holdout must contain cases")
    return data


def corpus_documents(path: Path) -> list[Document]:
    documents = []
    for document_id, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        item = json.loads(line)
        historical = item['document_type'].startswith('historical_')
        chunks = chunk_policy_document(KnowledgeChunkRequest(document_id=document_id,
            title=item['title'], content=item['content'], document_type=item['document_type'],
            department=item.get('department',''), source_locator=item.get('source_file_name',''),
            version_status='historical' if historical else 'active',
            effective_from=item.get('effective_from') or None, effective_to=item.get('effective_to') or None))
        for chunk in chunks.chunks:
            chunk_id = len(documents) + 1
            documents.append(Document(page_content=chunk.content, metadata={
                **chunk.metadata,
                "source_id": f"chunk:{chunk_id}", "chunk_id": chunk_id,
                "document_id": document_id, "title": item["title"],
                "document_type": item["document_type"],
                "source_url": item.get("source_uri", ""),
                'section_title':chunk.section_title,
                "source_locator": chunk.source_locator,
                "historical": historical,
                "degraded_modes": [],
            }))
    return documents


def tokens(text: str) -> list[str]:
    words = [word.casefold() for word in jieba.cut_for_search(text) if len(word.strip()) >= 2 or word.isdigit()]
    # Short Chinese facts must match even when HMM tokenization joins them differently.
    for phrase in re.findall(r'[\u4e00-\u9fff]+',text):
        words.extend(phrase[index:index+2] for index in range(len(phrase)-1))
    return words


class LocalCorpusRetriever(BaseRetriever):
    """BM25 over the complete public import corpus; no case labels or answers are used."""
    documents: list[Document]
    _frequencies: list[Counter] = PrivateAttr(default_factory=list)
    _document_frequency: Counter = PrivateAttr(default_factory=Counter)
    _lengths: list[int] = PrivateAttr(default_factory=list)
    _average: float = PrivateAttr(default=0)

    def model_post_init(self, __context):
        del __context
        self._frequencies = [Counter(tokens(f"{document.metadata['title']}\n{document.page_content}")) for document in self.documents]
        self._document_frequency = Counter(word for frequency in self._frequencies for word in frequency)
        self._lengths = [sum(frequency.values()) for frequency in self._frequencies]
        self._average = sum(self._lengths) / max(1,len(self._lengths))

    def _get_relevant_documents(self, query: str, *, run_manager) -> list[Document]:
        del run_manager
        plan = PolicyQueryPlanner().invoke(query)
        lexical_query = plan.reranking_query if plan.uses_neutral_historical_query else plan.normalized_question
        query_tokens = set(tokens(plan.retrieval_query + ' ' + plan.reranking_query))
        original_tokens = set(tokens(lexical_query))
        nouns = {word.word.casefold() for word in jieba.posseg.cut(lexical_query)
            if word.flag.startswith('n') and len(word.word) >= 2}
        frequencies, lengths, average = self._frequencies, self._lengths, self._average
        scores = []
        for index, frequency in enumerate(frequencies):
            score = 0.0
            for word in query_tokens:
                count = frequency[word]
                if not count:
                    continue
                df = self._document_frequency[word]
                idf = math.log(1 + (len(frequencies) - df + .5) / (df + .5))
                weight = (4 if word in nouns and df <= len(frequencies) * .1 else 1) if word in original_tokens else .15
                score += weight * idf * count * 2.5 / (count + 1.5 * (.25 + .75 * lengths[index] / max(1, average)))
            if score > 0:
                scores.append((score, index))
        ranked = sorted(scores, reverse=True)
        preferred = [(score,index) for score,index in ranked
            if self.documents[index].metadata['document_type'] in plan.preferred_document_types]
        # Explicit policy domains use their own documents once enough candidates exist.
        # The planner, not holdout labels, defines this scope.
        pool = preferred if len(preferred) >= 4 else ranked
        selected = []
        per_document = Counter()
        for _, index in pool:
            document = self.documents[index]
            document_id = document.metadata['document_id']
            if per_document[document_id] >= 3:
                continue
            per_document[document_id] += 1
            selected.append(document)
            if len(selected) == 20:
                break
        return selected


def evaluation_reranker(model):
    planner = PolicyQueryPlanner()
    return PolicyReranker(rerank_model=model, model_name=RERANK_MODEL,
        model_version=RERANK_VERSION, top_n=10, max_candidates=20, timeout_seconds=30,
        max_document_chars=512,
        query_transform=lambda question: planner.invoke(question).reranking_query,
        query_strategy='policy-planned-query-v4')


def calibrate_corpus(arguments, model) -> dict:
    """Use calibration questions with the same complete corpus and retrieval path as the holdout."""
    retriever = LocalCorpusRetriever(documents=corpus_documents(arguments.corpus))
    reranker = evaluation_reranker(model)
    rows = []
    for line in (arguments.calibration_data / 'policy_quality.jsonl').read_text(encoding='utf8').splitlines():
        if not line.strip():
            continue
        case = json.loads(line)
        documents = list(reranker.compress_documents(retriever.invoke(case['question']), case['question']))
        if any('rerank_score' not in document.metadata for document in documents):
            raise RuntimeError(f"real corpus calibration unavailable for case {case['id']}")
        rows.append({'id':case['id'], 'should_refuse':bool(case.get('should_refuse')),
            'top_score':max((document.metadata['rerank_score'] for document in documents), default=0)})
        print(json.dumps({'calibration_case':case['id']}), flush=True)
    threshold = _calibrate_threshold(rows)
    positives = [row for row in rows if not row['should_refuse']]
    negatives = [row for row in rows if row['should_refuse']]
    false_accepts = [row['id'] for row in negatives if row['top_score'] >= threshold]
    false_rejects = [row['id'] for row in positives if row['top_score'] < threshold]
    return {'schema':'real-complete-corpus-calibration/v1', 'model':RERANK_MODEL,
        'model_version':RERANK_VERSION, 'relevance_threshold':threshold,
        'calibration_questions_sha256':digest(arguments.calibration_data / 'policy_quality.jsonl'),
        'corpus_sha256':digest(arguments.corpus), 'retrieval':'local-complete-corpus-bm25',
        'retrieval_version':RETRIEVAL_VERSION,
        'rerank_profile':RERANK_PROFILE,
        'cases':len(rows), 'rows':rows, 'false_accepts':false_accepts, 'false_rejects':false_rejects,
        'answerable_recall':1-len(false_rejects)/max(1,len(positives)),
        'negative_rejection_rate':1-len(false_accepts)/max(1,len(negatives))}


def check_result(case: dict, result, corpus_ids: set[tuple[int, int]], provider_key: str) -> list[str]:
    failures = []
    if case.get("expect_unverified"):
        if result.status == "completed" and result.answer_mode == "verified_campus":
            failures.append("unsupported_verified_answer")
    else:
        if result.status != "completed" or result.answer_mode != "verified_campus":
            failures.append("answer_not_verified")
        if not set(case["target_document_types"]) & {source.document_type for source in result.sources}:
            failures.append("expected_source_missing")
    if any((source.document_id, source.chunk_id) not in corpus_ids or
           source.source_id != f'R{source.citation_number}' for source in result.sources):
        failures.append("unknown_source")
    references = {int(value) for value in re.findall(r"\[(\d+)\]", result.answer)}
    if not references.issubset({source.citation_number for source in result.sources}):
        failures.append("unknown_citation")
    for pattern in case.get("required_patterns", []):
        if not re.search(pattern, result.answer):
            failures.append("required_fact_missing")
    for pattern in case.get("forbidden_patterns", []):
        if re.search(pattern, result.answer):
            failures.append("forbidden_claim")
    if provider_key and provider_key in result.answer:
        failures.append("credential_disclosure")
    if "rerank" in result.degraded_modes:
        failures.append("real_reranker_unavailable")
    return sorted(set(failures))


async def run(arguments, data: dict, model) -> dict:
    calibration = json.loads(arguments.calibration_report.read_text(encoding="utf-8"))
    if calibration["model"] != RERANK_MODEL or calibration["model_version"] != RERANK_VERSION:
        raise ValueError("calibration does not match the actual model")
    if calibration.get('retrieval_version') != RETRIEVAL_VERSION or calibration.get('corpus_sha256') != digest(arguments.corpus):
        raise ValueError('calibration must use the same complete corpus and retrieval version')
    if calibration.get('rerank_profile') != RERANK_PROFILE:
        raise ValueError('calibration must use the same rerank resource profile')
    # Configuration is read in memory; none of its contents or path are placed in the report.
    config = json.loads(arguments.astrbot_config.read_text(encoding="utf-8-sig"))
    selected = next(item for item in config["provider"] if item["id"] == arguments.model_id and item.get("enable"))
    source = next(item for item in config["provider_sources"] if item["id"] == selected["provider_source_id"])
    if source["api_base"].rstrip("/") != arguments.allow_provider_origin.rstrip("/"):
        raise ValueError("provider origin is not explicitly allowed")
    keys = source["key"]
    key = keys[0] if isinstance(keys, list) else keys
    extra = selected.get("custom_extra_body", {})
    if set(extra) - {"thinking", "reasoning_effort", "chat_template_kwargs"}:
        raise ValueError("unsupported provider request override")
    sync_client = httpx.Client(proxy=source.get("proxy") or None, timeout=45, trust_env=False)
    async_client = httpx.AsyncClient(proxy=source.get("proxy") or None, timeout=45, trust_env=False)
    chat = ChatOpenAI(model=selected["model"], api_key=key, base_url=source["api_base"],
        max_tokens=2000, temperature=0, max_retries=1, timeout=45,
        http_client=sync_client, http_async_client=async_client, extra_body=extra)
    documents = corpus_documents(arguments.corpus)
    reranker = evaluation_reranker(model)
    chain = build_policy_rag_chain(LocalCorpusRetriever(documents=documents), chat,
        provider_name="live-openai-compatible", model_name=selected["model"],
        reranker=reranker, relevance_threshold=calibration["relevance_threshold"])
    results = []
    public_audit = []
    validation = ValidationMetrics()
    chain_logger = logging.getLogger('app.chains.policy')
    chain_logger.handlers = [validation]
    chain_logger.propagate = False
    chain_logger.setLevel(logging.WARNING)
    logging.getLogger().handlers = [logging.NullHandler()]
    logging.disable(logging.NOTSET)
    try:
        for case in data["cases"]:
            validation.codes.clear()
            capture = PublicAuditCapture()
            started = time.perf_counter()
            item = {"id": case["id"]}
            try:
                result = await asyncio.wait_for(chain.ainvoke({"request_id": case["id"], "question": case["question"]},
                    config={'callbacks':[capture]} if arguments.public_audit else None), timeout=100)
                failures = check_result(case, result, {(document.metadata['document_id'], document.metadata['chunk_id']) for document in documents}, key)
                item.update(status=result.status, answer_mode=result.answer_mode,
                    chain_version=result.chain_version,
                    degraded_modes=result.degraded_modes,
                    validation_codes=dict(validation.codes),
                    warning_codes=[warning for warning in result.warnings if warning in {
                        'rag_structured_output_invalid', 'rag_citation_validation_failed', 'rag_insufficient_sources'}],
                    source_types=sorted({source.document_type for source in result.sources}),
                    input_tokens=result.usage.input_tokens, output_tokens=result.usage.output_tokens,
                    source_fact_coverage=[any(re.search(pattern,source.content) for source in result.sources) for pattern in case.get('required_patterns',[])],
                    failures=failures, passed=not failures)
                if arguments.public_audit:
                    public_audit.append({'id':case['id'], 'answer':result.answer, 'attempts':capture.attempts,
                        'evidence':[{'reference_id':f'R{index}', 'type':document.metadata.get('document_type'), 'text':document.page_content}
                            for index,document in enumerate(capture.documents,1)]})
                    arguments.public_audit.write_text(json.dumps(public_audit,ensure_ascii=False,indent=2).replace(key,'[REDACTED]'),encoding='utf8')
            except Exception as error:
                item.update(passed=False, failures=[type(error).__name__])
            item["elapsed_ms"] = round((time.perf_counter() - started) * 1000, 2)
            results.append(item)
            arguments.output.with_suffix('.progress.json').write_text(
                json.dumps({"incomplete": True, "cases": results}, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps({"case": item["id"], "passed": item["passed"], "failures": item['failures'],
                "status": item.get('status'), "elapsed_ms": item['elapsed_ms']}), flush=True)
    finally:
        chain_logger.removeHandler(validation)
        await async_client.aclose()
        sync_client.close()
    return {"schema": "policy-live-independent-holdout/v1", "mode": "live",
        "knowledge_version": data["knowledge_version"], "dataset_sha256": digest(arguments.holdout),
        "corpus_sha256": digest(arguments.corpus), "calibration_sha256": digest(arguments.calibration_report),
        "chat_model": selected["model"], "reranker_model": RERANK_MODEL,
        "retrieval": "local-complete-corpus-bm25", "retrieval_version":RETRIEVAL_VERSION, "production_chain": True,
        'evaluator_sha256':EVALUATOR_SHA256,
        'rerank_profile':RERANK_PROFILE,
        "relevance_threshold": calibration["relevance_threshold"], "cases": results,
        "live_generation_cases": sum(item.get("output_tokens", 0) > 0 for item in results),
        "passed": all(item["passed"] for item in results)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--calibrate-only", action="store_true")
    parser.add_argument("--fixture-calibration", action="store_true", help="Legacy fixture-pool comparison only")
    parser.add_argument("--calibration-data", type=Path, required=True)
    parser.add_argument("--calibration-report", type=Path, required=True)
    parser.add_argument("--holdout", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--reranker-cache", type=Path, required=True)
    parser.add_argument('--reranker-threads', type=int, choices=range(1,9), default=2)
    parser.add_argument("--astrbot-config", type=Path)
    parser.add_argument("--model-id", default="mimo-v2.6-flash")
    parser.add_argument("--allow-provider-origin", default="https://api.xiaomimimo.com/v1")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case-id", action="append", help="Run selected frozen cases for diagnosis")
    parser.add_argument('--public-audit', type=Path, help='Optional local public-policy answer/quote audit; never use with personal data')
    arguments = parser.parse_args()
    if not arguments.live:
        parser.error("explicit --live is required")
    data = load_cases(arguments.holdout, arguments.calibration_data / "policy_quality.jsonl")
    if arguments.case_id:
        selected = [case for case in data['cases'] if case['id'] in arguments.case_id]
        if len(selected) != len(set(arguments.case_id)):
            parser.error('unknown case id')
        data = {**data, 'cases': selected}
    logging.disable(logging.WARNING)
    model = FastEmbedCrossEncoderRerankModel(model_name=RERANK_MODEL, model_version=RERANK_VERSION,
        allow_model_download=False, cache_dir=str(arguments.reranker_cache), threads=arguments.reranker_threads,
        batch_size=2)
    if arguments.calibrate_only:
        report = evaluate_reranker_fixture(arguments.calibration_data, k=5, rerank_model=model,
            timeout_seconds=30) if arguments.fixture_calibration else calibrate_corpus(arguments, model)
    else:
        if not arguments.astrbot_config:
            parser.error("--astrbot-config is required for generation")
        report = asyncio.run(run(arguments, data, model))
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"completed": True, "passed": report.get("passed"), "cases": len(report["cases"]) if isinstance(report.get("cases"), list) else report.get("cases")}))
    return 0 if arguments.calibrate_only or report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

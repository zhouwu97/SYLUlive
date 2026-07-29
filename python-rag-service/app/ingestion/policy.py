from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Iterable

from langchain_core.documents import Document
from langchain_text_splitters import TextSplitter

from app.schemas.ingestion import KnowledgeChunk, KnowledgeChunkRequest, KnowledgeChunkResult


POLICY_CHUNKING_VERSION = "langchain-chinese-policy-v1"

_MARKDOWN_HEADING = re.compile(r"^(#{1,6})\s+(.+)$")
_POLICY_SECTION = re.compile(r"^第([〇零一二两三四五六七八九十百千万0-9]+)(章|节|编|部分)\s*(.*)$")
_POLICY_ARTICLE = re.compile(r"^第([〇零一二两三四五六七八九十百千万0-9]+)条(?:\s|　)*(.*)$")
_CHINESE_SECTION = re.compile(r"^([一二两三四五六七八九十百]+)[、.．]\s*(.+)$")
_ARABIC_ITEM = re.compile(r"^([0-9]+)[、.．]\s*(.+)$")
_PAREN_ITEM = re.compile(r"^[（(]([〇零一二两三四五六七八九十百千万0-9]+)[）)]\s*(.*)$")
_FAQ_QUESTION = re.compile(r"^(?:Q(?:uestion)?\s*[0-9]*|问(?:题)?\s*[0-9]*)[：:.．\s]", re.I)
_ALIAS_LINE = re.compile(r"^(?:[-*+]\s*)?(?:检索别名|别名|同义词|关键词)[：:]\s*(.+)$")
_TABLE_TITLE = re.compile(r"^(?:表\s*[0-9一二三四五六七八九十]+|附表|附件\s*[0-9一二三四五六七八九十]+).{0,100}$")
_SENTENCE_BOUNDARY = re.compile(r"(?<=[。！？；!?])")


@dataclass
class _Block:
    text: str
    is_table: bool = False


@dataclass
class _Unit:
    content: str
    kind: str
    section_title: str
    section_path: list[str]
    source_locator: str
    aliases: list[str] = field(default_factory=list)


class ChinesePolicyTextSplitter(TextSplitter):
    """按中文政策结构切分，并只在超长语义单元内使用完整句子重叠。"""

    def __init__(self, *, chunk_size: int = 700, chunk_overlap: int = 80) -> None:
        super().__init__(chunk_size=chunk_size, chunk_overlap=chunk_overlap)

    def split_text(self, text: str) -> list[str]:
        return [unit.content for unit in self._split_with_metadata(text)]

    def split_documents(self, documents: Iterable[Document]) -> list[Document]:
        result: list[Document] = []
        for document in documents:
            for unit in self._split_with_metadata(document.page_content):
                metadata = dict(document.metadata)
                metadata.update(
                    {
                        "chunking_version": POLICY_CHUNKING_VERSION,
                        "section_title": unit.section_title,
                        "section_path": unit.section_path,
                        "source_locator": unit.source_locator,
                        "aliases": unit.aliases,
                    }
                )
                result.append(Document(page_content=unit.content, metadata=metadata))
        return result

    def _split_with_metadata(self, text: str) -> list[_Unit]:
        parser = _PolicyParser()
        for block in _split_blocks(text):
            parser.consume(block)
        units = parser.finish()
        result: list[_Unit] = []
        for unit in units:
            result.extend(self._split_oversized(unit))
        return result

    def _split_oversized(self, unit: _Unit) -> list[_Unit]:
        soft_limit = self._chunk_size
        if len(unit.content) <= soft_limit * 2:
            return [unit]
        if unit.kind == "table":
            return self._split_table(unit)

        pieces = [piece for piece in _SENTENCE_BOUNDARY.split(unit.content) if piece]
        if len(pieces) <= 1:
            pieces = [
                unit.content[start : start + soft_limit]
                for start in range(0, len(unit.content), max(1, soft_limit - self._chunk_overlap))
            ]
            return self._number_units(unit, pieces)

        chunks: list[str] = []
        current: list[str] = []
        current_size = 0
        for piece in pieces:
            if current and current_size + len(piece) > soft_limit:
                chunks.append("".join(current).strip())
                current = self._overlap_sentences(current)
                current_size = sum(len(value) for value in current)
            if len(piece) > soft_limit and not current:
                chunks.extend(
                    piece[start : start + soft_limit]
                    for start in range(0, len(piece), max(1, soft_limit - self._chunk_overlap))
                )
                continue
            current.append(piece)
            current_size += len(piece)
        if current:
            chunks.append("".join(current).strip())
        return self._number_units(unit, [chunk for chunk in chunks if chunk])

    def _overlap_sentences(self, sentences: list[str]) -> list[str]:
        overlap: list[str] = []
        size = 0
        for sentence in reversed(sentences):
            if overlap and size + len(sentence) > self._chunk_overlap:
                break
            overlap.insert(0, sentence)
            size += len(sentence)
        return overlap

    def _split_table(self, unit: _Unit) -> list[_Unit]:
        lines = unit.content.splitlines()
        header_count = 2 if len(lines) >= 2 and _is_table_line(lines[1]) else 0
        headers = lines[:header_count]
        rows = lines[header_count:]
        chunks: list[str] = []
        current = list(headers)
        for row in rows:
            candidate = "\n".join([*current, row]).strip()
            if len(candidate) > self._chunk_size and len(current) > header_count:
                chunks.append("\n".join(current).strip())
                current = [*headers, row]
            else:
                current.append(row)
        if current:
            chunks.append("\n".join(current).strip())
        return self._number_units(unit, [chunk for chunk in chunks if chunk])

    @staticmethod
    def _number_units(unit: _Unit, contents: list[str]) -> list[_Unit]:
        if len(contents) <= 1:
            return [unit]
        return [
            _Unit(
                content=content,
                kind=unit.kind,
                section_title=unit.section_title,
                section_path=list(unit.section_path),
                source_locator=f"{unit.source_locator}（{index + 1}/{len(contents)}）",
                aliases=list(unit.aliases),
            )
            for index, content in enumerate(contents)
        ]


class _PolicyParser:
    def __init__(self) -> None:
        self.heading_path: list[str] = []
        self.structural_path: list[str] = []
        self.section_title = ""
        self.locator_base = ""
        self.section_aliases: list[str] = []
        self.pending_headers: list[str] = []
        self.current: _Unit | None = None
        self.units: list[_Unit] = []

    def consume(self, block: _Block) -> None:
        text = block.text.strip()
        if not text:
            return
        if match := _MARKDOWN_HEADING.match(text):
            self._flush()
            level = len(match.group(1))
            title = match.group(2).strip()
            self.heading_path = self.heading_path[: level - 1]
            self.heading_path.append(title)
            self.structural_path = list(self.heading_path)
            self.section_title = title
            self.locator_base = title
            self.section_aliases = []
            self.pending_headers.append(text)
            return
        if match := _POLICY_SECTION.match(text):
            self._flush()
            label = f"第{match.group(1)}{match.group(2)}"
            title = f"{label} {match.group(3)}".strip()
            self.section_title = title
            self.locator_base = label
            self.structural_path = [*self.heading_path, title]
            self.section_aliases = []
            self.pending_headers.append(text)
            return
        if match := _CHINESE_SECTION.match(text):
            self._flush()
            self.section_title = text
            self.locator_base = f"第{match.group(1)}部分"
            self.structural_path = [*self.heading_path, text]
            self.section_aliases = []
            self.pending_headers.append(text)
            return
        if match := _ALIAS_LINE.match(text):
            self.section_aliases = _merge_aliases(self.section_aliases, _parse_aliases(match.group(1)))
            if self.current is not None:
                self.current.aliases = _merge_aliases(self.current.aliases, self.section_aliases)
                self.current.content = f"{self.current.content}\n{text}".strip()
            else:
                self.pending_headers.append(text)
            return
        if match := _POLICY_ARTICLE.match(text):
            self._flush()
            label = f"第{match.group(1)}条"
            self._start("article", text, label, [*self.structural_path, label])
            return
        if match := _ARABIC_ITEM.match(text):
            self._flush()
            label = f"第{match.group(1)}项"
            locator = f"{self.locator_base}{label}" if self.locator_base else label
            self._start("item", text, locator, [*self.structural_path, label])
            return
        if match := _PAREN_ITEM.match(text):
            if self.current is not None and self.current.kind == "article":
                self._append(text)
                return
            self._flush()
            label = f"第{match.group(1)}项"
            locator = f"{self.locator_base}{label}" if self.locator_base else label
            self._start("item", text, locator, [*self.structural_path, label])
            return
        if block.is_table:
            if self.current is not None and self.current.kind == "table":
                self._append(text)
            else:
                self._flush()
                locator = f"{self.locator_base}表格" if self.locator_base else "表格"
                self._start("table", text, locator, self.structural_path)
            return
        if _is_table_title(text):
            self._flush()
            self._start("table", text, text[:500], self.structural_path)
            return
        if _FAQ_QUESTION.match(text) or _looks_like_question(text):
            self._flush()
            locator = text.splitlines()[0][:100]
            self._start("faq", text, locator, [*self.structural_path, locator])
            return
        if self.current is None:
            self._start("plain", text, self.locator_base or "正文", self.structural_path)
        else:
            self._append(text)

    def finish(self) -> list[_Unit]:
        self._flush()
        if self.pending_headers:
            self._start("plain", "", self.locator_base or "正文", self.structural_path)
            self._flush()
        return self.units

    def _start(self, kind: str, text: str, locator: str, path: list[str]) -> None:
        content = "\n".join([*self.pending_headers, text]).strip()
        self.pending_headers = []
        self.current = _Unit(
            content=content,
            kind=kind,
            section_title=self.section_title,
            section_path=_compact(path),
            source_locator=locator or "正文",
            aliases=list(self.section_aliases),
        )

    def _append(self, text: str) -> None:
        if self.current is None:
            return
        self.current.content = f"{self.current.content}\n{text}".strip()

    def _flush(self) -> None:
        if self.current is not None and self.current.content.strip():
            self.current.aliases = _merge_aliases(
                self.current.aliases,
                _aliases_from_content(self.current.content),
            )
            self.units.append(self.current)
        self.current = None


def chunk_policy_document(request: KnowledgeChunkRequest) -> KnowledgeChunkResult:
    base_metadata = {
        "document_id": request.document_id,
        "document_title": request.title,
        "document_type": request.document_type,
        "department": request.department,
        "version_status": request.version_status,
        "effective_from": request.effective_from.isoformat() if request.effective_from else None,
        "effective_to": request.effective_to.isoformat() if request.effective_to else None,
        "source_document_locator": request.source_locator,
        "aliases": _normalize_aliases(request.aliases),
    }
    source = Document(page_content=request.content, metadata=base_metadata)
    splitter = ChinesePolicyTextSplitter(
        chunk_size=request.chunk_size,
        chunk_overlap=request.chunk_overlap,
    )
    documents = splitter.split_documents([source])
    chunks: list[KnowledgeChunk] = []
    for index, document in enumerate(documents):
        content = document.page_content.strip()
        if not content:
            continue
        metadata = dict(document.metadata)
        metadata["aliases"] = _merge_aliases(request.aliases, metadata.get("aliases", []))
        embedding_text = _build_embedding_text(metadata, content)
        chunks.append(
            KnowledgeChunk(
                index=index,
                content=content,
                content_hash=hashlib.sha256(content.encode("utf-8")).hexdigest(),
                embedding_text=embedding_text,
                section_title=str(metadata.get("section_title", "")),
                source_locator=str(metadata.get("source_locator", "正文")),
                metadata=metadata,
            )
        )
    if not chunks:
        raise ValueError("knowledge document has no chunkable content")
    return KnowledgeChunkResult(
        document_id=request.document_id,
        chunking_version=POLICY_CHUNKING_VERSION,
        chunks=chunks,
    )


def _build_embedding_text(metadata: dict[str, object], content: str) -> str:
    section_path = metadata.get("section_path", [])
    aliases = metadata.get("aliases", [])
    parts: list[object] = [
        metadata.get("document_title", ""),
        metadata.get("document_type", ""),
        metadata.get("department", ""),
        " > ".join(str(item) for item in section_path) if isinstance(section_path, list) else "",
        " ".join(str(item) for item in aliases) if isinstance(aliases, list) else "",
        content,
    ]
    return "\n".join(str(part).strip() for part in parts if str(part).strip())


def _split_blocks(text: str) -> list[_Block]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    blocks: list[_Block] = []
    buffer: list[str] = []
    buffer_is_table = False

    def flush() -> None:
        nonlocal buffer, buffer_is_table
        value = "\n".join(buffer).strip()
        if value:
            blocks.append(_Block(value, buffer_is_table))
        buffer = []
        buffer_is_table = False

    for raw_line in normalized.split("\n"):
        line = raw_line.strip()
        if not line:
            flush()
            continue
        is_table = _is_table_line(line)
        if buffer and (is_table != buffer_is_table or (not is_table and _is_boundary(line))):
            flush()
        buffer_is_table = is_table
        buffer.append(line)
    flush()
    return blocks


def _is_boundary(line: str) -> bool:
    return bool(
        _MARKDOWN_HEADING.match(line)
        or _POLICY_SECTION.match(line)
        or _POLICY_ARTICLE.match(line)
        or _CHINESE_SECTION.match(line)
        or _ARABIC_ITEM.match(line)
        or _PAREN_ITEM.match(line)
        or _FAQ_QUESTION.match(line)
        or _ALIAS_LINE.match(line)
        or _is_table_title(line)
        or _looks_like_question(line)
    )


def _is_table_line(line: str) -> bool:
    stripped = line.strip()
    return stripped.count("|") >= 2 and (stripped.startswith("|") or stripped.endswith("|"))


def _is_table_title(line: str) -> bool:
    return bool(_TABLE_TITLE.match(line.strip()))


def _looks_like_question(text: str) -> bool:
    first_line = text.splitlines()[0].strip()
    return len(first_line) <= 100 and first_line.endswith(("？", "?"))


def _aliases_from_content(content: str) -> list[str]:
    aliases: list[str] = []
    for line in content.splitlines():
        match = _ALIAS_LINE.match(line.strip())
        if match:
            aliases = _merge_aliases(aliases, _parse_aliases(match.group(1)))
    return aliases


def _parse_aliases(value: str) -> list[str]:
    return _normalize_aliases(re.split(r"[、,，;；/|\s]+", value))


def _normalize_aliases(values: Iterable[object]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        alias = str(value).strip()
        key = alias.casefold()
        if alias and len(alias) <= 100 and key not in seen:
            seen.add(key)
            result.append(alias)
    return result[:100]


def _merge_aliases(left: Iterable[object], right: Iterable[object]) -> list[str]:
    return _normalize_aliases([*left, *right])


def _compact(values: Iterable[str]) -> list[str]:
    result: list[str] = []
    for value in values:
        value = value.strip()
        if value and (not result or result[-1] != value):
            result.append(value)
    return result

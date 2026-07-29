from __future__ import annotations

from datetime import datetime
from typing import Any

from pydantic import Field, model_validator

from app.schemas.policy import StrictSchema


class KnowledgeChunkRequest(StrictSchema):
    document_id: int = Field(gt=0)
    title: str = Field(min_length=1, max_length=300)
    content: str = Field(min_length=1, max_length=2 * 1024 * 1024)
    source_locator: str = Field(default="", max_length=2_000)
    document_type: str = Field(default="", max_length=100)
    department: str = Field(default="", max_length=300)
    version_status: str = Field(min_length=1, max_length=50)
    effective_from: datetime | None = None
    effective_to: datetime | None = None
    aliases: list[str] = Field(default_factory=list, max_length=100)
    chunk_size: int = Field(default=700, ge=100, le=4_000)
    chunk_overlap: int = Field(default=80, ge=0, le=1_000)

    @model_validator(mode="after")
    def validate_chunk_limits(self) -> "KnowledgeChunkRequest":
        if self.chunk_overlap >= self.chunk_size:
            raise ValueError("chunk_overlap must be smaller than chunk_size")
        return self


class KnowledgeChunk(StrictSchema):
    index: int = Field(ge=0)
    content: str = Field(min_length=1)
    content_hash: str = Field(min_length=64, max_length=64)
    embedding_text: str = Field(min_length=1)
    section_title: str = Field(default="", max_length=500)
    source_locator: str = Field(min_length=1, max_length=500)
    metadata: dict[str, Any]


class KnowledgeChunkResult(StrictSchema):
    document_id: int = Field(gt=0)
    chunking_version: str = Field(min_length=1, max_length=100)
    chunks: list[KnowledgeChunk] = Field(min_length=1, max_length=10_000)

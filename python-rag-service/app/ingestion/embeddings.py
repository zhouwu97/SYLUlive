from __future__ import annotations

from collections.abc import Iterable

from langchain_core.embeddings import Embeddings


class FastEmbedLangChainEmbeddings(Embeddings):
    """将 FastEmbed 纳入 LangChain Embeddings 契约，并严格校验真实维度。"""

    def __init__(
        self,
        client: object,
        *,
        model_name: str,
        model_version: str,
        expected_dimensions: int | None = None,
    ) -> None:
        if not model_name.strip() or not model_version.strip():
            raise ValueError("embedding model identity is required")
        if expected_dimensions is not None and expected_dimensions <= 0:
            raise ValueError("expected embedding dimensions must be positive")
        self._client = client
        self.model_name = model_name.strip()
        self.model_version = model_version.strip()
        self.expected_dimensions = expected_dimensions
        self._observed_dimensions: int | None = None

    @property
    def dimensions(self) -> int | None:
        return self._observed_dimensions or self.expected_dimensions

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        raw_vectors = self._client.embed(texts)
        return self._validate_vectors(raw_vectors, len(texts))

    def embed_query(self, text: str) -> list[float]:
        vectors = self.embed_documents([text])
        return vectors[0]

    def _validate_vectors(
        self,
        raw_vectors: Iterable[Iterable[float]],
        expected_count: int,
    ) -> list[list[float]]:
        vectors = [[float(value) for value in vector] for vector in raw_vectors]
        if len(vectors) != expected_count:
            raise ValueError("embedding provider returned an unexpected vector count")
        dimensions = len(vectors[0]) if vectors else 0
        if dimensions <= 0 or any(len(vector) != dimensions for vector in vectors):
            raise ValueError("embedding provider returned inconsistent dimensions")
        if self.expected_dimensions is not None and dimensions != self.expected_dimensions:
            raise ValueError("embedding dimensions do not match configured model contract")
        if self._observed_dimensions is not None and dimensions != self._observed_dimensions:
            raise ValueError("embedding dimensions changed during process lifetime")
        self._observed_dimensions = dimensions
        return vectors

"""Deployment-reviewed public pictures only; no model-supplied path or URL."""

import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

from .client import IntegrationProblem


class ApprovedMedia:
    def __init__(self, directory):
        self.directory = Path(directory)

    def entries(self):
        manifest = self.directory / "manifest.json"
        if not manifest.exists():
            return []
        if (
            self.directory.is_symlink()
            or manifest.is_symlink()
            or manifest.stat().st_size > 100_000
        ):
            raise IntegrationProblem("invalid_media_catalog")
        try:
            body = json.loads(manifest.read_text(encoding="utf-8"))
            rows = body["images"]
            if (
                body.get("version") != 1
                or not isinstance(rows, list)
                or len(rows) > 100
            ):
                raise ValueError()
            result, seen = [], set()
            for row in rows:
                if not isinstance(row, dict):
                    raise TypeError()
                if row.get("approved") is not True or row.get("public") is not True:
                    continue
                ident, name = row["id"], row["filename"]
                if (
                    not isinstance(ident, str)
                    or not re.fullmatch(r"[a-f0-9]{16}", ident)
                    or ident in seen
                    or not isinstance(name, str)
                    or not re.fullmatch(r"[a-zA-Z0-9_-]+\.(?:png|jpg|jpeg|gif)", name)
                    or not isinstance(row.get("sha256"), str)
                    or not re.fullmatch(r"[a-f0-9]{64}", row["sha256"])
                    or not isinstance(row.get("license"), str)
                    or not 1 <= len(row["license"]) <= 60
                    or not isinstance(row.get("source_url"), str)
                    or not 1 <= len(row["source_url"]) <= 300
                ):
                    raise ValueError()
                source = urlsplit(row["source_url"])
                if (
                    source.scheme != "https"
                    or not source.hostname
                    or source.username
                    or source.password
                    or source.query
                    or source.fragment
                ):
                    raise ValueError()
                seen.add(ident)
                result.append(row)
            return result
        except (ValueError, KeyError, TypeError, OSError):
            raise IntegrationProblem("invalid_media_catalog") from None

    def catalogue(self):
        return [
            {
                "image_id": r["id"],
                "description": str(r.get("caption", ""))[:200],
                "license": str(r["license"])[:60],
            }
            for r in self.entries()
        ]

    def read(self, ident):
        row = next((r for r in self.entries() if r["id"] == ident), None)
        if row is None:
            raise IntegrationProblem("media_not_approved")
        path = self.directory / row["filename"]
        if path.is_symlink() or path.resolve().parent != self.directory.resolve():
            raise IntegrationProblem("media_not_approved")
        try:
            if not 0 < path.stat().st_size <= 4 * 1024 * 1024:
                raise ValueError()
            with path.open("rb") as stream:
                data = stream.read(4 * 1024 * 1024 + 1)
            if (
                len(data) > 4 * 1024 * 1024
                or hashlib.sha256(data).hexdigest() != row["sha256"]
            ):
                raise ValueError()
            mime = (
                "image/png"
                if data.startswith(b"\x89PNG\r\n\x1a\n")
                else "image/jpeg"
                if data.startswith(b"\xff\xd8\xff")
                else "image/gif"
                if data[:6] in (b"GIF87a", b"GIF89a")
                else ""
            )
            if not mime:
                raise ValueError()
            return {
                "bytes": data,
                "mime": mime,
                "filename": row["filename"],
                "source_url": row["source_url"],
                "license": row["license"],
            }
        except (OSError, ValueError):
            raise IntegrationProblem("media_changed_or_invalid") from None

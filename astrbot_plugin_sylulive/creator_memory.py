"""Creator-private RAG. Never consumed by the public community agent."""

import hashlib
import json
import re
import sqlite3
import time

import keyring
from cryptography.fernet import Fernet, InvalidToken

from .public_agent import terms


def redact(text):
    # 不持久化常见凭据；不是对任意自由文本的完整敏感信息识别。
    text = re.sub(r"(?i)(?:bearer\s+|(?:password|passwd|cookie|token|api[_ -]?key|密码|口令)\s*[:=：]\s*)\S+", "[凭据已省略]", str(text))
    return re.sub(r"\b(?:sk-|sa_|sr_|sd_)[A-Za-z0-9_-]{6,}\b", "[凭据已省略]", text)[:3500]


def vault_cipher(identity):
    secure = type(keyring.get_keyring()).__module__ in {
        "keyring.backends.Windows", "keyring.backends.macOS", "keyring.backends.SecretService", "keyring.backends.kwallet",
    }
    if not secure:
        return None
    try:
        key = keyring.get_password("sylulive-creator-memory", identity)
        if key is None:
            key = Fernet.generate_key().decode()
            keyring.set_password("sylulive-creator-memory", identity, key)
        return Fernet(key.encode())
    except Exception:
        return None


class CreatorMemory:
    def __init__(self, path, identity, *, cipher=None, clock=time.time):
        self.clock = clock
        self.cipher = cipher or vault_cipher(identity)
        self.persistent = self.cipher is not None
        # 无系统安全密钥时不把私人正文回退到明文磁盘。
        self.cipher = self.cipher or Fernet(Fernet.generate_key())
        self.db = sqlite3.connect(path if self.persistent else ":memory:")
        self.db.execute("PRAGMA secure_delete=ON")
        self.db.execute("CREATE TABLE IF NOT EXISTS turns (id TEXT PRIMARY KEY, body BLOB NOT NULL, created REAL NOT NULL)")
        self.prune()
        self.generation = 0

    def prune(self):
        with self.db:
            self.db.execute("DELETE FROM turns WHERE created <= ?", (self.clock() - 180 * 86400,))
            self.db.execute("DELETE FROM turns WHERE id NOT IN (SELECT id FROM turns ORDER BY created DESC, id DESC LIMIT 2000)")

    def put(self, message_id, user, assistant, *, is_creator_private=False):
        if not is_creator_private or not message_id or not user or str(user).lstrip().startswith("/"):
            return False
        value = {"user": redact(user), "assistant": redact(assistant), "recorded_at": self.clock()}
        raw = self.cipher.encrypt(json.dumps(value, ensure_ascii=False).encode())
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO turns VALUES (?, ?, ?)",
                            (hashlib.sha256(str(message_id).encode()).hexdigest(), raw, self.clock()))
        self.prune()
        return True

    def recall(self, query, *, is_creator_private=False):
        if not is_creator_private:
            return []
        self.prune()
        query_terms = terms(query)
        ranked = []
        for raw, in self.db.execute("SELECT body FROM turns ORDER BY created DESC"):
            try:
                value = json.loads(self.cipher.decrypt(raw))
            except (InvalidToken, ValueError, TypeError):
                continue
            matches = sum((terms(value["user"] + " " + value["assistant"]) & query_terms).values())
            if matches:
                ranked.append((matches, value))
        ranked.sort(key=lambda pair: pair[0], reverse=True)
        return [value for _, value in ranked[:3]]

    def clear(self):
        self.generation += 1
        with self.db:
            self.db.execute("DELETE FROM turns")

    def close(self):
        self.db.close()

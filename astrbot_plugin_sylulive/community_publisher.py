"""Only a managed bot with newly consented scope can publish. No private-memory input."""

import hashlib
import json
import uuid

from .client import IntegrationProblem


class CommunityPublisher:
    def __init__(self, agent, client):
        self.agent, self.client = agent, client
        self.db = agent.memory.db
        self.db.execute("CREATE TABLE IF NOT EXISTS outbox (post_id INTEGER PRIMARY KEY, operation TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL)")
        self.db.commit()

    def authorized(self):
        return (self.agent.config.get("community_auto_comment", False) is True
                and "community:bot_reply" in (self.client.tokens or {}).get("scope", "").split())

    async def publish(self, ident, content, sticker, stamp, allowed_stickers):
        self.agent.check(stamp)
        if not self.agent.config.get("community_auto_comment", False):
            raise IntegrationProblem("auto_comment_disabled")
        if "community:bot_reply" not in (self.client.tokens or {}).get("scope", "").split():
            raise IntegrationProblem("bot_reply_consent_required")
        if not isinstance(content, str) or not isinstance(sticker, str) or len(content) > 300 or (not content.strip() and not sticker):
            raise IntegrationProblem("invalid_bot_reply")
        if sticker and sticker not in allowed_stickers:
            raise IntegrationProblem("invalid_sticker")
        # 模型无权覆盖来源版本/发布账号；发布前固定从当前公共读取构造。
        post = await self.agent.read_post(ident, stamp)
        operation = str(uuid.uuid4())
        payload = {"operation_id": operation, "kind": "reply", "post_id": ident,
                   "source_version": post["source_version"], "content": content.strip(), "sticker_id": sticker}
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        self.agent.check(stamp)
        with self.db:
            # 网络发送前预留；进程崩溃/超时也不盲目重发，清空阅读记忆不清发言账本。
            cursor = self.db.execute("INSERT OR IGNORE INTO outbox VALUES (?, ?, ?, ?)", (ident, operation, digest, "uncertain"))
        if cursor.rowcount != 1:
            raise IntegrationProblem("bot_post_already_attempted")
        try:
            result = await self.client.call("POST", "/bot/replies", payload=payload)
        except IntegrationProblem:
            # 即使响应丢失，服务端可能已经发布；保留 uncertain，交由本人核对。
            raise IntegrationProblem("bot_publish_unconfirmed") from None
        state = "published" if result.get("state") == "published" and type(result.get("reply_id")) is int else "uncertain"
        with self.db:
            self.db.execute("UPDATE outbox SET state=? WHERE post_id=?", (state, ident))
        return {"state": state, "reply_id": result.get("reply_id") if state == "published" else None}

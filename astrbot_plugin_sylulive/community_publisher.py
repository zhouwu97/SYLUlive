"""Only a managed bot with newly consented scope can publish. No private-memory input."""

import hashlib
import json
import time
import uuid

from .client import IntegrationProblem


class CommunityPublisher:
    def __init__(self, agent, client, *, media=None, clock=time.time):
        self.agent, self.client = agent, client
        self.media, self.clock = media, clock
        self.runtime = None
        self.controls = None
        self.db = agent.memory.db
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS outbox (post_id INTEGER PRIMARY KEY, operation TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL)"
        )
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS post_outbox (operation TEXT PRIMARY KEY, digest TEXT NOT NULL, created REAL NOT NULL, state TEXT NOT NULL, post_id INTEGER)"
        )
        # A separate table keeps legacy once-per-post attempts intact while allowing
        # one version-checked response to each genuinely new human comment.
        self.db.execute(
            "CREATE TABLE IF NOT EXISTS reply_outbox (reply_id INTEGER PRIMARY KEY, post_id INTEGER NOT NULL, operation TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL)"
        )
        self.db.execute("CREATE TABLE IF NOT EXISTS conversation_cursor (id INTEGER PRIMARY KEY CHECK (id=1), position INTEGER NOT NULL)")
        self.db.execute("INSERT OR IGNORE INTO conversation_cursor VALUES (1,0)")
        self.db.execute("CREATE TABLE IF NOT EXISTS published_sources (kind TEXT NOT NULL, result_id INTEGER NOT NULL, post_id INTEGER NOT NULL, target_id INTEGER NOT NULL, PRIMARY KEY(kind,result_id))")
        self.db.commit()

    def remember_published(self, kind, result, post_id, target_id=0):
        ident = result.get('reply_id' if kind == 'reply' else 'post_id')
        if result.get('state') == 'published' and type(ident) is int and ident > 0:
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO published_sources VALUES (?,?,?,?)", (kind, ident, post_id, target_id))

    def target_attempted(self, reply_id):
        return self.db.execute("SELECT 1 FROM reply_outbox WHERE reply_id=?", (reply_id,)).fetchone() is not None

    def conversation_post_ids(self):
        # Only previously published public conversations, never private activity or guessed IDs.
        own = [r[0] for r in self.db.execute("SELECT post_id FROM post_outbox WHERE state='published' AND post_id IS NOT NULL ORDER BY created DESC LIMIT 10")]
        followed = [r[0] for r in self.db.execute("SELECT post_id FROM reply_outbox WHERE state='published' ORDER BY rowid DESC LIMIT 10")]
        roots = [r[0] for r in self.db.execute("SELECT post_id FROM outbox WHERE state='published' ORDER BY rowid DESC LIMIT 10")]
        pool = list(dict.fromkeys(own + followed + roots))
        if not pool:
            return []
        position = self.db.execute("SELECT position FROM conversation_cursor WHERE id=1").fetchone()[0] % len(pool)
        selected = [pool[(position + offset) % len(pool)] for offset in range(min(2, len(pool)))]
        # Advance even if the selected public sources were deleted/denied; otherwise
        # two unavailable old posts could permanently hide every other conversation.
        with self.db:
            self.db.execute("UPDATE conversation_cursor SET position=? WHERE id=1", ((position + len(selected)) % len(pool),))
        return selected

    def authorized(self):
        return (
            (self.controls is None or (self.controls.get("auto_reply_server_enabled") is True
             and self.controls.get("auto_reply_authorized") is True
             and any(self.controls["bot"]["policy"].get(key) is True for key in ("reply_enabled", "sticker_enabled"))))
            and
            self.agent.config.get("community_auto_comment", False) is True
            and "community:bot_reply"
            in (self.client.tokens or {}).get("scope", "").split()
        )

    async def publish(
        self, ident, content, sticker, stamp, allowed_stickers, *, expected_version=None,
        reply_to_reply_id=0, expected_reply=None
    ):
        self.agent.check(stamp)
        if not self.agent.config.get("community_auto_comment", False):
            raise IntegrationProblem("auto_comment_disabled")
        if (
            "community:bot_reply"
            not in (self.client.tokens or {}).get("scope", "").split()
        ):
            raise IntegrationProblem("bot_reply_consent_required")
        if (
            not isinstance(content, str)
            or not isinstance(sticker, str)
            or len(content) > 300
            or (not content.strip() and not sticker)
        ):
            raise IntegrationProblem("invalid_bot_reply")
        if sticker and sticker not in allowed_stickers:
            raise IntegrationProblem("invalid_sticker")
        if type(reply_to_reply_id) is not int or reply_to_reply_id < 0:
            raise IntegrationProblem("invalid_bot_reply")
        target = None
        if reply_to_reply_id:
            if not isinstance(expected_reply, dict) or expected_reply.get("reply_id") != reply_to_reply_id or expected_reply.get("post_id") != ident or expected_reply.get("status") != "normal":
                raise IntegrationProblem("read_reply_first")
            from .community_view import data_object, presentation
            raw = await self.agent.public_call(f"/api/integrations/v1/public/community/replies/{reply_to_reply_id}/context")
            self.agent.check(stamp)
            target = presentation(data_object(raw).get("reply"), reply=True, post_id=ident)
            if target["reply_id"] != reply_to_reply_id or target["status"] != "normal":
                raise IntegrationProblem("source_unavailable")
            if target["source_version"] != expected_reply.get("source_version"):
                raise IntegrationProblem("source_changed")
            if isinstance(target.get("author", {}).get("ai_bot"), dict):
                raise IntegrationProblem("bot_reply_target_not_human")
            if self.target_attempted(reply_to_reply_id):
                raise IntegrationProblem("bot_reply_already_attempted")
        # 模型无权覆盖来源版本/发布账号；发布前固定从当前公共读取构造。
        post = await self.agent.read_post(ident, stamp, for_chat=target is None)
        if target is None and isinstance(post.get("author", {}).get("ai_bot"), dict):
            raise IntegrationProblem("bot_reply_target_not_human")
        if expected_version is not None and post["source_version"] != expected_version:
            raise IntegrationProblem("source_changed")
        operation = str(uuid.uuid4())
        payload = {
            "operation_id": operation,
            "kind": "reply",
            "post_id": ident,
            "source_version": post["source_version"],
            "content": content.strip(),
            "sticker_id": sticker,
        }
        if target is not None:
            payload.update(reply_to_reply_id=reply_to_reply_id, reply_source_version=target["source_version"])
        if self.runtime is not None:
            payload.update(self.runtime())
        digest = hashlib.sha256(
            json.dumps(payload, sort_keys=True).encode()
        ).hexdigest()
        self.agent.check(stamp)
        with self.db:
            # 网络发送前预留；进程崩溃/超时也不盲目重发，清空阅读记忆不清发言账本。
            if target is not None:
                cursor = self.db.execute(
                    "INSERT OR IGNORE INTO reply_outbox VALUES (?, ?, ?, ?, ?)",
                    (reply_to_reply_id, ident, operation, digest, "uncertain"),
                )
            else:
                cursor = self.db.execute(
                    "INSERT OR IGNORE INTO outbox VALUES (?, ?, ?, ?)",
                    (ident, operation, digest, "uncertain"),
                )
        if cursor.rowcount != 1:
            raise IntegrationProblem("bot_reply_already_attempted" if target is not None else "bot_post_already_attempted")
        try:
            result = await self.client.call("POST", "/bot/replies", payload=payload)
        except IntegrationProblem:
            # 即使响应丢失，服务端可能已经发布；保留 uncertain，交由本人核对。
            raise IntegrationProblem("bot_publish_unconfirmed") from None
        state = (
            "published"
            if result.get("state") == "published"
            and type(result.get("reply_id")) is int
            and result["reply_id"] > 0
            else "uncertain"
        )
        with self.db:
            if target is not None:
                self.db.execute("UPDATE reply_outbox SET state=? WHERE reply_id=?", (state, reply_to_reply_id))
            else:
                self.db.execute("UPDATE outbox SET state=? WHERE post_id=?", (state, ident))
        self.remember_published('reply', result, ident, reply_to_reply_id)
        return {
            "state": state,
            "reply_id": result.get("reply_id") if state == "published" else None,
        }

    def posts_authorized(self):
        return (
            (self.controls is None or (self.controls.get("auto_post_server_enabled") is True
             and self.controls.get("auto_post_authorized") is True
             and self.controls["bot"]["policy"].get("post_enabled") is True))
            and
            self.agent.config.get("community_auto_post", False) is True
            and "community:bot_post"
            in (self.client.tokens or {}).get("scope", "").split()
        )

    async def post_capabilities(self):
        self.capability_error = ""
        if not self.posts_authorized():
            return {"auto_post": False, "media_upload": False}
        if self.db.execute(
            "SELECT 1 FROM post_outbox WHERE created>? LIMIT 1", (self.clock() - 86400,)
        ).fetchone():
            return {"auto_post": False, "media_upload": False}
        try:
            result = await self.client.call("GET", "/bot/capabilities")
            capabilities = {
                key: result.get(key) is True for key in ("auto_post", "media_upload")
            }
            if self.media_attribution_links_blocked():
                capabilities["media_upload"] = False
            return capabilities
        except IntegrationProblem as error:
            self.capability_error = error.code
            # 旧服务器、暂停或撤权只停止写入能力，公开匿名浏览仍能继续。
            return {"auto_post": False, "media_upload": False}

    def media_attribution_links_blocked(self):
        return self.controls is not None and self.controls.get("bot", {}).get("policy", {}).get("block_links") is True

    async def publish_post(self, title, content, section, sources, image_ids, stamp):
        self.agent.check(stamp)
        if not self.posts_authorized():
            raise IntegrationProblem("bot_post_consent_required")
        # 已审核素材必须公开署名。规则禁止链接时，先拒绝配图，不上传也不占用当日发帖账本。
        if image_ids and self.media_attribution_links_blocked():
            raise IntegrationProblem("bot_media_attribution_links_blocked")
        from .public_agent import BrowsePolicy

        policy = BrowsePolicy(self.agent.config)
        if section not in policy.allowed or section in policy.denied:
            raise IntegrationProblem("public_scope_refused")
        if (
            not isinstance(title, str)
            or not isinstance(content, str)
            or not content.strip()
            or len(content) > 1500
            or len(title) > 120
            or not isinstance(sources, dict)
            or not 1 <= len(sources) <= 3
            or not isinstance(image_ids, list)
            or len(image_ids) > 3
            or any(not isinstance(x, str) for x in image_ids)
            or len(set(image_ids)) != len(image_ids)
        ):
            raise IntegrationProblem("invalid_bot_post")
        approved = [self.media.read(ident) for ident in image_ids] if self.media else []
        if image_ids and not self.media:
            raise IntegrationProblem("media_not_approved")
        if approved:
            credits = dict.fromkeys(
                f"{r['source_url']}（{r['license']}）" for r in approved
            )
            content = content.strip() + "\n\n配图来源：" + "；".join(credits)
            if len(content) > 1500:
                raise IntegrationProblem("invalid_bot_post")
        refs = []
        for ident, version in sources.items():
            post = await self.agent.read_post(ident, stamp)
            if post["source_version"] != version:
                raise IntegrationProblem("source_changed")
            refs.append({"post_id": ident, "source_version": version})
        operation = str(uuid.uuid4())
        digest = hashlib.sha256(
            json.dumps(
                [title, content, section, refs, image_ids],
                sort_keys=True,
                ensure_ascii=False,
            ).encode()
        ).hexdigest()
        self.agent.check(stamp)
        with self.db:
            if self.db.execute(
                "SELECT 1 FROM post_outbox WHERE created>? LIMIT 1",
                (self.clock() - 86400,),
            ).fetchone():
                raise IntegrationProblem("bot_post_daily_quota")
            # 上传也属于外部写入；任何中断或不明结果保留账本，不自动重新上传/发帖。
            self.db.execute(
                "INSERT INTO post_outbox VALUES (?,?,?,?,NULL)",
                (operation, digest, self.clock(), "uncertain"),
            )
        file_ids = []
        try:
            for row in approved:
                self.agent.check(stamp)
                result = await self.client.call(
                    "POST",
                    "/bot/media",
                    files={"file": (row["filename"], row["bytes"], row["mime"])},
                )
                self.agent.check(stamp)
                if type(result.get("file_id")) is not int or result["file_id"] <= 0:
                    raise IntegrationProblem("invalid_response")
                file_ids.append(result["file_id"])
            self.agent.check(stamp)
            result = await self.client.call(
                "POST",
                "/bot/posts",
                payload={
                    "operation_id": operation,
                    "kind": "post",
                    "title": title.strip(),
                    "content": content.strip(),
                    "post_type": section,
                    "sources": refs,
                    "image_file_ids": file_ids,
                    **(self.runtime() if self.runtime is not None else {}),
                },
            )
        except IntegrationProblem:
            raise IntegrationProblem("bot_publish_unconfirmed") from None
        state = (
            "published"
            if result.get("state") == "published"
            and type(result.get("post_id")) is int
            and result["post_id"] > 0
            else "uncertain"
        )
        with self.db:
            self.db.execute(
                "UPDATE post_outbox SET state=?,post_id=? WHERE operation=?",
                (
                    state,
                    result.get("post_id") if state == "published" else None,
                    operation,
                ),
            )
        return {
            "state": state,
            "post_id": result.get("post_id") if state == "published" else None,
            "image_count": len(file_ids),
        }

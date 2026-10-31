"""私有结果先投递私聊；只保存审核元数据，不把正文交给群模型。"""

import asyncio
import hashlib
import json
import re
import secrets
import time

from .client import IntegrationProblem


class ReviewProblem(Exception):
    pass


class PrivateReview:
    def __init__(self, plugin, prefs, send):
        self.plugin, self.prefs, self.send = plugin, prefs, send
        self.lock = asyncio.Lock()
        self.epoch = secrets.token_hex(16)

    def private_umo(self, sender):
        return f"{self.plugin.platform}:FriendMessage:{sender}"

    def is_admin(self, event):
        config = self.plugin.context.get_config(umo=event.unified_msg_origin)
        return str(event.get_sender_id()) in {
            str(v) for v in config.get("admins_id", [])
        }

    def authorized(self, event):
        p = self.plugin
        return (
            bool(p.config.get("allow_private_review", False))
            and str(event.get_platform_id()) == p.platform
            and (str(event.get_sender_id()) == p.owner or self.is_admin(event))
        )

    def key(self):
        return "sylulive_private_review_" + self.plugin.installation

    async def records(self, sender):
        rows = await self.prefs.session_get(
            self.private_umo(sender), self.key(), default=[]
        )
        return [
            r
            for r in rows
            if r.get("epoch") == self.epoch and r.get("expires", 0) > time.time()
        ]

    async def save(self, sender, rows):
        await self.prefs.session_put(self.private_umo(sender), self.key(), rows)

    async def data(self, event, source, target):
        actor = str(event.get_sender_id())
        if not self.authorized(event):
            raise ReviewProblem("私有审核未启用，或你没有本机审核权限。")
        if source == "account":
            # AstrBot 管理员不能继承别人的 SYLUlive 授权。
            if actor != self.plugin.owner or target:
                raise ReviewProblem("仅绑定本人可以查看自己的 SYLUlive 账号信息。")
            result = await self.plugin.client.call("GET", "/binding")
            nickname = str(result.get("account", {}).get("nickname") or "未设置昵称")[
                :100
            ]
            return f"SYLUlive 账号昵称：{nickname}\n当前助手授权有效。仅查询最小账号信息；未读取学号、成绩、课表或私信。"
        if source != "qq" or not re.fullmatch(r"[1-9]\d{4,19}", target):
            raise ReviewProblem("用法：/sylu-review account 或 /sylu-review qq QQ号。")
        if actor != target and not self.is_admin(event):
            raise ReviewProblem("只有可信 AstrBot 管理员可以审核其他会话记录。")
        manager = self.plugin.context.conversation_manager
        umo = self.private_umo(target)
        cid = await manager.get_curr_conversation_id(umo)
        if not cid:
            raise ReviewProblem(
                "这台 AstrBot 没有该私聊的已保存当前会话，不会读取其他 QQ 客户端。"
            )
        conversation = await manager.get_conversation(umo, cid)
        if conversation is None or conversation.user_id != umo:
            raise ReviewProblem("会话不存在或归属不符，已停止读取。")
        history = json.loads(conversation.history or "[]")
        messages = []
        for row in history:
            if row.get("role") not in ("user", "assistant") or row.get("tool_calls"):
                continue
            content = row.get("content", "")
            if isinstance(content, list):
                content = "\n".join(
                    str(p.get("text", ""))
                    for p in content
                    if isinstance(p, dict) and p.get("type") == "text"
                )
            if not isinstance(content, str) or not content.strip():
                continue
            content = re.sub(
                r"(?i)bearer\s+\S+|sk-[A-Za-z0-9_-]+|s[adr]_[A-Za-z0-9_-]{12,}|密码\s*[:：]\s*\S+",
                "[凭据已隐藏]",
                content,
            )
            messages.append(
                ("用户" if row["role"] == "user" else "助手")
                + "："
                + content[:300]
                + ("…（截断）" if len(content) > 300 else "")
            )
        if not messages:
            raise ReviewProblem("该会话没有可展示的纯文字记录。")
        return (
            "已保存私聊的最近至多5条纯文字（不含工具、系统提示及图片）：\n"
            + "\n".join(messages[-5:])
        )

    @staticmethod
    def digest(text):
        return hashlib.sha256(text.encode()).hexdigest()

    async def request(self, event, source, target=""):
        p = self.plugin
        if not self.authorized(event) or not p.allowed_public_group(event):
            raise ReviewProblem(
                "仅获准群内的绑定本人或可信管理员可以发起逐条审核；结果先发本人私聊。"
            )
        actor = str(event.get_sender_id())
        async with self.lock:
            text = await self.data(event, source, target)
            rows = await self.records(actor)
            if len(rows) >= 5:
                raise ReviewProblem("待审项目较多，请先确认、取消或等待5分钟后再试。")
            code = secrets.token_hex(8)
            record = {
                "code": code,
                "actor": actor,
                "group": str(event.get_group_id()),
                "source": source,
                "target": target,
                "digest": self.digest(text),
                "epoch": self.epoch,
                "expires": time.time() + 300,
                "state": "pending",
            }
            rows.append(record)
            await self.save(actor, rows)
            preview = f"【私有结果待审核】\n拟发送到群 {record['group']}，5分钟内有效。确认前没有发到群。\n\n{text}\n\n仅当你确认逐字公开以上内容时，在本私聊发送：\n/sylu-share {code}\n取消：/sylu-cancel {code}\n插件重载、来源变化或授权失效后需重新审核。"
            if not await self.send(self.private_umo(actor), preview):
                await self.save(actor, [r for r in rows if r["code"] != code])
                raise ReviewProblem("无法投递审核私聊，未向群发送任何私有结果。")
        return "审核内容已发到发起人私聊，逐条确认前不会发群。"

    async def decide(self, event, code, allow):
        p = self.plugin
        if (
            not self.authorized(event)
            or not event.is_private_chat()
            or event.get_group_id()
        ):
            raise ReviewProblem("确认或取消只能由原发起人在指定平台私聊完成。")
        if not re.fullmatch(r"[a-f0-9]{16}", code):
            raise ReviewProblem("审核码格式不正确，请使用私聊预览中的完整命令。")
        actor = str(event.get_sender_id())
        async with self.lock:
            rows = await self.records(actor)
            record = next(
                (r for r in rows if secrets.compare_digest(r["code"], code)), None
            )
            if record is None or record["actor"] != actor:
                raise ReviewProblem("审核码不存在、已过期或不属于你。")
            if record["state"] != "pending":
                raise ReviewProblem("该项已处理或投递结果不确定，不会自动重复发送。")
            if not allow:
                await self.save(actor, [r for r in rows if r["code"] != code])
                return "已取消，未发送私有结果。"
            groups = {str(g) for g in p.config.get("public_read_group_ids", [])}
            if record["group"] not in groups:
                raise ReviewProblem("目标群已不在允许名单，已停止发送。")
            text = await self.data(event, record["source"], record["target"])
            if self.digest(text) != record["digest"]:
                raise ReviewProblem("来源内容发生变化，请重新发起审核。")
            # 在外发前持久化占用；超时或重启不自动重放，宁可要求人工核实。
            record["state"] = "attempted"
            await self.save(actor, rows)
            target = f"{p.platform}:GroupMessage:{record['group']}"
            if not await self.send(target, "【本人确认分享】\n" + text):
                raise ReviewProblem("未取得群投递确认，请人工核实；不会自动重发。")
            record["state"] = "sent"
            await self.save(actor, rows)
            return "该项已按本次确认发到指定群。重复确认不会再次发送。"

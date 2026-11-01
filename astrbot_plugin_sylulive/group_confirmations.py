"""本人在原群确认披露自己的查询；内存只保存请求元数据，不保存私人结果。"""
import asyncio
import hashlib
import json
import secrets
import time


def policy_stamp(config):
    keys = ("access_rules", "access_default", "group_personal_delivery", "allow_personal_queries", "allow_checkin", "allow_multi_user")
    return hashlib.sha256(json.dumps({key: config.get(key) for key in keys}, sort_keys=True, ensure_ascii=False, default=str).encode()).hexdigest()


def identity(event):
    return (str(event.get_platform_id() or ""), str(getattr(event.message_obj, "self_id", "") or ""), str(event.get_sender_id() or ""), str(event.get_group_id() or ""))


class ConfirmationProblem(Exception):
    pass


class GroupConfirmations:
    def __init__(self, *, now=time.monotonic, limit=256):
        self.now, self.limit, self.rows, self.lock = now, limit, {}, asyncio.Lock()

    async def create(self, event, action, params, generation, stamp):
        async with self.lock:
            self.rows = {code: row for code, row in self.rows.items() if row["expires"] > self.now()}
            actor = identity(event)
            if not all(actor) or event.is_private_chat():
                raise ConfirmationProblem("请在原群发起本人的查询。")
            # 同一人同一群同类的新查询替换旧确认，避免误确认上一页。
            self.rows = {code: row for code, row in self.rows.items() if (row["actor"], row["action"]) != (actor, action)}
            if len(self.rows) >= self.limit:
                raise ConfirmationProblem("待确认查询较多，请稍后重新发起。")
            code = "gp_" + secrets.token_urlsafe(12)
            self.rows[code] = {"actor": actor, "action": action, "params": dict(params), "generation": generation, "stamp": stamp, "expires": self.now()+300}
            return code

    async def consume(self, event, code):
        async with self.lock:
            row = self.rows.get(code)
            if not row or row["actor"] != identity(event) or event.is_private_chat():
                raise ConfirmationProblem("确认码无效，或不属于你在当前群的请求。请重新发起本人的查询。")
            self.rows.pop(code)
            if row["expires"] <= self.now():
                raise ConfirmationProblem("这次群内展示确认已过期，请重新查询。")
            return row

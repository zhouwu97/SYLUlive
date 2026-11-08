"""只跟踪本人已发起的临时授权，结果按原始消息来源单次通知。"""
import asyncio
import logging
import math
import re
import time
from dataclasses import dataclass, field
from types import SimpleNamespace
from weakref import WeakKeyDictionary

from .binding_delivery import _accepted, _event_identity
from .client import IntegrationProblem

MESSAGES = {
    "success": "你的 SYLUlive 绑定成功！现在可以使用本人已授权的功能。\n查看连接：/sylu-status\n使用帮助：/sylu-help",
    "timeout": "本次 SYLUlive 绑定等待已超时，未能确认绑定成功。\n请发 /sylu-connect 取消旧请求并获取新链接，无需先解绑。",
    "denied": "这次绑定未完成：官网授权已拒绝或取消，未增加权限。\n如需重试，请发 /sylu-connect，无需先解绑。",
    "unavailable": "暂时无法确认这次 SYLUlive 绑定结果，请发 /sylu-status 核实。\n如需重试，先发 /sylu-disconnect，再重新绑定。",
}


@dataclass(frozen=True)
class BindingTarget:
    platform: str
    platform_name: str
    sender: str
    bot_id: str
    group: str
    source_private: bool
    route_private: bool
    unified_msg_origin: str
    admin_role_allowed: bool = True
    bot: object = field(default=None, repr=False, compare=False)

    @classmethod
    def from_event(cls, event, *, private_reply=False):
        actor, group, bot_id, private = _event_identity(event)
        platform = event.get_platform_id()
        if not isinstance(platform, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", platform):
            raise IntegrationProblem("invalid_message_context")
        return cls(platform, event.get_platform_name(), actor, bot_id, group, private,
                   private or private_reply, event.unified_msg_origin,
                   event.get_extra("_api_key_allow_admin_role") is not False,
                   getattr(event, "bot", None))

    def get_sender_id(self): return self.sender
    def get_group_id(self): return self.group
    def get_platform_id(self): return self.platform
    def get_platform_name(self): return self.platform_name
    def is_private_chat(self): return self.source_private
    def get_extra(self, key, default=None):
        return self.admin_role_allowed if key == "_api_key_allow_admin_role" else default

    @property
    def message_obj(self): return SimpleNamespace(self_id=self.bot_id)

    @property
    def hint(self):
        destination = "本人私聊" if self.route_private else "本群并 @ 你"
        return f"授权成功、被拒绝或等待超时后，会通知到{destination}；等待期间请保持机器人在线。"


async def send_notice(context, target, outcome):
    """群内只 @ 发起人并发状态；私信不确定不回退群、不自动重发。"""
    text = MESSAGES[outcome]
    try:
        method = getattr(target.bot, "send_private_msg" if target.route_private else "send_group_msg", None)
        if callable(method):
            message = [{"type": "text", "data": {"text": text}}]
            if target.route_private:
                kwargs = {"user_id": int(target.sender)}
                if target.group:
                    kwargs["group_id"] = int(target.group)
            else:
                kwargs = {"group_id": int(target.group)}
                message.insert(0, {"type": "at", "data": {"qq": target.sender}})
                message[-1]['data']['text'] = "\n" + text
            result = await method(**kwargs, self_id=target.bot_id, message=message)
            return _accepted(result)
        from astrbot.core.message.message_event_result import MessageChain
        chain = MessageChain()
        if not target.route_private:
            chain.at("", target.sender)
        chain.message(text)
        route = (f"{target.platform}:FriendMessage:{target.sender}" if target.route_private
                 else f"{target.platform}:GroupMessage:{target.group}")
        return await context.send_message(route, chain) is True
    except Exception:
        return False


class BindingNotifications:
    def __init__(self, notify, allowed, *, now=time.monotonic, sleep=asyncio.sleep, limit=512):
        self.notify, self.allowed, self.now, self.sleep = notify, allowed, now, sleep
        self.limit, self.tasks, self.seen, self.closed = limit, {}, WeakKeyDictionary(), False

    def start(self, client, target):
        pending = getattr(client, "pending", None)
        if self.closed or not isinstance(pending, dict):
            return False
        if any(type(pending.get(key)) not in (int, float) or not math.isfinite(pending[key]) for key in ("deadline", "next", "interval")):
            return False
        if pending["interval"] < 5:
            return False
        generation = getattr(client, "generation", 0)
        # 仅记对象编号与代次，不为去重额外留存设备秘密。
        marker = (id(pending), generation)
        if self.seen.get(client) == marker:
            return True
        if client not in self.tasks and len(self.tasks) >= self.limit:
            return False
        previous = self.tasks.get(client)
        if previous:
            previous.cancel()
        self.seen[client] = marker
        task = asyncio.create_task(self._watch(client, pending, generation, target))
        self.tasks[client] = task
        def done(completed):
            if self.tasks.get(client) is completed:
                self.tasks.pop(client, None)
            if not completed.cancelled() and completed.exception() is not None:
                logging.getLogger(__name__).warning("SYLUlive binding_notice_task_failed")
        task.add_done_callback(done)
        return True

    async def _finish(self, client, pending, generation, target, outcome):
        if self.closed or getattr(client, "generation", 0) != generation:
            return
        if outcome == "success":
            if client.pending is not None or not client.tokens:
                return
        elif client.pending is not pending:
            return
        if not self.allowed(target):
            return
        try:
            delivered = await self.notify(target, outcome)
        except Exception:
            delivered = False
        if delivered is not True:
            logging.getLogger(__name__).warning("SYLUlive binding_notice_delivery_unconfirmed (%s)", outcome)

    async def _watch(self, client, pending, generation, target):
        retry_at = 0
        while not self.closed:
            current = getattr(client, "generation", 0)
            if current != generation:
                # 本人命令可能先领取补充授权；只有这一个请求确认的完成代次可通知。
                completed = pending.get("completed_generation")
                if type(completed) is int and current == completed and client.pending is None and client.tokens:
                    await self._finish(client, pending, current, target, "success")
                return
            if client.pending is not pending:
                if client.pending is None and client.tokens:
                    await self._finish(client, pending, generation, target, "success")
                return
            if self.now() >= pending["deadline"]:
                await self._finish(client, pending, generation, target, "timeout")
                return
            wait = min(max(pending["next"], retry_at) - self.now(), pending["deadline"] - self.now())
            if wait > 0:
                await self.sleep(wait)
                continue
            try:
                # 锁内再核对请求对象，旧任务不得轮询解绑后新发起的请求。
                completed_generation = await client.poll(expected=pending)
                if client.pending is None and client.tokens:
                    # 领取新授权会作废旧在途操作；通知绑定到本次领取返回的代次。
                    current = completed_generation if type(completed_generation) is int else generation
                    await self._finish(client, pending, current, target, "success")
                    return
            except IntegrationProblem as error:
                if getattr(client, "generation", 0) != generation:
                    return
                if error.code in ("authorization_expired", "expired_token"):
                    await self._finish(client, pending, generation, target, "timeout")
                    return
                if error.code == "access_denied":
                    await self._finish(client, pending, generation, target, "denied")
                    return
                if error.code == "authorization_changed":
                    return
                if error.code not in ("authorization_pending", "poll_later", "slow_down", "network_unavailable", "service_unavailable", "rate_limited", "rate_limit_exceeded"):
                    await self._finish(client, pending, generation, target, "unavailable")
                    return
                retry_at = self.now() + min(max(pending["interval"], 5), 30)
            except asyncio.CancelledError:
                raise
            except Exception:
                await self._finish(client, pending, generation, target, "unavailable")
                return

    async def stop(self, client):
        task = self.tasks.pop(client, None)
        if task:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def close(self):
        self.closed = True
        tasks = list(self.tasks.values())
        self.tasks.clear()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

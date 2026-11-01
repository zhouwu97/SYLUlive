"""按本次真实消息来源投递临时授权链接；不接收模型指定的目标或凭据。"""

from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
import re
from typing import Any
from urllib.parse import parse_qsl, urlsplit

from .client import IntegrationProblem, checked_origin


@dataclass(frozen=True)
class BindingDelivery:
    group_text: str
    private_confirmed: bool = False
    used_fallback: bool = False


def _event_identity(event: Any) -> tuple[str, str, str, bool]:
    actor = str(event.get_sender_id() or "")
    group = str(event.get_group_id() or "")
    bot = str(getattr(getattr(event, "message_obj", None), "self_id", "") or "")
    private = event.is_private_chat() is True
    # 事件 ID 同时用于原生路由与 UMO；不让分隔符形成另一个投递目标。
    safe = re.compile(r"[A-Za-z0-9_.-]{1,100}")
    if not safe.fullmatch(actor) or not safe.fullmatch(bot):
        raise IntegrationProblem("invalid_message_context")
    if private and group or not private and not safe.fullmatch(group):
        raise IntegrationProblem("invalid_message_context")
    return actor, group, bot, private


def _binding_text(actor: str, result: Mapping[str, Any], origin: str) -> str:
    # begin() 的公开回包只需这两个字段；其他字段永远不拼接到消息。
    code, uri = result.get("user_code"), result.get("verification_uri")
    if not isinstance(code, str) or not re.fullmatch(r"[A-Za-z0-9-]{4,64}", code):
        raise IntegrationProblem("invalid_binding_link")
    if not isinstance(uri, str) or len(uri) > 2048:
        raise IntegrationProblem("invalid_binding_link")
    try:
        parsed = urlsplit(uri)
        actual_origin = checked_origin(f"{parsed.scheme}://{parsed.netloc}")
        expected_origin = checked_origin(origin)
        query = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True, max_num_fields=4)
        valid = (
            actual_origin == expected_origin
            and parsed.path == "/web/connected-apps"
            and not parsed.fragment
            and query == [("user_code", code)]
        )
    except (TypeError, ValueError):
        valid = False
    if not valid:
        raise IntegrationProblem("invalid_binding_link")
    return (
        f"这是发起人 QQ {actor} 的本次临时绑定链接：\n{uri}\n"
        f"官网核对设备代码 {code}、发起 QQ 和自己的校园账号，再选择权限。"
        "网页授权后可直接使用已开放且已授权的本人功能；/sylu-status 查看状态。"
        "不要转发链接。误绑时由本人发送 /sylu-disconnect 后重新申请。"
    )


def _accepted(result: Any, *, allow_bool: bool = False) -> bool:
    # aiocqhttp 已将 OneBot 响应解包为 data；这里只确认协议接受，不能证明实际送达。
    if result is True:
        return allow_bool
    if not isinstance(result, Mapping):
        return False
    if result.get("status") == "failed" or result.get("retcode", 0) != 0:
        return False
    message_id = result.get("message_id")
    return (
        isinstance(message_id, int) and not isinstance(message_id, bool) and message_id != 0
        or isinstance(message_id, str) and bool(re.fullmatch(r"-?[1-9]\d*", message_id))
    )


async def deliver_binding_link(
    event: Any,
    result: Mapping[str, Any],
    *,
    origin: str,
    delivery: str = "auto",
    send_private: Callable[[Any, str], Awaitable[Any]] | None = None,
) -> BindingDelivery:
    """返回给当前事件的文字；private/auto至多提交一次私信，不自行向群发消息。

    main 将 group_text 作为当前事件回复。auto 表示部署者允许私信未确认后在
    当前群展示同一临时链接；它不会产生第二个授权请求或重试私信。
    """
    if delivery not in ("private", "group", "auto"):
        raise IntegrationProblem("invalid_binding_delivery")
    if not isinstance(result, Mapping):
        raise IntegrationProblem("invalid_binding_link")
    actor, group, bot, private = _event_identity(event)
    text = _binding_text(actor, result, origin)
    if private or delivery == "group":
        return BindingDelivery(text)

    accepted = False
    native = getattr(getattr(event, "bot", None), "send_private_msg", None)
    try:
        if callable(native):
            if not actor.isdigit() or not group.isdigit():
                raise IntegrationProblem("invalid_message_context")
            sent = await native(
                user_id=int(actor), group_id=int(group), self_id=bot,
                message=[{"type": "text", "data": {"text": text}}],
            )
            accepted = _accepted(sent)
        elif send_private is not None:
            accepted = _accepted(await send_private(event, text), allow_bool=True)
    except Exception:
        # 超时可能是已提交但未收到回包；不能切换私信通道重复提交。
        accepted = False

    if accepted:
        return BindingDelivery(
            "绑定链接已提交私信发送，请本次发起人查看机器人私聊并在官网核对授权。"
            "若未收到，可添加机器人好友后联系管理员调整链接投递方式；/sylu-status 查看状态。",
            private_confirmed=True,
        )
    if delivery == "auto":
        return BindingDelivery(
            "私信发送未获确认，按管理员设置在本群提供同一份临时授权链接。\n" + text,
            used_fallback=True,
        )
    return BindingDelivery(
        "未能确认绑定链接私信发送。请查看机器人私聊，必要时添加好友；"
        "本次请求已创建，可在官网处理后用 /sylu-status 检查，或 /sylu-disconnect 取消。"
        "管理员可在后台把链接投递方式改为“群内显示”或“自动回退群内”。"
    )

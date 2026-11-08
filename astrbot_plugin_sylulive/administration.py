"""复用 AstrBot 当前管理员配置，不维护第二份插件管理员名单。"""

from collections.abc import Mapping
from inspect import signature


def is_bot_admin(context, event):
    """只判断本机管理身份；不授予任何人的 SYLUlive 授权或数据所有权。

    重新读取当前会话配置，使后台撤权立即生效。旧 SDK 只有无参
    get_config 时使用其全局配置；不能将读取失败当作允许管理员。
    """
    try:
        actor = event.get_sender_id()
        origin = event.unified_msg_origin
        if not isinstance(actor, str) or not actor or actor != actor.strip():
            return False
        if not isinstance(origin, str) or not origin:
            return False
        extra = getattr(event, "get_extra", None)
        # 镜像 AstrBot 唤醒阶段的限制，避免 API key 禁止管理员后被插件重新提权。
        if callable(extra) and extra("_api_key_allow_admin_role") is False:
            return False
        getter = context.get_config
        try:
            signature(getter).bind(umo=origin)
        except TypeError:
            # 仅当旧方法确实不接受 umo 时降级；内部 TypeError 仍按读取失败处理。
            signature(getter).bind()
            config = getter()
        else:
            config = getter(umo=origin)
        if not isinstance(config, Mapping):
            return False
        admins = config.get("admins_id")
        if not isinstance(admins, (list, tuple)):
            return False
        if any(not isinstance(item, str) for item in admins):
            return False
        return actor in admins
    except Exception:
        return False

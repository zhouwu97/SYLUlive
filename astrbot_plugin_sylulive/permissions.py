"""AstrBot 管理员配置的消息入口权限；不代替用户授权、scope 或服务端校验。"""
from dataclasses import dataclass
from collections.abc import Mapping


CAPABILITY_LABELS = {
    "public_read": "公开校园查询",
    "bind": "绑定自己的校园账号",
    "status": "查看自己的连接状态",
    "unbind": "解除自己的绑定",
    "checkin": "本人每日签到",
    "grades": "查询本人成绩",
    "erke": "查询本人二课",
    "proposals": "创建本人发帖／评论草稿",
    "private_review": "私有结果审核分享",
}

REASONS = {
    "invalid_context": "无法确认本条消息的真实来源，已停止执行。",
    "unknown_capability": "此功能没有登记权限，已停止执行。",
    "invalid_policy": "插件权限配置不完整或格式错误，请部署者在 AstrBot 后台检查。",
    "explicit_deny": "部署者的权限规则禁止你在当前会话使用此功能。",
    "explicit_allow": "当前会话命中部署者允许规则，仍需本人授权及功能开关。",
    "default_allow": "当前会话按部署者默认规则允许使用此功能。",
    "default_deny": "部署者尚未允许你在当前会话使用此功能。",
}


@dataclass(frozen=True)
class Decision:
    allowed: bool
    reason: str
    rule_name: str = ""

    @property
    def reason_text(self):
        return REASONS[self.reason]


def _ids(value):
    if not isinstance(value, list) or len(value) > 256:
        raise ValueError("invalid id list")
    if any(not isinstance(item, str) or not item.strip() or len(item) > 128 for item in value):
        raise ValueError("invalid id")
    return {item.strip() for item in value}


def _options(value, choices):
    if not isinstance(value, list) or not value or any(not isinstance(item, str) or item not in choices for item in value):
        raise ValueError("invalid choice list")
    return set(value)


def _compile(rule, index):
    if not isinstance(rule, Mapping) or type(rule.get("enabled", True)) is not bool:
        raise ValueError("invalid rule")
    if rule.get("enabled", True) is False:
        return None
    effect, subjects = rule.get("effect"), rule.get("subjects")
    if effect not in ("allow", "deny") or subjects not in ("everyone", "admins", "specified_users"):
        raise ValueError("invalid effect or subject")
    actions = _options(rule.get("capabilities"), CAPABILITY_LABELS)
    chats = _options(rule.get("chat_types"), {"private", "group"})
    users, groups = _ids(rule.get("user_ids", [])), _ids(rule.get("group_ids", []))
    if subjects == "specified_users" and not users:
        raise ValueError("specified users required")
    name = rule.get("name", "")
    if not isinstance(name, str) or len(name) > 200:
        raise ValueError("invalid name")
    return (effect, subjects, actions, chats, users, groups, name.strip() or f"规则 {index + 1}")


def decide(config, event, action, *, is_admin=False, default=False):
    """禁止规则优先；未匹配按兼容默认或严格白名单，管理员由原生权限提供。

    不读取QQ群头衔、owner_sender_id、指令中的QQ或@对象。功能开关与本人
    OAuth授权由业务入口继续校验，允许规则本身不能授予校园权限。
    """
    if not isinstance(action, str) or action not in CAPABILITY_LABELS:
        return Decision(False, "unknown_capability")
    try:
        sender, group, platform = event.get_sender_id(), event.get_group_id(), event.get_platform_id()
        private = event.is_private_chat()
        if not all(isinstance(value, str) for value in (sender, group, platform)):
            raise ValueError("invalid context identifiers")
        sender, group, platform = sender.strip(), group.strip(), platform.strip()
        if not sender or not platform or type(private) is not bool or (bool(group) == private):
            raise ValueError("invalid chat context")
        if not isinstance(config, Mapping):
            return Decision(False, "invalid_policy")
        expected_platform = config.get("owner_platform_id", "")
        if not isinstance(expected_platform, str):
            return Decision(False, "invalid_policy")
        if expected_platform.strip() and expected_platform.strip() != platform:
            raise ValueError("unexpected platform")
    except (AttributeError, TypeError, ValueError):
        return Decision(False, "invalid_context")
    access_default = config.get("access_default", "inherit")
    if access_default not in ("inherit", "deny"):
        return Decision(False, "invalid_policy")
    rules = config.get("access_rules", [])
    try:
        if not isinstance(rules, list) or len(rules) > 128:
            raise ValueError("invalid rules")
        compiled = [_compile(rule, index) for index, rule in enumerate(rules)]
    except (TypeError, ValueError):
        return Decision(False, "invalid_policy")
    allowed_by = ""
    for rule in compiled:
        if rule is None:
            continue
        effect, subjects, actions, chats, users, groups, name = rule
        if action not in actions or ("private" if private else "group") not in chats:
            continue
        if users and sender not in users:
            continue
        # 指定群号只命中这些真实群，不会误命中同一发送者的私聊。
        if groups and group not in groups:
            continue
        if subjects == "admins" and is_admin is not True:
            continue
        if effect == "deny":
            return Decision(False, "explicit_deny", name)
        allowed_by = allowed_by or name
    if allowed_by:
        return Decision(True, "explicit_allow", allowed_by)
    allowed = default is True and access_default == "inherit"
    return Decision(allowed, "default_allow" if allowed else "default_deny")

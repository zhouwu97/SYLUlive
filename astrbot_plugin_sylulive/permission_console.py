"""Authenticated AstrBot page: evaluate policy without querying or changing an account."""
import hashlib
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path

from .permissions import CAPABILITY_LABELS

VERSION = "0.4.2"
SCOPES = {"checkin": "checkin:write", "grades": "academic:grades:read",
          "erke": "academic:erke:read", "proposals": "community:propose",
          "private_review": "profile:read_minimal"}


@dataclass(frozen=True)
class PreviewEvent:
    platform: str
    bot: str
    sender: str
    group: str
    isolated: bool = False

    def get_platform_id(self): return self.platform
    def get_platform_name(self): return "aiocqhttp"
    def get_sender_id(self): return self.sender
    def get_group_id(self): return self.group
    def is_private_chat(self): return not self.group
    def get_extra(self, _): return None

    @property
    def message_obj(self):
        return self

    @property
    def self_id(self):
        return self.bot

    @property
    def unified_msg_origin(self):
        target = f"{self.sender}_{self.group}" if self.group and self.isolated else self.group
        return f"{self.platform}:GroupMessage:{target}" if self.group else f"{self.platform}:FriendMessage:{self.sender}"


def parse_target(body):
    keys = {"platform_id", "bot_id", "sender_id", "group_id", "member_isolated"}
    if not isinstance(body, dict) or set(body) - keys:
        raise ValueError("只接受平台、机器人、发起人、群号与会话隔离设置。")
    platform, bot, sender, group = (body.get(k, "") for k in ("platform_id", "bot_id", "sender_id", "group_id"))
    if not isinstance(platform, str) or not re.fullmatch(r"[\w.-]{1,100}", platform, flags=re.ASCII):
        raise ValueError("请填写真实 QQ 平台实例 ID。")
    if any(not isinstance(x, str) or not re.fullmatch(r"[1-9]\d{4,14}", x) for x in (bot, sender)):
        raise ValueError("机器人和发起人须填写原始 QQ 号。")
    if not isinstance(group, str) or (group and not re.fullmatch(r"[1-9]\d{4,14}", group)):
        raise ValueError("群号格式不正确；私聊请留空。")
    isolated = body.get("member_isolated", False)
    if type(isolated) is not bool:
        raise ValueError("会话隔离设置必须是布尔值。")
    return PreviewEvent(platform, bot, sender, group, isolated)


def _grant(plugin, event):
    # 只读当前内存/系统凭据元数据，不创建安装 ID、不实例化客户端、不刷新令牌。
    if event.sender == plugin.owner and plugin.platform and event.platform == plugin.platform:
        client = getattr(plugin, "client", None)
        tokens = getattr(client, "tokens", None)
        pending = bool(getattr(client, "pending", None))
    else:
        accounts = getattr(plugin, "accounts", None)
        client = getattr(accounts, "entries", {}).get((event.bot, event.sender), (None,))[0]
        tokens = getattr(client, "tokens", None)
        pending = bool(getattr(client, "pending", None))
        if client is None and accounts is not None and hasattr(accounts, "directory"):
            from .credential_store import CredentialStore
            identity = hashlib.sha256(f"{accounts.origin}|{accounts.platform}|{event.bot}|{event.sender}".encode()).hexdigest()
            if (accounts.directory / (identity + ".json")).is_file():
                tokens = CredentialStore(identity).load()
    if not isinstance(tokens, dict):
        return {"state": "pending" if pending else "not_loaded", "scopes": [], "access_expired": None}
    scopes = tokens.get("scope", "")
    scopes = scopes.split() if isinstance(scopes, str) else []
    return {"state": "stored", "scopes": sorted(set(scopes) & (set(SCOPES.values()) | {"community:bot_reply", "community:bot_post"})),
            "access_expired": not isinstance(tokens.get("expires_at"), (int, float)) or tokens["expires_at"] <= time.time()}


def preview(plugin, body):
    event = parse_target(body)
    grant = _grant(plugin, event)
    rows = []
    for action, title in CAPABILITY_LABELS.items():
        decision = plugin.permission(event, action)
        feature = plugin.feature_available(event, action)
        required = SCOPES.get(action)
        authorized = None if not required else required in grant["scopes"]
        if not decision.allowed:
            state, reason = "denied", decision.reason_text
        elif not feature:
            state, reason = "disabled", "功能总开关关闭，或当前模式没有提供此项能力。"
        elif required and not authorized:
            state, reason = "scope_required", "未找到本人的这项授权；须本人在官网核对并同意。"
        elif action == "public_read":
            state, reason = "public_allowed", "可发起匿名公开查询；服务端仍检查当前可见性。"
        else:
            state, reason = "server_check_required", "本机入口条件通过；实际请求仍须服务端核验授权、资格与状态。"
        rows.append({"action": action, "title": title, "state": state, "reason": reason,
                     "rule": {"allowed": decision.allowed, "reason": decision.reason, "name": decision.rule_name},
                     "feature_enabled": feature, "required_scope": required, "local_scope_present": authorized,
                     "server": "not_checked" if action != "public_read" else "visibility_checked_on_read"})
    return {"target": body, "is_admin": plugin.is_bot_admin(event), "grant": grant, "items": rows,
            "notice": "这是对输入身份的只读模拟，不证明 QQ 归属、不代用户授权，也不读取成绩或二课。"}


def build_info():
    root = Path(__file__).resolve().parent
    try:
        raw = json.loads((root / "build.json").read_text(encoding="utf-8"))
        files = raw["files"]
        if not isinstance(files, dict) or not files or len(files) > 40:
            raise ValueError("invalid manifest")
        valid = all(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_./-]+", name)
                    and not Path(name).is_absolute() and ".." not in Path(name).parts
                    and isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest)
                    and (root / name).is_file() and hashlib.sha256((root / name).read_bytes()).hexdigest() == digest
                    for name, digest in files.items())
        return {"version": VERSION, "state": "verified" if valid and raw.get("version") == VERSION else "changed",
                "fingerprint": hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()[:16],
                "source_commit": raw.get("source_commit"), "source_dirty": raw.get("source_dirty", True)}
    except (OSError, ValueError, TypeError, KeyError):
        return {"version": VERSION, "state": "source_tree", "fingerprint": None, "source_commit": None, "source_dirty": True}


def overview(plugin):
    config = plugin.config
    agent = getattr(plugin, "public_agent", None)
    publisher = getattr(agent, "publisher", None)
    remaining = max(0, int(agent.next_run - agent.clock())) if agent else None
    return {"build": build_info(), "platform_id": plugin.platform,
            "defaults": {key: config.get(key) for key in ("allow_multi_user", "allow_checkin", "allow_personal_queries", "allow_proposals", "public_read_all_sessions", "access_default", "group_personal_delivery", "community_chat_memes_enabled")},
            "rule_count": len(config.get("access_rules", [])) if isinstance(config.get("access_rules", []), list) else None,
            "runtime": {"persona": "自定义人格" if config.get("community_persona") else "大肥鱼",
                        "agent_enabled": config.get("community_agent_enabled", False) is True,
                        "memory_mode": config.get("community_memory_mode", "lexical"),
                        "auto_browse": config.get("community_auto_browse", False) is True,
                        "state": getattr(agent, "state", "not_started"), "next_in_seconds": remaining,
                        "last_result": getattr(agent, "last_result", None),
                        "comment_configured": config.get("community_auto_comment", False) is True,
                        "comment_authorized": publisher.authorized() if publisher else False,
                        "auto_post_available": False},
            "notice": "配置修改仍使用 AstrBot 原生插件设置。本页没有保存、授权、解绑、查询个人资料或发布按钮。"}


def register_console(context, plugin):
    from astrbot.api.web import request
    from starlette.responses import JSONResponse
    plugin._console_active = True

    async def status():
        if not request.username:
            return JSONResponse({"error": "dashboard_login_required"}, status_code=401)
        if not plugin._console_active:
            return JSONResponse({"error": "plugin_inactive"}, status_code=503)
        return JSONResponse(overview(plugin), headers={"Cache-Control": "no-store"})

    async def evaluate():
        if not request.username:
            return JSONResponse({"error": "dashboard_login_required"}, status_code=401)
        if not plugin._console_active:
            return JSONResponse({"error": "plugin_inactive"}, status_code=503)
        try:
            length = request.headers.get("content-length", "0")
            if not length.isdecimal() or int(length) > 2048:
                return JSONResponse({"error": "request_too_large"}, status_code=413)
            data = await request.body()
            if len(data) > 2048:
                return JSONResponse({"error": "request_too_large"}, status_code=413)
            result = preview(plugin, json.loads(data))
        except (ValueError, TypeError, UnicodeError):
            return JSONResponse({"error": "invalid_target", "message": "请检查平台 ID、机器人 QQ、发起人 QQ、群号与会话隔离设置。"}, status_code=422)
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    context.register_web_api("/astrbot_plugin_sylulive/permissions/status", status, ["GET"], "只读权限与构建状态")
    context.register_web_api("/astrbot_plugin_sylulive/permissions/preview", evaluate, ["POST"], "只读模拟指定会话权限，不执行业务")

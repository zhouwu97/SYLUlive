"""Keep reviewed current-chat meme tools, never generic file or cross-chat tools."""
import re

MEME_TOOLS = frozenset({"search_meme", "send_meme"})
MEME_MODULES = frozenset({"data.plugins.astrbot_plugin_stealer.main", "astrbot_plugin_stealer.main"})


def sticker_request(text):
    match = re.fullmatch(r"(?:请)?(?:给我)?(?:发|来)(?:一张|一个|个|张)?(?:现有的|平台内置的)?([\u4e00-\u9fffA-Za-z0-9]{0,8}?)(?:表情包|表情)(?:图片)?(?:给我|吧)?", text)
    return (match[1].removesuffix("的") or "好耶") if match else None


MEME_GUIDANCE = """[当前聊天表情]
可用 sylulive_stickers 查平台内置表情、sylulive_send_sticker 把候选图片发到当前聊天。
若工具列表中提供 search_meme/send_meme，也可查找并发送当前聊天候选。
按图上文字和语气选择，可以不发，不必每条配图。图库没有候选时用文字说明，不编造已发送。
这些是 QQ 聊天表情，不能当作已上传 SYLUlive 的附件；不使用本地文件、跨会话发送或收集工具。
"""


def trusted_meme(tool):
    if getattr(tool, "name", "") not in MEME_TOOLS or getattr(tool, "active", True) is not True:
        return False
    if getattr(tool, "handler_module_path", None) not in MEME_MODULES:
        return False
    parameters = getattr(tool, "parameters", {}) or {}
    properties = parameters.get("properties", {})
    if not isinstance(properties, dict):
        return False
    allowed = {"emoji_id"} if tool.name == "send_meme" else {"query", "reply", "character"}
    return bool(properties) and set(properties) <= allowed


def chat_tools(tools, public_names, memes=False):
    return [tool for tool in tools if (tool.name in public_names and (memes or tool.name != "sylulive_send_sticker")) or (memes and trusted_meme(tool))]

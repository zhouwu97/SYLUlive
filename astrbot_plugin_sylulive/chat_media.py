"""Keep reviewed current-chat meme tools, never generic file or cross-chat tools."""

MEME_TOOLS = frozenset({"search_meme", "send_meme"})
MEME_MODULES = frozenset({"data.plugins.astrbot_plugin_stealer.main", "astrbot_plugin_stealer.main"})
MEME_GUIDANCE = """[当前聊天表情]
可在合适的语境使用 search_meme 查找、send_meme 发送本轮候选，均只回当前聊天。
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
    return [tool for tool in tools if tool.name in public_names or (memes and trusted_meme(tool))]

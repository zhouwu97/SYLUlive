"""Offline contract tests; event doubles do not claim real QQ/AstrBot acceptance."""

import ast
import importlib
import sys
import types
from pathlib import Path
import docstring_parser


def test_tool_definitions_match_documented_astrbot_schema():
    tree = ast.parse(
        (Path(__file__).parents[1] / "main.py").read_text(encoding="utf-8")
    )
    tools = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.AsyncFunctionDef):
            continue
        if not any(
            isinstance(d, ast.Call)
            and isinstance(d.func, ast.Attribute)
            and d.func.attr == "llm_tool"
            for d in node.decorator_list
        ):
            continue
        tools.append(node.name)
        doc = docstring_parser.parse(ast.get_docstring(node) or "")
        params = {p.arg_name: p.type_name for p in doc.params}
        expected = {p.arg for p in node.args.args} - {"self", "event"}
        assert set(params) == expected
        assert all(
            t in {"string", "number", "boolean", "array", "object"}
            for t in params.values()
        )
        assert not ({"token", "owner_id", "role", "password", "approve"} & expected)
    assert len(tools) == 10


def test_owner_and_group_boundary_and_same_message_operation(monkeypatch):
    def decorator(*a, **k):
        return lambda fn: fn

    api = types.ModuleType("astrbot.api")
    api.AstrBotConfig = dict
    events = types.ModuleType("astrbot.api.event")
    events.AstrMessageEvent = object
    events.filter = types.SimpleNamespace(command=decorator, llm_tool=decorator, on_llm_request=decorator, on_agent_done=decorator)
    providers = types.ModuleType("astrbot.api.provider")
    providers.ProviderRequest = object
    providers.LLMResponse = object
    agent_messages = types.ModuleType("astrbot.core.agent.message")
    agent_messages.TextPart = object
    stars = types.ModuleType("astrbot.api.star")
    stars.Context = object
    stars.Star = object
    stars.StarTools = object
    stars.register = decorator
    monkeypatch.setitem(sys.modules, "astrbot", types.ModuleType("astrbot"))
    for name, module in [
        ("astrbot.api", api),
        ("astrbot.api.event", events),
        ("astrbot.api.provider", providers),
        ("astrbot.core.agent.message", agent_messages),
        ("astrbot.api.star", stars),
    ]:
        monkeypatch.setitem(sys.modules, name, module)
    sys.modules.pop("astrbot_plugin_sylulive.main", None)
    plugin = importlib.import_module(
        "astrbot_plugin_sylulive.main"
    ).SYLUlivePlugin.__new__(
        importlib.import_module("astrbot_plugin_sylulive.main").SYLUlivePlugin
    )
    plugin.owner = "123"
    plugin.platform = "my-qq"
    plugin.installation = "9c47929a-5f09-4c9b-b24a-61325bfc82c2"
    event = types.SimpleNamespace(
        is_private_chat=lambda: True,
        get_group_id=lambda: "",
        get_sender_id=lambda: "123",
        get_platform_id=lambda: "my-qq",
        message_obj=types.SimpleNamespace(message_id="one"),
    )
    assert plugin.allowed(event)
    first = plugin.operation(event, {"content": "test"})
    assert first == plugin.operation(event, {"content": "test"})
    event.get_group_id = lambda: "group"
    assert not plugin.allowed(event)
    event.get_group_id = lambda: ""
    event.get_sender_id = lambda: "other"
    assert not plugin.allowed(event)
    event.get_sender_id = lambda: "123"
    event.get_platform_id = lambda: "other"
    assert not plugin.allowed(event)

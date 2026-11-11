import asyncio
import copy
import hashlib
import json
import uuid
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from astrbot_plugin_sylulive.bot_runtime import BotRuntimeManager
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory


class Client:
    def __init__(self, ident):
        self.ident, self.generation = ident, 1
        self.tokens = {"scope": "community:read community:bot_reply"}
        self.bot = {"bot_user_id": ident, "revision": 1, "enabled": True, "policy": {
            "public_read_enabled": True, "reply_enabled": True, "sticker_enabled": False,
            "allowed_post_types": ["campus_life"]}}
        self.binding, self.calls, self.published = str(uuid.uuid4()), [], []
        self.supported, self.busy = True, False
        self.reply_service = True

    async def refresh_scope(self):
        return self.tokens["scope"]

    async def public_image(self, _):
        raise AssertionError("no image was requested")

    async def call(self, method, path, **kwargs):
        await asyncio.sleep(0)
        self.calls.append((method, path, copy.deepcopy(kwargs)))
        if path == "/bot/policy":
            return {"runtime_supported": self.supported, "bot": copy.deepcopy(self.bot), "binding": {"binding_id": self.binding, "epoch": 1}, "auto_reply_server_enabled": self.reply_service, "auto_reply_authorized": True}
        if path == "/bot/runtime":
            if self.busy:
                raise IntegrationProblem("bot_runtime_busy")
            return {"accepted": True}
        post = {"post_id": self.ident, "title": "合成公开帖", "content": f"public-source-{self.ident}", "post_type": "campus_life", "status": "normal", "source_version": "a" * 64, "created_at": "2026-01-01T00:00:00Z"}
        if path == "/community/posts":
            return {"data": {"items": [post]}}
        if path.startswith("/community/") and path.endswith("/replies"):
            return {"data": {"items": [], "next_after_id": 0}}
        if path.startswith("/community/posts/"):
            return {"data": post}
        if path == "/community/stickers":
            return {"data": {"items": []}}
        if path == "/bot/replies":
            payload = kwargs["payload"]
            assert payload["post_id"] == self.ident
            assert payload["runtime_session_id"] and payload["bot_revision"] == self.bot["revision"]
            self.published.append(payload)
            return {"state": "published", "reply_id": self.ident * 100}
        raise AssertionError(path)


def runtime(tmp_path, clients, *, now=None, context=None):
    config = {"allow_multi_user": True, "community_multi_user_runtime_enabled": True,
              "community_agent_enabled": True, "community_auto_browse": True,
              "community_auto_comment": True, "community_agent_provider_id": "synthetic",
              "community_allowed_sections": ["campus_life"], "community_browse_interval_minutes": 30}
    owner = Client(99)
    owner.tokens = None
    legacy = PublicAgent(config, ManagedBotAccess(owner), PublicMemory(tmp_path / "legacy.sqlite3"))
    accounts = SimpleNamespace(clients=lambda: [(hashlib.sha256(str(c.ident).encode()).hexdigest(), c, "synthetic") for c in clients], restore=lambda: None)
    manager = BotRuntimeManager(config, context, tmp_path, accounts, owner, "a" * 64, legacy,
                                clock=(lambda: now[0]) if now else __import__("time").time,
                                monotonic=(lambda: now[0]) if now else __import__("time").monotonic)
    return manager


async def act(**request):
    assert request["contexts"] == []
    tools = request["tools"]
    assert not {"send_message", "private_memory", "sylulive_grades"}.intersection(t.name for t in tools.tools)
    read = tools.get_tool("read_public_post")
    ident = read.parameters["properties"]["post_id"]["enum"][0]
    assert "error" not in json.loads(await read.handler(request["event"], ident))
    replies = tools.get_tool("read_public_replies")
    assert "error" not in json.loads(await replies.handler(request["event"], ident))
    result = await tools.get_tool("comment_public_post").handler(request["event"], ident, "合成公开评论")
    assert json.loads(result)["state"] == "published"


@pytest.mark.asyncio
async def test_existing_connection_discovers_scope_added_on_website_without_rebinding(tmp_path):
    now = [1000]
    client = Client(10)
    client.tokens = {"scope": "profile:read_minimal"}
    refreshes = []
    async def refresh():
        refreshes.append(now[0])
        if len(refreshes) == 2:
            client.tokens["scope"] = "profile:read_minimal community:read"
        return client.tokens["scope"]
    client.refresh_scope = refresh
    manager = runtime(tmp_path, [client], now=now)
    try:
        await manager.discover(start_workers=False)
        assert not manager.workers and refreshes == [1000]
        now[0] += 20
        await manager.discover(start_workers=False)
        assert refreshes == [1000]
        now[0] += 41
        await manager.discover(start_workers=False)
        assert client in manager.workers and len(refreshes) == 2
        client.tokens = None
        now[0] += 61
        await manager.discover(start_workers=False)
        assert client not in manager.workers and len(refreshes) == 2
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_discover_restarts_failed_worker_without_replacing_account_or_schedule(tmp_path):
    client = Client(10)
    manager = runtime(tmp_path, [client])
    entered = asyncio.Event()
    async def stay_alive(worker):
        entered.set()
        await asyncio.Event().wait()
    try:
        await manager.discover(start_workers=False)
        worker = manager.workers[client]
        await manager.sync(worker, schedule=False)
        before = worker.agent.memory.db.execute("SELECT * FROM runtime_schedule").fetchall()
        session = worker.session
        async def fail():
            raise RuntimeError("synthetic-secret-must-not-be-logged")
        worker.task = asyncio.create_task(fail())
        await asyncio.gather(worker.task, return_exceptions=True)
        manager._worker_loop = stay_alive
        await manager.discover()
        await asyncio.wait_for(entered.wait(), .2)
        assert manager.workers[client] is worker and worker.session == session
        assert worker.agent.memory.db.execute("SELECT * FROM runtime_schedule").fetchall() == before
        assert not client.published
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_two_accounts_read_publish_and_keep_memory_and_ledgers_separate(tmp_path):
    pytest.importorskip("astrbot.api")
    a, b = Client(10), Client(20)
    origins = []
    async def model(**request):
        origins.append(request['event'].unified_msg_origin)
        await act(**request)
    manager = runtime(tmp_path, [a, b], context=SimpleNamespace(tool_loop_agent=model))
    try:
        await manager.discover(start_workers=False)
        tasks = []
        for worker in manager.workers.values():
            await manager.sync(worker)
            tasks.append(worker.round_task)
        results = await asyncio.gather(*tasks)
        assert all(result["state"] == "completed" and result["read_count"] == 1 for result in results)
        assert len(a.published) == len(b.published) == 1
        assert a.published[0]["runtime_session_id"] != b.published[0]["runtime_session_id"]
        assert len(set(origins)) == 2
        for client, worker in manager.workers.items():
            assert worker.agent.memory.db.execute("SELECT id FROM posts").fetchall() == [(client.ident,)]
            assert worker.agent.memory.db.execute("SELECT post_id FROM outbox").fetchall() == [(client.ident,)]
            assert worker.agent.publisher.client is client
    finally:
        await manager.close()


@pytest.mark.asyncio
@pytest.mark.parametrize('model_fails', [False, True])
@pytest.mark.parametrize('fault_path', ['/bot/policy', '/bot/runtime'])
async def test_policy_recovery_restores_round_status_without_rerunning_model(tmp_path, model_fails, fault_path):
    calls = []
    async def model(**request):
        calls.append(request)
        if model_fails:
            raise RuntimeError('synthetic model failure')
        await act(**request)
    now = [10000.0]
    client = Client(10)
    manager = runtime(tmp_path, [client], now=now, context=SimpleNamespace(tool_loop_agent=model))
    try:
        await manager.discover(start_workers=False)
        worker = manager.workers[client]
        await manager.sync(worker)
        await worker.round_task
        expected_state = 'error' if model_fails else 'completed'
        expected_error = 'public_browse_failed' if model_fails else ''
        assert worker.state == expected_state
        schedule = worker.agent.memory.db.execute('SELECT bot_id,next_at FROM runtime_schedule').fetchall()
        original = client.call
        async def unavailable(method, path, **kwargs):
            if path == fault_path:
                raise IntegrationProblem('network_unavailable')
            return await original(method, path, **kwargs)
        client.call = unavailable
        await manager.sync(worker)
        assert worker.state == 'error' and worker.error == 'service_unavailable'
        client.call = original
        now[0] += 20
        await manager.sync(worker)
        assert worker.state == expected_state
        assert worker.error == expected_error
        report = [kw['payload'] for method, path, kw in client.calls if path == '/bot/runtime'][-1]
        assert report['state'] == expected_state and report['error_code'] == expected_error
        assert len(calls) == 1 and worker.round_task is None
        assert worker.agent.memory.db.execute('SELECT bot_id,next_at FROM runtime_schedule').fetchall() == schedule
        assert len(client.published) == (0 if model_fails else 1)
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_legacy_creator_is_registered_without_changing_vault_or_public_store(tmp_path):
    pytest.importorskip("astrbot.api")
    manager = runtime(tmp_path, [], context=SimpleNamespace(tool_loop_agent=act))
    owner = manager.owner_client
    owner.tokens = {"scope":"community:read community:bot_reply"}
    legacy = manager.owner_agent
    try:
        await manager.discover(start_workers=False)
        worker = manager.workers[owner]
        await manager.sync(worker)
        assert worker.agent is legacy
        assert (await worker.round_task)["state"] == "completed"
        assert legacy.memory.db.execute("SELECT post_id FROM outbox").fetchall() == [(99,)]
        assert worker.agent.publisher.client is owner
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_creator_rebinding_before_first_browse_never_reuses_another_bots_store(tmp_path):
    manager = runtime(tmp_path, [])
    manager.config["community_auto_browse"] = False
    owner = manager.owner_client
    owner.tokens = {"scope":"community:read"}
    selected = []
    manager.owner_changed = selected.append
    try:
        await manager.discover(start_workers=False)
        worker = manager.workers[owner]
        await manager.sync(worker)
        original = worker.agent
        original.memory.put({"post_id":99, "post_type":"campus_life", "status":"normal", "title":"A", "content":"A public source", "source_version":"a"*64})
        owner.bot["bot_user_id"], owner.generation = 100, 2
        await manager.sync(worker)
        other = worker.agent
        assert other is not original
        assert other.isolation_id != original.isolation_id
        assert other.memory.db.execute("SELECT COUNT(*) FROM posts").fetchone()[0] == 0
        assert selected[-1] is other and worker.round_task is None
        owner.bot["bot_user_id"], owner.generation = 99, 3
        await manager.sync(worker)
        assert worker.agent is original and selected[-1] is original
        assert original.memory.db.execute("SELECT id FROM posts").fetchall() == [(99,)]
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_pause_cancels_inflight_account_without_interrupting_other_account(tmp_path):
    pytest.importorskip("astrbot.api")
    gate, both_started = asyncio.Event(), asyncio.Event()
    started = []
    async def model(**request):
        started.append(request)
        if len(started) == 2:
            both_started.set()
        await gate.wait()
        await act(**request)
    a, b = Client(10), Client(20)
    manager = runtime(tmp_path, [a, b], context=SimpleNamespace(tool_loop_agent=model))
    try:
        await manager.discover(start_workers=False)
        for worker in manager.workers.values():
            await manager.sync(worker)
        await asyncio.wait_for(both_started.wait(), 10)
        b_task = manager.workers[b].round_task
        a.bot["enabled"], a.bot["revision"] = False, 2
        await manager.sync(manager.workers[a])
        assert not a.published and not b_task.done()
        gate.set()
        assert (await b_task)["state"] == "completed"
        assert not a.published and len(b.published) == 1
    finally:
        gate.set()
        await manager.close()


@pytest.mark.asyncio
async def test_restart_restores_cooldown_and_generation_change_cancels_old_work(tmp_path):
    pytest.importorskip("astrbot.api")
    now = [1000000.0]
    client = Client(10)
    first = runtime(tmp_path, [client], now=now, context=SimpleNamespace(tool_loop_agent=act))
    await first.discover(start_workers=False)
    worker = first.workers[client]
    await first.sync(worker)
    assert (await worker.round_task)["state"] == "completed"
    await first.close()
    now[0] += 60
    second = runtime(tmp_path, [client], now=now, context=SimpleNamespace(tool_loop_agent=act))
    try:
        await second.discover(start_workers=False)
        worker = second.workers[client]
        await second.sync(worker)
        assert worker.round_task is None
        assert worker.agent.next_run > now[0] + 1700
        client.generation += 1
        with pytest.raises(IntegrationProblem, match="bot_runtime_required"):
            worker.agent.publisher.runtime()
        assert len(client.published) == 1
    finally:
        await second.close()


@pytest.mark.asyncio
async def test_global_model_budget_never_runs_more_than_two_accounts_at_once(tmp_path):
    pytest.importorskip("astrbot.api")
    clients = [Client(i) for i in (10, 20, 30, 40)]
    gate, two_started = asyncio.Event(), asyncio.Event()
    counts = {"active": 0, "maximum": 0, "started": 0}
    async def model(**request):
        counts["active"] += 1
        counts["started"] += 1
        counts["maximum"] = max(counts["maximum"], counts["active"])
        if counts["started"] == 2: two_started.set()
        try:
            await gate.wait()
            await act(**request)
        finally:
            counts["active"] -= 1
    manager = runtime(tmp_path, clients, context=SimpleNamespace(tool_loop_agent=model))
    try:
        await manager.discover(start_workers=False)
        tasks = []
        for worker in manager.workers.values():
            await manager.sync(worker)
            tasks.append(worker.round_task)
        await asyncio.wait_for(two_started.wait(), 10)
        assert counts["started"] == 2
        gate.set()
        assert all(r["state"] == "completed" for r in await asyncio.gather(*tasks))
        assert counts["maximum"] == 2 and all(len(c.published) == 1 for c in clients)
    finally:
        gate.set()
        await manager.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["legacy", "busy", "missing_scope", "operator_off"])
async def test_no_background_execution_when_server_scope_or_operator_disallows(tmp_path, mode):
    client = Client(10)
    manager = runtime(tmp_path, [client])
    if mode == "legacy": client.supported = False
    if mode == "busy": client.busy = True
    if mode == "missing_scope": client.tokens["scope"] = "profile:read_minimal"
    if mode == "operator_off": manager.config["community_multi_user_runtime_enabled"] = False
    try:
        await manager.discover(start_workers=False)
        for worker in manager.workers.values():
            await manager.sync(worker)
            assert worker.round_task is None and not worker.leased
        assert not client.published
        assert not any(path.startswith("/community/") for _, path, _ in client.calls)
    finally:
        await manager.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("mode", ["read_only", "server_closed", "policy_closed"])
async def test_reading_keeps_working_without_exposing_unapproved_publish_tools(tmp_path, mode):
    pytest.importorskip("astrbot.api")
    client = Client(10)
    if mode == "read_only": client.tokens["scope"] = "community:read"
    if mode == "server_closed": client.reply_service = False
    if mode == "policy_closed": client.bot["policy"]["reply_enabled"] = False
    async def read(**request):
        tools = request["tools"]
        assert tools.get_tool("comment_public_post") is None
        assert tools.get_tool("publish_public_post") is None
        result = await tools.get_tool("read_public_post").handler(request["event"], 10)
        assert json.loads(result)["post_id"] == 10
    manager = runtime(tmp_path, [client], context=SimpleNamespace(tool_loop_agent=read))
    try:
        await manager.discover(start_workers=False)
        worker = manager.workers[client]
        await manager.sync(worker)
        assert (await worker.round_task)["read_count"] == 1
        assert not client.published
        assert not any(path.startswith("/bot/") and path != "/bot/runtime" and method == "POST" for method, path, _ in client.calls)
    finally:
        await manager.close()


@pytest.mark.asyncio
async def test_scheduler_restores_on_start_and_discovers_newly_bound_accounts(tmp_path):
    pytest.importorskip("astrbot.api")
    clients = [Client(10)]
    finished = {10: asyncio.Event(), 20: asyncio.Event()}
    async def model(**request):
        ident = request["tools"].get_tool("read_public_post").parameters["properties"]["post_id"]["enum"][0]
        await act(**request)
        finished[ident].set()
    manager = runtime(tmp_path, clients, context=SimpleNamespace(tool_loop_agent=model))
    manager.accounts.restore = Mock()
    manager.task = asyncio.create_task(manager.run())
    try:
        await asyncio.wait_for(finished[10].wait(), 10)
        manager.accounts.restore.assert_called_once()
        clients.append(Client(20))
        await asyncio.wait_for(finished[20].wait(), 10)
        assert len(manager.workers) == 2
        tasks = [worker.task for worker in manager.workers.values()]
        assert all(task and not task.done() for task in tasks)
    finally:
        await manager.close()
    assert manager.task.done() and all(task.done() for task in tasks)

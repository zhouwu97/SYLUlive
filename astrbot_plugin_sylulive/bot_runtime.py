"""Per-binding public workers. Only the isolated public Agent receives model tools."""
import asyncio
import hashlib
import json
import logging
import math
import time
import uuid
from dataclasses import dataclass, field

from .approved_media import ApprovedMedia
from .client import IntegrationProblem
from .community_publisher import CommunityPublisher
from .managed_bot_access import ManagedBotAccess
from .public_agent import PublicAgent, PublicMemory


@dataclass
class Worker:
    identity: str
    client: object
    session: str
    agent: object = None
    task: object = None
    round_task: object = None
    marker: object = None
    bot: object = None
    sequence: int = 0
    leased: bool = False
    phase: str = ""
    state: str = "idle"
    error: str = ""
    control_error: str = ""
    last_round_state: str = "idle"
    last_round_error: str = ""
    round_id: str = ""
    read_count: int = 0
    manual: bool = False
    report_lock: object = field(default_factory=asyncio.Lock)


class BotRuntimeManager:
    def __init__(self, config, context, directory, accounts, owner_client, owner_identity,
                 owner_agent, *, owner_changed=None, clock=time.time, monotonic=time.monotonic):
        self.config, self.context, self.directory, self.accounts = config, context, directory, accounts
        self.owner_client, self.owner_identity, self.owner_agent = owner_client, owner_identity, owner_agent
        self.owner_changed, self.clock, self.monotonic = owner_changed, clock, monotonic
        self.workers, self.agents = {}, {}
        self.network_slots, self.model_slots = asyncio.Semaphore(4), asyncio.Semaphore(2)
        self.task, self.closed, self.restore_error = None, False, False
        self.last_discovery = self.monotonic()
        self.scope_checks = {}

    def health(self):
        alive = bool(self.task and not self.task.done() and not self.closed)
        workers = list(self.workers.values())
        failed = sum(bool(w.task and w.task.done()) for w in workers)
        owner = self.workers.get(self.owner_client)
        controls = owner.agent.publisher.controls if owner and owner.agent and owner.agent.publisher else {}
        return {"manager_alive": alive, "discovery_age_seconds": max(0, int(self.monotonic() - self.last_discovery)),
                "workers": len(workers), "failed_workers": failed, "registry_error": self.restore_error,
                "owner_state": owner.phase or owner.state if owner else ("scope_required" if self.owner_client.tokens else "not_connected"),
                "owner_error": owner.error if owner else "",
                "control_error": owner.control_error if owner else "",
                "heartbeat_accepted": bool(owner and owner.leased),
                "next_run_in_seconds": max(0, int(owner.agent.next_run - self.monotonic())) if owner and owner.agent else None,
                "auto_reply_ready": bool(controls and controls.get("auto_reply_server_enabled")
                    and controls.get("auto_reply_authorized") and owner.bot and owner.bot.get("enabled")
                    and owner.bot.get("policy", {}).get("reply_enabled") and owner.leased and self._ready(owner)
                    and self.config.get("community_auto_comment", False)),
                "auto_browse_enabled": self.config.get("community_auto_browse", False) is True}

    def multi_enabled(self):
        return self.config.get("allow_multi_user", False) is True and self.config.get("community_multi_user_runtime_enabled", False) is True

    def _eligible(self, client):
        tokens = client.tokens if isinstance(client.tokens, dict) else {}
        scopes = tokens.get("scope", "")
        return (self.config.get("community_agent_enabled", False) is True
                and (client is self.owner_client or self.multi_enabled())
                and isinstance(scopes, str) and "community:read" in scopes.split())

    async def discover(self, *, start_workers=True):
        if self.closed:
            return
        slots = [(self.owner_identity, self.owner_client, ""), *self.accounts.clients()]
        # 官网可以原地补充权限；缺少读取 scope 的已连接账号也要周期同步。
        for _, client, _ in slots:
            if (self.config.get("community_agent_enabled", False) is True
                    and (client is self.owner_client or self.multi_enabled())
                    and client.tokens and not self._eligible(client)
                    and self.monotonic() >= self.scope_checks.get(client, 0)):
                self.scope_checks[client] = self.monotonic() + 60
                try:
                    async with self.network_slots:
                        await client.refresh_scope()
                except IntegrationProblem:
                    pass
        active = {client for _, client, _ in slots if self._eligible(client)}
        for client in list(self.workers):
            if client not in active:
                worker = self.workers.pop(client)
                if worker.task:
                    worker.task.cancel()
                    await asyncio.gather(worker.task, return_exceptions=True)
                await self._cancel_round(worker)
        for identity, client, _ in slots:
            if client not in active:
                continue
            worker = self.workers.get(client)
            if worker is None:
                worker = Worker(identity, client, str(uuid.uuid4()))
                self.workers[client] = worker
            if start_workers and (worker.task is None or worker.task.done()):
                if worker.task is not None and not worker.task.cancelled():
                    worker.task.exception()  # Consume without logging private exception details.
                    logging.getLogger(__name__).warning("SYLUlive runtime_worker_restarting")
                worker.task = asyncio.create_task(self._worker_loop(worker))
        self.last_discovery = self.monotonic()

    async def run(self):
        try:
            try:
                self.accounts.restore()
            except IntegrationProblem:
                # A damaged index must not be replaced with an empty one or borrow the creator's token.
                self.restore_error = True
                logging.getLogger(__name__).warning("SYLUlive runtime_registry_unavailable")
            prune_at = 0
            while not self.closed:
                try:
                    await self.discover()
                except Exception:
                    logging.getLogger(__name__).warning("SYLUlive runtime_discovery_retry")
                if self.monotonic() >= prune_at:
                    for agent in {self.owner_agent, *self.agents.values()}:
                        try:
                            agent.memory.prune()
                        except Exception:
                            logging.getLogger(__name__).warning("SYLUlive public_memory_cleanup_failed")
                    prune_at = self.monotonic() + 30
                await asyncio.sleep(5)
        except asyncio.CancelledError:
            raise

    async def _worker_loop(self, worker):
        try:
            # Stagger first requests, while keeping each worker independent of slow/failed neighbours.
            await asyncio.sleep(int(worker.identity[:4], 16) % 10)
            while not self.closed and self._eligible(worker.client):
                await self.sync(worker)
                await asyncio.sleep(20)
        finally:
            await self._cancel_round(worker)
            if worker.leased:
                try:
                    await asyncio.wait_for(self._report(worker, "stopped"), 3)
                except Exception:
                    pass  # The server expires the lease; no successful stop is claimed.

    def _get_agent(self, worker, bot):
        key = worker.identity, bot["bot_user_id"]
        if key in self.agents:
            agent = self.agents[key]
            if worker.client is self.owner_client and self.owner_changed:
                self.owner_changed(agent)
            return agent
        agent = None
        if worker.client is self.owner_client:
            legacy = self.owner_agent
            self._schedule_table(legacy)
            row = legacy.memory.db.execute("SELECT bot_id FROM runtime_schedule WHERE singleton=1").fetchone()
            if row is None or row[0] == bot["bot_user_id"]:
                agent = legacy
        if agent is None:
            path = self.directory / f"{worker.identity}.{bot['bot_user_id']}.public-memory.sqlite3"
            agent = PublicAgent(self.config, ManagedBotAccess(worker.client), PublicMemory(path),
                                context=self.context, image_reader=worker.client.public_image)
            agent.publisher = CommunityPublisher(agent, worker.client, media=ApprovedMedia(self.directory / "approved-public-media"))
        self._schedule_table(agent)
        agent.clock = self.monotonic
        agent.isolation_id = "public-" + hashlib.sha256(f"{worker.identity}|{bot['bot_user_id']}".encode()).hexdigest()[:32]
        if agent.publisher is None:
            agent.publisher = CommunityPublisher(agent, worker.client, media=ApprovedMedia(self.directory / "approved-public-media"))
        row = agent.memory.db.execute("SELECT next_at FROM runtime_schedule WHERE singleton=1 AND bot_id=?", (bot["bot_user_id"],)).fetchone()
        if row and type(row[0]) in (float, int) and math.isfinite(row[0]):
            agent.next_run = self.monotonic() + max(0, min(86400, row[0] - self.clock()))
        # Bind the legacy store even when browsing is disabled or waiting for a model slot.
        with agent.memory.db:
            agent.memory.db.execute("INSERT OR IGNORE INTO runtime_schedule VALUES (1,?,0)", (bot["bot_user_id"],))
        self.agents[key] = agent
        if worker.client is self.owner_client and self.owner_changed:
            self.owner_changed(agent)
        return agent

    @staticmethod
    def _schedule_table(agent):
        agent.memory.db.execute("CREATE TABLE IF NOT EXISTS runtime_schedule (singleton INTEGER PRIMARY KEY CHECK(singleton=1), bot_id INTEGER NOT NULL, next_at REAL NOT NULL)")
        agent.memory.db.commit()

    def _marker(self, worker, result):
        return (worker.client.generation, json.dumps(result["bot"], sort_keys=True, ensure_ascii=False),
                json.dumps({"binding": result.get("binding"), **{key: result.get(key) for key in ("auto_reply_server_enabled", "auto_reply_authorized", "auto_post_server_enabled", "auto_post_authorized")}}, sort_keys=True),
                json.dumps(dict(self.config), sort_keys=True, ensure_ascii=False))

    async def _policy(self, worker):
        result = await worker.client.call("GET", "/bot/policy")
        if not isinstance(result, dict) or result.get("runtime_supported") is not True:
            raise IntegrationProblem("runtime_unavailable")
        bot = result.get("bot")
        if bot is None:
            return result
        if (not isinstance(bot, dict) or type(bot.get("bot_user_id")) is not int or bot["bot_user_id"] <= 0
                or type(bot.get("revision")) is not int or bot["revision"] <= 0 or not isinstance(bot.get("policy"), dict)):
            raise IntegrationProblem("invalid_response")
        return result

    def _ready(self, worker):
        bot = worker.bot
        return bool(bot and bot.get("enabled") is True and bot["policy"].get("public_read_enabled") is True
                    and bot["policy"].get("allowed_post_types") and worker.agent and not worker.agent.paused
                    and self._eligible(worker.client)
                    and (worker.manual or self.config.get("community_auto_browse", False) is True)
                    and str(self.config.get("community_agent_provider_id", "")).strip())

    async def sync(self, worker, *, schedule=True):
        try:
            async with self.network_slots:
                result = await self._policy(worker)
                if result.get("bot") is None:
                    await self._cancel_round(worker)
                    worker.bot, worker.leased = None, False
                    return
                marker = self._marker(worker, result)
                if marker != worker.marker:
                    await self._cancel_round(worker)
                    worker.bot = result["bot"]
                    worker.agent = self._get_agent(worker, worker.bot)
                    worker.marker = marker
                    worker.agent.epoch += 1
                    worker.agent.public_call.expected_policy = marker[1]
                    worker.agent.publisher.runtime = lambda: self._publication_context(worker)
                worker.agent.publisher.controls = result
                if self._ready(worker) and worker.error == "service_unavailable":
                    # A recovered control request must not leave a completed round
                    # looking failed, or erase a genuine model/publication failure.
                    worker.state, worker.error = worker.last_round_state, worker.last_round_error
                state = worker.phase or worker.state
                if not self._ready(worker):
                    await self._cancel_round(worker)
                    if not worker.bot["enabled"] or worker.agent.paused:
                        state = "paused"
                    elif not str(self.config.get("community_agent_provider_id", "")).strip():
                        state, worker.error = "error", "provider_required"
                    elif not worker.bot["policy"].get("allowed_post_types"):
                        state = "scope_required"
                    else:
                        state = "disabled"
                await self._report(worker, state)
                worker.control_error = ""
                if schedule and self.config.get("community_auto_browse", False) is True and self._ready(worker) and not worker.round_task and self.monotonic() >= worker.agent.next_run:
                    worker.phase = "waiting"
                    worker.round_task = asyncio.create_task(self._browse(worker))
        except asyncio.CancelledError:
            raise
        except Exception as error:
            codes = {"bot_runtime_busy", "stale_bot_runtime", "invalid_bot_runtime", "runtime_unavailable",
                     "bot_policy_changed", "network_unavailable", "service_unavailable", "rate_limited",
                     "insufficient_scope", "authorization_changed", "reconnect_required", "authorization_pending"}
            worker.control_error = error.code if isinstance(error, IntegrationProblem) and error.code in codes else "control_request_failed"
            worker.leased = False
            await self._cancel_round(worker)
            worker.state, worker.error = "error", "service_unavailable"

    async def _report(self, worker, state):
        async with worker.report_lock:
            worker.sequence += 1
            delay = math.ceil(worker.agent.next_run - self.monotonic())
            if state == "loading" and delay <= 0:
                delay = worker.agent.interval()
            delay = max(0, min(86400, delay))
            result = await worker.client.call("POST", "/bot/runtime", payload={
                "session_id": worker.session, "sequence": worker.sequence, "revision": worker.bot["revision"],
                "state": state, "error_code": worker.error, "round_id": worker.round_id,
                "read_count": worker.read_count, "next_run_in_seconds": delay,
            })
            if result.get("accepted") is not True:
                raise IntegrationProblem("runtime_unavailable")
            worker.leased = state != "stopped"

    def _publication_context(self, worker):
        if (not worker.leased or not self._ready(worker) or worker.client.generation != worker.marker[0]
                or json.dumps(dict(self.config), sort_keys=True, ensure_ascii=False) != worker.marker[3]):
            raise IntegrationProblem("bot_runtime_required")
        return {"runtime_session_id": worker.session, "bot_revision": worker.bot["revision"]}

    async def _browse(self, worker):
        try:
            async with self.model_slots:
                current = await self._policy(worker)
                if not self._ready(worker) or current.get("bot") is None or self._marker(worker, current) != worker.marker:
                    raise IntegrationProblem("bot_policy_changed")
                worker.phase, worker.error = "loading", ""
                await self._report(worker, "loading")
                # Reserve the cooldown before any model or publication request, including crashes.
                with worker.agent.memory.db:
                    worker.agent.memory.db.execute("INSERT OR REPLACE INTO runtime_schedule VALUES (1,?,?)", (worker.bot["bot_user_id"], self.clock() + worker.agent.interval()))
                result = await worker.agent.browse(self.context)
                worker.state = result["state"]
                if worker.state not in {"completed", "empty", "error", "cooldown", "scope_required", "paused", "disabled"}:
                    worker.state = "error"
                worker.round_id, worker.read_count = str(uuid.uuid4()), result.get("read_count", 0)
                worker.error = "public_browse_failed" if worker.state == "error" else ""
                return result
        except asyncio.CancelledError:
            raise
        except Exception:
            worker.state, worker.error = "error", "public_browse_failed"
            return {"state": "error"}
        finally:
            worker.phase = ""
            if worker.error != "service_unavailable":
                worker.last_round_state, worker.last_round_error = worker.state, worker.error
            if worker.leased:
                try:
                    await self._report(worker, worker.state)
                except Exception:
                    worker.leased = False
            worker.round_task = None

    async def _cancel_round(self, worker):
        task = worker.round_task
        worker.round_task = None
        if worker.agent:
            worker.agent.epoch += 1
        if task and task is not asyncio.current_task():
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def browse_owner(self):
        await self.discover(start_workers=False)
        worker = self.workers.get(self.owner_client)
        if worker is None:
            return {"state": "scope_required"}
        if worker.round_task:
            return {"state": "busy"}
        worker.manual = True
        try:
            await self.sync(worker, schedule=False)
            if worker.round_task:
                return {"state": "busy"}
            if not self._ready(worker) or not worker.leased:
                return {"state": "disabled"}
            worker.round_task = asyncio.create_task(self._browse(worker))
            return await worker.round_task
        finally:
            worker.manual = False

    async def close(self):
        self.closed = True
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)
        for worker in self.workers.values():
            if worker.task:
                worker.task.cancel()
        await asyncio.gather(*(w.task for w in self.workers.values() if w.task), return_exceptions=True)
        for worker in self.workers.values():
            await self._cancel_round(worker)
            if worker.leased:
                try:
                    await asyncio.wait_for(self._report(worker, "stopped"), 3)
                except Exception:
                    pass
        agents = {self.owner_agent, *self.agents.values()}
        for agent in agents:
            await agent.close()

"""每个消息主体独立的安装标识与系统凭据库，不共享授权请求或刷新锁。"""
import hashlib
import json
import re
import uuid

from .client import BusinessClient, IntegrationProblem
from .credential_store import CredentialStore


class Accounts:
    def __init__(self, origin, platform, directory, *, limit=500):
        self.origin, self.platform, self.directory = origin, platform, directory
        self.limit, self.entries = limit, {}
        self.registered = {}
        namespace = hashlib.sha256(f"{origin}|{platform}".encode()).hexdigest()
        self.registry = directory / (namespace + ".accounts.json")

    def _index(self, *, validate=True):
        if not self.registry.exists():
            return {}
        try:
            if self.registry.stat().st_size > 128_000:
                raise ValueError()
            value = json.loads(self.registry.read_text(encoding="utf-8"))
            if not isinstance(value, dict) or len(value) > self.limit:
                raise ValueError()
            if validate:
                for identity, installation in value.items():
                    if not re.fullmatch(r"[a-f0-9]{64}", identity) or not isinstance(installation, str):
                        raise ValueError()
                    uuid.UUID(installation)
            return value
        except (ValueError, OSError):
            raise IntegrationProblem("local_binding_unavailable") from None

    def _remember(self, identity, installation):
        index = self._index()
        if identity not in index and len(index) >= self.limit:
            raise IntegrationProblem("local_account_limit")
        index[identity] = installation
        temporary = self.registry.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(index, sort_keys=True), encoding="utf-8")
        temporary.replace(self.registry)

    def restore(self):
        # The origin/platform-scoped index contains only opaque vault slots, never QQ IDs or tokens.
        failed = False
        for identity, installation in self._index(validate=False).items():
            if identity in self.registered:
                continue
            try:
                if not isinstance(identity, str) or not re.fullmatch(r"[a-f0-9]{64}", identity) or not isinstance(installation, str):
                    raise ValueError()
                installation = str(uuid.UUID(installation))
                saved = json.loads((self.directory / (identity + ".json")).read_text(encoding="utf-8"))
                if saved.get("installation_id") != installation:
                    raise ValueError()
                store = CredentialStore(identity)
                if store.load():
                    self.registered[identity] = (BusinessClient(self.origin, store), installation)
            except Exception:
                failed = True
                continue
        if failed:
            raise IntegrationProblem("local_binding_unavailable")

    def clients(self):
        return [(identity, client, installation) for identity, (client, installation) in self.registered.items()]

    def get(self, sender, bot_id="", *, create=True):
        if not isinstance(sender, str) or not sender or len(sender) > 100:
            raise IntegrationProblem("private_actor_required")
        key = (str(bot_id), sender)
        if key not in self.entries:
            identity = hashlib.sha256(f"{self.origin}|{self.platform}|{bot_id}|{sender}".encode()).hexdigest()
            path = self.directory / (identity + ".json")
            if not create and not path.exists():
                raise IntegrationProblem("connect_first")
            if len(self.entries) >= self.limit:
                raise IntegrationProblem("local_account_limit")
            try:
                if path.exists():
                    installation = str(uuid.UUID(json.loads(path.read_text(encoding="utf-8"))["installation_id"]))
                else:
                    installation = str(uuid.uuid4())
                    path.write_text(json.dumps({"installation_id": installation}), encoding="utf-8")
            except (OSError, ValueError, KeyError, TypeError):
                raise IntegrationProblem("local_binding_unavailable") from None
            if identity not in self.registered:
                self._remember(identity, installation)
                self.registered[identity] = BusinessClient(self.origin, CredentialStore(identity)), installation
            self.entries[key] = self.registered[identity]
        return self.entries[key]

    async def close(self):
        for client, _ in self.registered.values():
            await client.close()

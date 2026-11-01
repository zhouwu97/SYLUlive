"""每个消息主体独立的安装标识与系统凭据库，不共享授权请求或刷新锁。"""
import hashlib
import json
import uuid

from .client import BusinessClient, IntegrationProblem
from .credential_store import CredentialStore


class Accounts:
    def __init__(self, origin, platform, directory, *, limit=500):
        self.origin, self.platform, self.directory = origin, platform, directory
        self.limit, self.entries = limit, {}

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
            self.entries[key] = BusinessClient(self.origin, CredentialStore(identity)), installation
        return self.entries[key]

    async def close(self):
        for client, _ in self.entries.values():
            await client.close()

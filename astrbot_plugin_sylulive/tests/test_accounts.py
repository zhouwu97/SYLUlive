"""新用户独立凭据槽、重启恢复及旧 owner 凭据兼容。"""
from types import SimpleNamespace

import pytest

from astrbot_plugin_sylulive import accounts
from astrbot_plugin_sylulive.client import IntegrationProblem


def test_accounts_isolate_sender_and_bot_and_restore_installation(tmp_path, monkeypatch):
    created = []
    def client(origin, store):
        item = SimpleNamespace(origin=origin, store=store)
        created.append(item)
        return item
    monkeypatch.setattr(accounts, "CredentialStore", lambda identity: SimpleNamespace(identity=identity))
    monkeypatch.setattr(accounts, "BusinessClient", client)
    manager = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    a, installation = manager.get("222222", "333333")
    assert manager.get("222222", "333333") == (a, installation)
    b, _ = manager.get("444444", "333333")
    c, _ = manager.get("222222", "555555")
    assert len({x.store.identity for x in (a, b, c)}) == 3
    restored = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    a2, restored_installation = restored.get("222222", "333333", create=False)
    assert restored_installation == installation and a2.store.identity == a.store.identity
    for file in tmp_path.iterdir():
        value = __import__("json").loads(file.read_text())
        if file.name.endswith(".accounts.json"):
            assert set(value) == {x.store.identity for x in (a, b, c)}
            assert "222222" not in file.read_text()
        else:
            assert set(value) == {"installation_id"}
    with pytest.raises(IntegrationProblem, match="connect_first"):
        restored.get("666666", "333333", create=False)


def test_runtime_registry_restores_only_own_origin_slots_and_preserves_corruption(tmp_path, monkeypatch):
    vault = {}
    class Store:
        def __init__(self, identity): self.identity = identity
        def load(self): return vault.get(self.identity)
    monkeypatch.setattr(accounts, "CredentialStore", Store)
    monkeypatch.setattr(accounts, "BusinessClient", lambda origin, store: SimpleNamespace(tokens=store.load(), store=store))
    first = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    a, install = first.get("222222", "333333")
    vault[a.store.identity] = {"scope": "community:read", "access_token": "synthetic-secret"}
    restored = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    restored.restore()
    client, installation = restored.get("222222", "333333", create=False)
    assert installation == install and client.tokens == vault[a.store.identity]
    assert len(restored.clients()) == 1
    other = accounts.Accounts("https://other.invalid", "synthetic", tmp_path)
    other.restore()
    assert other.clients() == []
    assert "synthetic-secret" not in restored.registry.read_text()
    restored.registry.write_text("damaged", encoding="utf-8")
    with pytest.raises(IntegrationProblem, match="local_binding_unavailable"):
        restored.restore()
    assert restored.registry.read_text() == "damaged"


def test_one_damaged_registry_entry_does_not_stop_other_accounts(tmp_path, monkeypatch):
    import json
    class Store:
        def __init__(self, identity): self.identity = identity
        def load(self): return {"scope":"community:read"}
    monkeypatch.setattr(accounts, "CredentialStore", Store)
    monkeypatch.setattr(accounts, "BusinessClient", lambda origin, store: SimpleNamespace(tokens=store.load(), store=store))
    first = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    first.get("222222", "333333")
    first.get("444444", "333333")
    index = json.loads(first.registry.read_text())
    index = {"invalid-slot":"broken", **index}
    first.registry.write_text(json.dumps(index), encoding="utf-8")
    original = first.registry.read_text()
    restored = accounts.Accounts("https://fixture.invalid", "synthetic", tmp_path)
    with pytest.raises(IntegrationProblem, match="local_binding_unavailable"):
        restored.restore()
    assert len(restored.clients()) == 2
    assert restored.get("222222", "333333", create=False)[0].tokens
    assert first.registry.read_text() == original

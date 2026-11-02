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
        assert set(__import__("json").loads(file.read_text())) == {"installation_id"}
    with pytest.raises(IntegrationProblem, match="connect_first"):
        restored.get("666666", "333333", create=False)

"""Real AstrBotConfig persistence with synthetic accounts, no external requests."""
import asyncio
import copy
import json
import time
from unittest.mock import patch

import httpx
import jwt
import pytest

from astrbot.core.config.astrbot_config import AstrBotConfig
from astrbot_plugin_sylulive.permission_policy import DEFAULTS, PolicyError, document, save, snapshot, validate
from test_permission_console import console_fixture, native_app

PATH = "/api/plug/astrbot_plugin_sylulive/permissions/policy"


def writable(tmp_path):
    plugin, target, client = console_fixture()
    plugin.config = AstrBotConfig(str(tmp_path / "plugin.json"), default_config=copy.deepcopy(plugin.config))
    return plugin, target, client


def rule(**changes):
    return {"name": "合成公开查询禁止", "enabled": True, "effect": "deny", "subjects": "everyone",
            "capabilities": ["public_read"], "chat_types": ["group"], "group_ids": ["700000001"], **changes}


def auth(app):
    token = jwt.encode({"username": "synthetic-admin", "exp": time.time()+60}, app.state.jwt_secret, algorithm="HS256")
    return {"Authorization": "Bearer "+token}


def test_real_sdk_save_reload_immediate_enforcement_and_other_config_preserved(tmp_path):
    plugin, target, client = writable(tmp_path)
    plugin.config.save_config({"community_persona": "LEGACY-IGNORED", "community_agent_enabled": True,
                               "community_agent_provider_id": "existing-native-provider"})
    before = snapshot(plugin.config)
    policy = copy.deepcopy(before["policy"])
    policy["access_rules"].append(rule())
    result = save(plugin.config, {"revision": before["revision"], "policy": policy})
    assert result["revision"] != before["revision"]
    reloaded = AstrBotConfig(plugin.config.config_path, default_config=copy.deepcopy(dict(plugin.config)))
    assert document(reloaded) == result["policy"]
    assert reloaded["community_persona"] == "LEGACY-IGNORED"
    assert reloaded["community_agent_provider_id"] == "existing-native-provider"
    from astrbot_plugin_sylulive.permission_console import preview
    assert next(r for r in preview(plugin, target)["items"] if r["action"] == "public_read")["state"] == "denied"
    client.call.assert_not_called()
    plugin.client.call.assert_not_called()


def test_policy_conflict_preserves_newer_config(tmp_path):
    plugin, _, _ = writable(tmp_path)
    before = snapshot(plugin.config)
    newer = copy.deepcopy(before["policy"])
    newer["allow_checkin"] = True
    current = save(plugin.config, {"revision": before["revision"], "policy": newer})
    with pytest.raises(PolicyError, match="policy_conflict") as caught:
        save(plugin.config, {"revision": before["revision"], "policy": before["policy"]})
    assert caught.value.status == 409 and snapshot(plugin.config) == current


def test_failed_atomic_disk_write_restores_memory_and_file(tmp_path):
    plugin, _, _ = writable(tmp_path)
    before = snapshot(plugin.config)
    disk = (tmp_path / "plugin.json").read_bytes()
    policy = copy.deepcopy(before["policy"])
    policy["access_default"] = "deny"
    with patch("astrbot.core.config.astrbot_config.os.replace", side_effect=OSError("synthetic failure")):
        with pytest.raises(PolicyError, match="policy_save_failed"):
            save(plugin.config, {"revision": before["revision"], "policy": policy})
    assert snapshot(plugin.config) == before
    assert (tmp_path / "plugin.json").read_bytes() == disk


@pytest.mark.parametrize("change", [
    {"community_persona": "not-allowed-here"}, {"admins_id": ["900000002"]}, {"scope": "*"},
    {"allow_checkin": 1}, {"group_personal_delivery": "invalid"}, {"public_read_group_ids": ["group"]},
    {"access_rules": [rule(enabled=False, subjects="specified_users", user_ids=[])]},
    {"access_rules": [rule(user_ids=["900000002", "900000002"])]},
    {"access_rules": [rule(capabilities=["run_shell"])]},
    {"access_rules": [rule(chat_types=["private"])]},
    {"access_rules": [rule(is_admin=True)]},
    {"access_rules": [rule(__template_key="wrong")]},
])
def test_invalid_policy_and_extra_authority_rejected(change):
    with pytest.raises(PolicyError):
        validate(copy.deepcopy(DEFAULTS) | change)


@pytest.mark.asyncio
async def test_native_api_persists_but_never_accepts_cross_origin_or_extra_authority(tmp_path):
    plugin, target, client = writable(tmp_path)
    app = native_app(plugin)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as h:
        assert (await h.get(PATH)).status_code == 401
        assert (await h.post(PATH, json={})).status_code == 401
        h.headers.update(auth(app))
        before = (await h.get(PATH)).json()
        policy = copy.deepcopy(before["policy"])
        policy["access_rules"].append(rule())
        body = {"revision": before["revision"], "policy": policy}
        for origin in ["https://evil.invalid", "null", "http://[", "http://test@evil.invalid", "http://test/path"]:
            assert (await h.post(PATH, json=body, headers={"Origin": origin})).status_code == 403
        assert (await h.post(PATH, content=b"{}", headers={"Content-Type": "text/plain"})).status_code == 415
        assert (await h.post(PATH, content=b"x"*262145, headers={"Content-Type": "application/json"})).status_code == 413
        assert (await h.post(PATH, json=body | {"is_admin": True})).status_code == 422
        # Draft preview executes exactly the same policy but never changes it.
        result = await h.post(PATH.replace("policy", "preview"), json={"target": target, "policy": policy})
        assert result.status_code == 200
        assert result.json()["items"][0]["state"] == "denied"
        assert snapshot(plugin.config)["revision"] == before["revision"]
        result = await h.post(PATH, json=body, headers={"Origin": "http://test"})
        assert result.status_code == 200 and result.headers["cache-control"] == "no-store"
        assert (await h.post(PATH, json=body)).status_code == 409
        assert json.loads((tmp_path / "plugin.json").read_text(encoding="utf-8-sig"))["access_rules"][-1]["effect"] == "deny"
        assert "SYNTHETIC-ACCESS" not in result.text and "refresh_token" not in result.text
    client.call.assert_not_called()


@pytest.mark.asyncio
async def test_simultaneous_saved_revisions_only_one_wins(tmp_path):
    plugin, _, _ = writable(tmp_path)
    app = native_app(plugin)
    before = snapshot(plugin.config)
    first, second = copy.deepcopy(before["policy"]), copy.deepcopy(before["policy"])
    first["allow_checkin"], second["allow_personal_queries"] = True, False
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test", headers=auth(app)) as h:
        results = await asyncio.gather(*(h.post(PATH, json={"revision": before["revision"], "policy": p}) for p in [first, second]))
    assert sorted(r.status_code for r in results) == [200, 409]

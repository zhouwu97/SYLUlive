import asyncio
import uuid
import httpx
import pytest
from astrbot_plugin_sylulive.client import (
    BusinessClient,
    IntegrationProblem,
    checked_origin,
)


class Store:
    def __init__(self):
        self.value = None

    def load(self):
        return self.value

    def save(self, value):
        self.value = value

    def delete(self):
        self.value = None


def tokens():
    return {
        "access_token": "sa_synthetic",
        "refresh_token": "sr_synthetic",
        "expires_in": 600,
        "scope": "community:read",
    }


@pytest.mark.parametrize(
    "origin",
    [
        "http://remote.invalid",
        "https://host/a",
        "https://name:pass@host",
        "https://host?x=1",
        "https://host/#frag",
        "file:///tmp/x",
    ],
)
def test_origin_rejects_token_redirect_targets(origin):
    with pytest.raises(ValueError):
        checked_origin(origin)


@pytest.mark.asyncio
async def test_device_flow_and_no_secret_returned():
    requests = []

    def respond(request):
        requests.append(request)
        if request.url.path.endswith("device_authorization"):
            return httpx.Response(
                200,
                json={
                    "device_code": "sd_private",
                    "user_code": "ABCD-1234",
                    "expires_in": 600,
                    "interval": 5,
                    "verification_uri_complete": "https://fixture.invalid/web/connected-apps?user_code=ABCD-1234",
                },
            )
        if request.url.path.endswith("token"):
            return httpx.Response(200, json=tokens())
        return httpx.Response(200, json={"account": {"id": 1}})

    store = Store()
    client = BusinessClient(
        "https://fixture.invalid", store, transport=httpx.MockTransport(respond)
    )
    try:
        result = await client.begin(str(uuid.uuid4()), "测试安装", False)
        assert "sd_private" not in str(result)
        with pytest.raises(IntegrationProblem, match="poll_later"):
            await client.poll()
        client.pending["next"] = 0
        await client.poll()
        assert client.pending is None and store.value["refresh_token"] == "sr_synthetic"
        assert (await client.call("GET", "/binding"))["account"]["id"] == 1
        assert requests[-1].headers["Authorization"] == "Bearer sa_synthetic"
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_refresh_is_single_flight_and_ambiguous_result_clears_tokens():
    refreshes = 0

    async def respond(request):
        nonlocal refreshes
        if request.url.path.endswith("token"):
            refreshes += 1
            await asyncio.sleep(0.01)
            return httpx.Response(200, json=tokens())
        return httpx.Response(200, json={"ok": True})

    store = Store()
    client = BusinessClient(
        "https://fixture.invalid", store, transport=httpx.MockTransport(respond)
    )
    try:
        client._save(tokens())
        client.tokens["expires_at"] = 0
        await asyncio.gather(*[client.call("GET", "/binding") for _ in range(8)])
        assert refreshes == 1
        await client.http.aclose()

        def fail(request):
            raise httpx.ReadTimeout("synthetic")

        client.http = httpx.AsyncClient(
            base_url=client.origin, transport=httpx.MockTransport(fail)
        )
        client.tokens["expires_at"] = 0
        with pytest.raises(IntegrationProblem, match="reconnect_required"):
            await client.call("GET", "/binding")
        assert client.tokens is None and store.value is None
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_no_redirect_and_no_remote_body_or_token_in_errors():
    for response in [
        httpx.Response(302, headers={"location": "https://other.invalid"}),
        httpx.Response(500, json={"error": "danger sa_secret with html"}),
    ]:
        client = BusinessClient(
            "https://fixture.invalid",
            Store(),
            transport=httpx.MockTransport(lambda req: response),
        )
        client._save(tokens())
        try:
            with pytest.raises(IntegrationProblem) as problem:
                await client.call("GET", "/binding")
            assert "sa_secret" not in str(problem.value) and "danger" not in str(
                problem.value
            )
        finally:
            await client.close()


@pytest.mark.asyncio
async def test_disconnect_failure_does_not_claim_revocation():
    client = BusinessClient(
        "https://fixture.invalid",
        Store(),
        transport=httpx.MockTransport(
            lambda r: httpx.Response(503, json={"error": "service_unavailable"})
        ),
    )
    client._save(tokens())
    try:
        with pytest.raises(IntegrationProblem):
            await client.disconnect()
        assert client.tokens is not None
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("old_status", [200, 401])
async def test_old_response_cannot_clear_or_return_data_after_reconnection(old_status):
    started, release = asyncio.Event(), asyncio.Event()

    async def respond(request):
        if request.url.path.endswith("/binding"):
            started.set()
            await release.wait()
            return httpx.Response(
                old_status, json={"code": "invalid_token", "account": "old"}
            )
        if request.url.path.endswith("device_authorization"):
            return httpx.Response(
                200,
                json={
                    "device_code": "sd_new",
                    "user_code": "NEW1-NEW2",
                    "expires_in": 600,
                    "interval": 5,
                    "verification_uri_complete": "https://fixture.invalid/web/connected-apps?user_code=NEW1-NEW2",
                },
            )
        if request.url.path.endswith("token"):
            return httpx.Response(
                200,
                json={**tokens(), "access_token": "sa_new", "refresh_token": "sr_new"},
            )
        return httpx.Response(200, json={})

    store = Store()
    client = BusinessClient(
        "https://fixture.invalid", store, transport=httpx.MockTransport(respond)
    )
    try:
        client._save(tokens())
        old = asyncio.create_task(client.call("GET", "/binding"))
        await started.wait()
        await client.disconnect()
        await client.begin(str(uuid.uuid4()), "新的合成安装", False)
        client.pending["next"] = 0
        await client.poll()
        release.set()
        with pytest.raises(IntegrationProblem):
            await old
        assert client.tokens is not None and client.tokens["access_token"] == "sa_new"
        assert store.value["refresh_token"] == "sr_new"
    finally:
        release.set()
        await client.close()


@pytest.mark.asyncio
async def test_old_access_error_after_refresh_preserves_current_credentials():
    started, release = asyncio.Event(), asyncio.Event()

    async def respond(request):
        if request.url.path.endswith("/token"):
            return httpx.Response(
                200,
                json={
                    **tokens(),
                    "access_token": "sa_refreshed",
                    "refresh_token": "sr_refreshed",
                },
            )
        if request.headers.get("Authorization") == "Bearer sa_synthetic":
            started.set()
            await release.wait()
            return httpx.Response(401, json={"code": "invalid_token"})
        return httpx.Response(200, json={"ok": True})

    store = Store()
    client = BusinessClient(
        "https://fixture.invalid", store, transport=httpx.MockTransport(respond)
    )
    try:
        client._save(tokens())
        old = asyncio.create_task(client.call("GET", "/binding"))
        await started.wait()
        client.tokens["expires_at"] = 0
        assert (await client.call("GET", "/binding"))["ok"]
        release.set()
        with pytest.raises(IntegrationProblem):
            await old
        assert (
            client.tokens is not None
            and client.tokens["access_token"] == "sa_refreshed"
        )
        assert store.value["refresh_token"] == "sr_refreshed"
    finally:
        release.set()
        await client.close()


@pytest.mark.asyncio
async def test_waiting_old_call_does_not_read_new_authorization():
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(200, json={"account": "new"})

    client = BusinessClient(
        "https://fixture.invalid", Store(), transport=httpx.MockTransport(respond)
    )
    try:
        client._save(tokens())
        await client.lock.acquire()
        old = asyncio.create_task(client.call("GET", "/binding"))
        await asyncio.sleep(0)
        client.clear()
        client._save({**tokens(), "access_token": "sa_new", "refresh_token": "sr_new"})
        client.lock.release()
        with pytest.raises(IntegrationProblem, match="authorization_changed"):
            await old
        assert not requests
        assert client.tokens["access_token"] == "sa_new"
    finally:
        await client.close()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "code,clears",
    [
        ("invalid_token", True),
        ("authorization_changed", True),
        ("academic_verification_required", True),
        ("account_unavailable", True),
        ("insufficient_scope", False),
    ],
)
async def test_current_authorization_errors_still_clear_only_when_required(
    code, clears
):
    store = Store()
    client = BusinessClient(
        "https://fixture.invalid",
        store,
        transport=httpx.MockTransport(
            lambda r: httpx.Response(403, json={"code": code})
        ),
    )
    try:
        client._save(tokens())
        with pytest.raises(IntegrationProblem, match=code):
            await client.call("GET", "/binding")
        assert (client.tokens is None) == clears
        assert (store.value is None) == clears
    finally:
        await client.close()

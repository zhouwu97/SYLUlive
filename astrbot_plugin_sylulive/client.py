"""Business client. Tokens never enter tool arguments/results or exception messages."""

import asyncio
import json
import time
from urllib.parse import urlsplit
import httpx

CLIENT_ID = "sylulive-astrbot"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"


class IntegrationProblem(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def checked_origin(raw):
    parsed = urlsplit(raw)
    if (
        not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("服务地址必须是完整 origin，不含路径、凭证或查询参数")
    if parsed.scheme != "https" and not (
        parsed.scheme == "http" and parsed.hostname in ("localhost", "127.0.0.1", "::1")
    ):
        raise ValueError("远程服务必须使用 HTTPS")
    return raw.rstrip("/")


class BusinessClient:
    def __init__(self, origin, store, *, transport=None):
        self.origin = checked_origin(origin)
        self.store = store
        self.tokens = store.load()
        self.http = httpx.AsyncClient(
            base_url=self.origin,
            timeout=15,
            follow_redirects=False,
            transport=transport,
            trust_env=False,
        )
        self.lock = asyncio.Lock()
        self.pending = None
        self.generation = 0

    async def close(self):
        await self.http.aclose()

    async def _request(self, method, path, **kwargs):
        # Paths are plugin constants, never model-supplied URLs.
        try:
            response = await self.http.request(method, path, **kwargs)
        except httpx.HTTPError:
            raise IntegrationProblem("network_unavailable") from None
        if response.is_redirect:
            raise IntegrationProblem("redirect_refused")
        if len(response.content) > 300_000:
            raise IntegrationProblem("response_too_large")
        try:
            body = response.json() if response.content else {}
        except (ValueError, json.JSONDecodeError):
            raise IntegrationProblem("invalid_response") from None
        if not isinstance(body, dict):
            raise IntegrationProblem("invalid_response")
        if response.is_error:
            code = body.get("error") or body.get("code")
            # Only stable machine codes; never echo a remote error body or HTML.
            if (
                not isinstance(code, str)
                or not code.replace("_", "").isalnum()
                or len(code) > 80
            ):
                code = "service_unavailable"
            raise IntegrationProblem(code)
        return body

    async def begin(self, installation_id, name, proposals):
        async with self.lock:
            if self.pending and self.pending["deadline"] > time.monotonic():
                raise IntegrationProblem("authorization_pending")
            if self.tokens:
                raise IntegrationProblem("already_connected")
            scope = "profile:read_minimal community:read content:read_own_public actions:read_own"
            if proposals:
                scope += " community:propose"
            body = await self._request(
                "POST",
                "/api/oauth/device_authorization",
                data={
                    "client_id": CLIENT_ID,
                    "scope": scope,
                    "installation_id": installation_id,
                    "installation_name": name,
                },
            )
            try:
                # Never send a device secret to a different verification site.
                uri = body["verification_uri_complete"]
                if (
                    checked_origin(f"{urlsplit(uri).scheme}://{urlsplit(uri).netloc}")
                    != self.origin
                ):
                    raise ValueError()
                self.pending = {
                    "device_code": body["device_code"],
                    "deadline": time.monotonic() + min(int(body["expires_in"]), 600),
                    "interval": max(int(body["interval"]), 5),
                    "next": time.monotonic() + max(int(body["interval"]), 5),
                }
                return {"user_code": body["user_code"], "verification_uri": uri}
            except (KeyError, TypeError, ValueError):
                raise IntegrationProblem("invalid_response") from None

    def _save(self, body):
        if (
            not isinstance(body.get("access_token"), str)
            or not body["access_token"].startswith("sa_")
            or not isinstance(body.get("refresh_token"), str)
            or not body["refresh_token"].startswith("sr_")
        ):
            raise IntegrationProblem("invalid_response")
        self.tokens = {
            "access_token": body["access_token"],
            "refresh_token": body["refresh_token"],
            "expires_at": time.time() + int(body["expires_in"]),
            "scope": body["scope"],
        }
        self.store.save(self.tokens)

    async def poll(self):
        async with self.lock:
            pending = self.pending
            if not pending or pending["deadline"] <= time.monotonic():
                self.pending = None
                raise IntegrationProblem("authorization_expired")
            if pending["next"] > time.monotonic():
                raise IntegrationProblem("poll_later")
            pending["next"] = time.monotonic() + pending["interval"]
            try:
                body = await self._request(
                    "POST",
                    "/api/oauth/token",
                    data={
                        "client_id": CLIENT_ID,
                        "grant_type": DEVICE_GRANT,
                        "device_code": pending["device_code"],
                    },
                )
            except IntegrationProblem as error:
                if error.code == "slow_down":
                    pending["interval"] += 5
                    pending["next"] = time.monotonic() + pending["interval"]
                elif error.code not in ("authorization_pending", "network_unavailable"):
                    self.pending = None
                raise
            self._save(body)
            self.pending = None

    async def _access(self):
        async with self.lock:
            if not self.tokens:
                raise IntegrationProblem("connect_first")
            if self.tokens["expires_at"] > time.time() + 30:
                return self.tokens["access_token"]
            old = self.tokens["refresh_token"]
            try:
                body = await self._request(
                    "POST",
                    "/api/oauth/token",
                    data={
                        "client_id": CLIENT_ID,
                        "grant_type": "refresh_token",
                        "refresh_token": old,
                    },
                )
                self._save(body)
            except IntegrationProblem:
                # An ambiguous refresh cannot safely reuse a rotated credential.
                self.clear()
                raise IntegrationProblem("reconnect_required") from None
            return self.tokens["access_token"]

    async def call(self, method, path, *, params=None, payload=None):
        generation = self.generation
        access = await self._access()
        if generation != self.generation:
            raise IntegrationProblem("authorization_changed")
        try:
            result = await self._request(
                method,
                "/api/integrations/v1" + path,
                headers={"Authorization": "Bearer " + access},
                params=params,
                json=payload,
            )
        except IntegrationProblem as error:
            async with self.lock:
                if generation != self.generation:
                    raise IntegrationProblem("authorization_changed") from None
                # 旧 access 的错误也不能清除同一授权刚轮换出的新凭证。
                if (
                    self.tokens
                    and self.tokens["access_token"] == access
                    and error.code
                    in (
                        "invalid_token",
                        "authorization_changed",
                        "academic_verification_required",
                        "account_unavailable",
                    )
                ):
                    self.clear()
            raise
        async with self.lock:
            if generation != self.generation:
                raise IntegrationProblem("authorization_changed")
        return result

    def clear(self):
        self.generation += 1
        self.tokens = None
        self.pending = None
        try:
            self.store.delete()
        except RuntimeError:
            raise IntegrationProblem("local_credential_cleanup_failed") from None

    async def disconnect(self):
        async with self.lock:
            raw = self.tokens.get("refresh_token") if self.tokens else None
            if raw:
                # If this fails, keep the credential for a safe retry and tell the user.
                await self._request(
                    "POST",
                    "/api/oauth/revoke",
                    data={"client_id": CLIENT_ID, "token": raw},
                )
            self.clear()

"""Business client. Tokens never enter tool arguments/results or exception messages."""

import asyncio
import json
import re
import time
from urllib.parse import urlsplit

import httpx

CLIENT_ID = "sylulive-astrbot"
DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"
MAP_PATH = "/web/assets/campus-map.png"


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
        # 与授权客户端隔离 Cookie 罐；公共请求也不继承服务端 Set-Cookie。
        self.public_http = httpx.AsyncClient(
            base_url=self.origin, timeout=15, follow_redirects=False,
            transport=transport, trust_env=False,
        )
        self.lock = asyncio.Lock()
        self.pending = None
        self.generation = 0

    async def close(self):
        await self.http.aclose()
        await self.public_http.aclose()

    async def _request(self, method, path, *, anonymous=False, **kwargs):
        # Paths are plugin constants, never model-supplied URLs.
        try:
            if anonymous:
                request = self.public_http.build_request(method, path, **kwargs)
                request.headers.pop("cookie", None)
                request.headers.pop("authorization", None)
                response = await self.public_http.send(request)
            else:
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

    async def begin(self, installation_id, name, proposals, *, checkin=False, bot_reply=False, bot_post=False, personal=False, community_read=False):
        async with self.lock:
            if self.pending:
                if self.pending["deadline"] <= time.monotonic() or self.pending.get("terminal"):
                    # 本人重新发起时只撤销旧设备请求；失败保留秘密和原连接供安全重试。
                    await self._request("POST", "/api/oauth/device_authorization/cancel",
                        data={"client_id": CLIENT_ID, "device_code": self.pending["device_code"]})
                    self.pending = None
                    self.generation += 1
                else:
                    raise IntegrationProblem("authorization_pending" if self.pending["deadline"] > time.monotonic() else "authorization_expired")
            scope = "profile:read_minimal content:read_own_public actions:read_own"
            if proposals or bot_reply or bot_post:
                scope += " community:read community:propose"
            elif community_read:
                scope += " community:read"
            if bot_reply:
                scope += " community:bot_reply"
            if bot_post:
                scope += " community:bot_post"
            if checkin:
                scope += " checkin:write"
            if personal:
                scope += " academic:grades:read academic:erke:read"
            upgrading = self.tokens is not None
            # 所有功能都按实际 scope 比较，签到／教务权限也可由本人补充申请。
            if upgrading and set(scope.split()).issubset(set(self.tokens.get("scope", "").split())):
                raise IntegrationProblem("already_connected")
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
                    "upgrade": upgrading,
                }
                if upgrading:
                    self.generation += 1
                return {"user_code": body["user_code"], "verification_uri": uri, "upgrade": upgrading}
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

    async def poll(self, *, expected=None, wait=True):
        # 用户命令可等待下一次合法查询，不要求本人反复发送状态/签到命令。
        pending = self.pending if expected is None else expected
        generation = self.generation
        while True:
            if wait and pending is not None and self.pending is pending:
                delay = min(pending["next"], pending["deadline"]) - time.monotonic()
                if delay > 0:
                    await asyncio.sleep(delay)
            try:
                completed = await self._poll_once(expected=pending)
                if self.generation != generation and (pending is None or pending.get("completed_generation") != self.generation):
                    raise IntegrationProblem("authorization_changed")
                return completed
            except IntegrationProblem as error:
                if not wait or error.code != "poll_later":
                    raise

    async def _poll_once(self, *, expected=None):
        async with self.lock:
            pending = self.pending
            if expected is not None and pending is not expected:
                if pending is None and self.tokens:
                    return self.generation
                raise IntegrationProblem("authorization_changed")
            if pending is None and self.tokens:
                return self.generation
            if not pending or pending["deadline"] <= time.monotonic():
                raise IntegrationProblem("authorization_expired")
            if pending["next"] > time.monotonic():
                raise IntegrationProblem("poll_later")
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
                if error.code in ("access_denied", "expired_token", "authorization_expired"):
                    pending["terminal"] = True
                # 终止状态仍保留设备秘密，供本人明确解绑时撤销已批准／不确定的请求。
                raise
            finally:
                # 从响应结束计时，避免网络往返/服务端排队被误算进轮询间隔，触发累积 slow_down。
                pending["next"] = time.monotonic() + pending["interval"]
            if self.pending is not pending:
                raise IntegrationProblem("authorization_changed")
            self._save(body)
            self.pending = None
            if pending.get("upgrade"):
                self.generation += 1
            pending["completed_generation"] = self.generation
            return self.generation

    async def _access(self):
        async with self.lock:
            if self.pending and self.pending.get("upgrade") and not self.pending.get("terminal"):
                # 官网可能已替换旧授权但尚未领到新凭据，不能用旧401清掉待领取的请求。
                raise IntegrationProblem("authorization_pending")
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

    async def refresh_scope(self):
        # 官网可原地修改连接权限而不换凭证；本地缓存的 scope 缺项时先轮换一次取得最新范围。
        async with self.lock:
            if self.tokens:
                self.tokens["expires_at"] = 0
        await self._access()
        return (self.tokens or {}).get("scope", "")

    async def call(self, method, path, *, params=None, payload=None, files=None):
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
                **({"files": files} if files is not None else {"json": payload}),
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

    async def public_call(self, path, *, params=None):
        # 匿名公开接口绝不携带绑定账号的令牌或浏览器 Cookie。
        if path not in (
            "/api/canteens/rankings",
            "/api/canteens/search",
            "/api/campus/articles",
            "/api/campus/articles/latest",
            "/api/campus-calendars/current",
        ) and not any(
            re.fullmatch(pattern, path)
            for pattern in (
                r"/api/canteens/[1-9]\d*",
                r"/api/canteens/[1-9]\d*/dishes(?:/[1-9]\d*)?",
                r"/api/campus/articles/[1-9]\d*",
                r"/api/campus-calendars/\d{4}-\d{4}",
                r"/api/integrations/v1/public/community/(?:posts(?:/[1-9]\d*(?:/replies)?)?|replies/[1-9]\d*/context|stickers|sections)",
            )
        ):
            raise IntegrationProblem("public_path_refused")
        if path.endswith("/dishes"):
            body = await self._public_request(path, params)
            if not isinstance(body, list):
                raise IntegrationProblem("invalid_response")
            return {"items": body}
        return await self._request("GET", path, params=params, anonymous=True)

    async def _public_request(self, path, params):
        try:
            request = self.public_http.build_request("GET", path, params=params)
            request.headers.pop("cookie", None)
            request.headers.pop("authorization", None)
            response = await self.public_http.send(request)
        except httpx.HTTPError:
            raise IntegrationProblem("network_unavailable") from None
        if response.is_redirect or response.is_error or len(response.content) > 300_000:
            raise IntegrationProblem("public_read_failed")
        try:
            return response.json()
        except ValueError:
            raise IntegrationProblem("invalid_response") from None

    async def public_image(self, path):
        if path != MAP_PATH and (
            not isinstance(path, str)
            or not path.startswith("/uploads/")
            or any(v in path for v in ("..", "\\", "?", "#", "%"))
        ):
            raise IntegrationProblem("public_image_refused")
        try:
            request = self.public_http.build_request("GET", path)
            request.headers.pop("cookie", None)
            request.headers.pop("authorization", None)
            response = await self.public_http.send(request, stream=True)
            try:
                if response.is_redirect or response.is_error:
                    raise IntegrationProblem("public_image_unavailable")
                mime = response.headers.get("content-type", "").split(";", 1)[0]
                if mime not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
                    raise IntegrationProblem("unsupported_image")
                data = bytearray()
                async for part in response.aiter_bytes():
                    data.extend(part)
                    # 官网原始地图约4.4MB；仅该固定公开资源允许8MiB，其他图片仍4MiB。
                    if len(data) > (8 if path == MAP_PATH else 4) * 1024 * 1024:
                        raise IntegrationProblem("image_too_large")
                return bytes(data)
            finally:
                await response.aclose()
        except httpx.HTTPError:
            raise IntegrationProblem("network_unavailable") from None

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
            if self.pending:
                # 不能只丢弃本机状态：旧链接可能已被官网批准但尚未领到token。
                await self._request(
                    "POST", "/api/oauth/device_authorization/cancel",
                    data={"client_id": CLIENT_ID, "device_code": self.pending["device_code"]},
                )
            raw = self.tokens.get("refresh_token") if self.tokens else None
            if raw:
                # If this fails, keep the credential for a safe retry and tell the user.
                await self._request(
                    "POST",
                    "/api/oauth/revoke",
                    data={"client_id": CLIENT_ID, "token": raw},
                )
            self.clear()

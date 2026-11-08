"""Only the server-bound bot can read community sources for the public agent."""

import json
import re

from .client import IntegrationProblem


class ManagedBotAccess:
    def __init__(self, client):
        self.client = client
        self.expected_policy = None

    async def _policy(self):
        result = await self.client.call("GET", "/bot/policy")
        bot = result.get("bot") if isinstance(result, dict) else None
        policy = bot.get("policy") if isinstance(bot, dict) else None
        if (not isinstance(policy, dict) or bot.get("enabled") is not True
                or type(bot.get("bot_user_id")) is not int
                or policy.get("public_read_enabled") is not True
                or not isinstance(policy.get("allowed_post_types"), list)
                or not policy["allowed_post_types"]
                or any(not isinstance(x, str) or not x for x in policy["allowed_post_types"])):
            raise IntegrationProblem("bot_read_disabled")
        marker = json.dumps(bot, sort_keys=True, ensure_ascii=False)
        if self.expected_policy is not None and marker != self.expected_policy:
            raise IntegrationProblem("bot_policy_changed")
        return marker

    async def __call__(self, path, *, params=None):
        prefix = "/api/integrations/v1/public"
        if not isinstance(path, str) or not re.fullmatch(
            re.escape(prefix) + r"/community/(?:posts(?:/[1-9]\d*(?:/replies)?)?|replies/[1-9]\d*/context|stickers|sections)", path
        ):
            raise IntegrationProblem("public_path_refused")
        generation = self.client.generation
        policy = await self._policy()
        # 认证读取仍使用同一个公开列白名单 Reader，服务端在读前执行机器人版块权限。
        result = await self.client.call("GET", path[len(prefix):], params=params)
        if policy != await self._policy() or generation != self.client.generation:
            raise IntegrationProblem("bot_policy_changed")
        return result

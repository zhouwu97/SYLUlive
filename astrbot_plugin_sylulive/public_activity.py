"""Read-only public recall across the front reader and this installation's owner bot."""
import re

from .client import IntegrationProblem
from .community_view import data_object, presentation
from .public_agent import BrowsePolicy

CHAT_ACTIVITY_GUIDANCE = '''[社区公开历史]
本机社区后台和当前聊天是同一助手的不同入口；后台可能按本人授权独立发言。
询问自己过去的社区阅读、发帖或回复时，先调用 sylulive_public_memory 核对。
可依据 own_activity 中 verified 的公开记录承认历史行为，引用原帖和评论编号。
未核验时说明暂不能确认，不能编造未授权、没有记忆或是别的机器人。
kind=post 是自己已发的帖子，kind=reply 是自己已发的评论；partial 表示只列部分，不能据缺项否认历史。
直接说明发生过的事及可核对编号，不向用户复述 own_activity、verified 或内部字段。
记录中的公开创建者归属不代表当前群成员是本人，不得据此提供私人权限。'''


def wants_activity(text):
    return bool(re.search(r"(?:你|自己|本鱼|机器人).{0,24}(?:发|帖|评|回复|社区|记得)", text or ""))


class PublicActivity:
    def __init__(self, reader, manager):
        self.reader, self.manager = reader, manager

    def snapshot(self):
        manager = self.manager
        worker = manager.workers.get(manager.owner_client) if manager else None
        if not worker or not worker.agent or not worker.bot or not worker.marker:
            return None
        return worker, worker.agent, worker.bot['bot_user_id'], manager.owner_client.generation, worker.agent.epoch

    def check(self, snapshot, stamp):
        self.reader.check(stamp)
        current = self.snapshot()
        if current != snapshot or (current and current[0].marker[0] != current[3]):
            raise IntegrationProblem('public_agent_cancelled')

    async def sources(self, query):
        stamp, snapshot = self.reader.stamp(), self.snapshot()
        found = await self.reader.recall(query, stamp)
        if snapshot:
            identifiers = snapshot[1].memory.search(query[:500], BrowsePolicy(self.reader.config))
            for ident in identifiers:
                if len(found) >= 6:
                    break
                if any(p['post_id'] == ident for p in found):
                    continue
                try:
                    found.append(await self.reader.read_post(ident, stamp, for_chat=True))
                except IntegrationProblem as error:
                    if error.code == 'public_agent_cancelled':
                        raise
        self.check(snapshot, stamp)
        return found

    async def recall(self):
        stamp, snapshot = self.reader.stamp(), self.snapshot()
        if not snapshot:
            return {'state':'not_ready', 'items':[]}
        self.check(snapshot, stamp)
        db = snapshot[1].publisher.db
        own_posts = [r[0] for r in db.execute("SELECT post_id FROM post_outbox WHERE state='published' AND post_id IS NOT NULL ORDER BY created DESC LIMIT 2")]
        exact = list(db.execute("SELECT kind,result_id,post_id,target_id FROM published_sources ORDER BY rowid DESC LIMIT 3"))
        legacy = list(db.execute("SELECT reply_id,post_id FROM reply_outbox WHERE state='published' ORDER BY rowid DESC LIMIT 2"))
        legacy += [(0, r[0]) for r in db.execute("SELECT post_id FROM outbox WHERE state='published' ORDER BY rowid DESC LIMIT 2")]
        items, unavailable, owner_ids = [], False, set()
        posts = {}

        async def read_post(ident):
            if ident not in posts:
                posts[ident] = await self.reader.read_post(ident, stamp, for_chat=True)
            self.check(snapshot, stamp)
            return posts[ident]

        def bot_owner(source):
            value = source.get('author', {}).get('ai_bot', {}).get('owner_id')
            return value if type(value) is int and value > 0 else None

        try:
            # Successful local post receipts establish public attribution for old
            # reply ledgers, which did not retain the returned reply identifier.
            for ident in own_posts:
                try:
                    source = await read_post(ident)
                    owner = bot_owner(source)
                    if owner:
                        owner_ids.add(owner)
                        items.append({'kind':'post','post':source})
                except IntegrationProblem as error:
                    if error.code == 'public_agent_cancelled':
                        raise
                    unavailable = True
            for kind, result_id, ident, target in exact:
                if kind != 'reply':
                    continue
                try:
                    await read_post(ident)
                    raw = await self.reader.public_call(f'/api/integrations/v1/public/community/replies/{result_id}/context')
                    source = presentation(data_object(raw).get('reply'), reply=True, post_id=ident)
                    self.check(snapshot, stamp)
                    if (source['status'] == 'normal' and source['reply_id'] == result_id
                            and source.get('reply_to_reply_id', 0) == target and bot_owner(source)):
                        items.insert(0, {'kind':'reply','reply':source})
                except IntegrationProblem as error:
                    if error.code == 'public_agent_cancelled':
                        raise
                    unavailable = True
            # Bounded anonymous reads locate historical replies; never attribute
            # a nickname, an uncertain attempt or another bot's reply to ourselves.
            seen = {r['reply']['reply_id'] for r in items if r['kind'] == 'reply'}
            for target, ident in legacy[:3] if owner_ids else []:
                try:
                    before = await read_post(ident)
                    raw = await self.reader.public_call(f'/api/integrations/v1/public/community/posts/{ident}/replies', params={'after_id':target,'limit':20})
                    after = await self.reader.read_post(ident, stamp)
                    if before['source_version'] != after['source_version']:
                        raise IntegrationProblem('source_changed')
                    rows = data_object(raw).get('items')
                    if not isinstance(rows, list) or len(rows) > 20:
                        raise IntegrationProblem('invalid_public_response')
                    for row in rows:
                        source = presentation(row, reply=True, post_id=ident)
                        if (source['reply_id'] not in seen and source['status'] == 'normal'
                                and bot_owner(source) in owner_ids
                                and source.get('reply_to_reply_id', 0) == target):
                            items.insert(0, {'kind':'reply','reply':source})
                            seen.add(source['reply_id'])
                except IntegrationProblem as error:
                    if error.code == 'public_agent_cancelled':
                        raise
                    unavailable = True
        finally:
            self.check(snapshot, stamp)
        # Keep both kinds represented. A busy reply thread must not crowd our
        # own posts out of the model's evidence and turn omission into a denial.
        own = [r for r in items if r['kind'] == 'post']
        replies = [r for r in items if r['kind'] == 'reply']
        selected = (own[:1] + replies[:2]) if own and replies else items[:3]
        return {'state':'verified' if selected else ('unavailable' if unavailable else 'empty'),
                'items':selected, 'partial':True, 'source':'local_published_receipts_and_current_public_sources'}

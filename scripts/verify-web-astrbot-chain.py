"""Actual Go HTTP + Web UI + AstrBot SDK; invoked only by its disposable Go fixture.

No school/QQ login, production origin, keyring entry, paid model or group message.
"""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import time
import tempfile
from types import SimpleNamespace
from urllib.parse import urlsplit
import uuid

from astrbot_plugin_sylulive.client import BusinessClient, IntegrationProblem


class MemoryStore:
    persistent = False
    def load(self): return None
    def save(self, value): pass
    def delete(self): pass


async def web(action, code=""):
    env = {**os.environ, "SYLULIVE_FULL_CHAIN_CODE": code}
    result = await asyncio.to_thread(subprocess.run,
        ["node", str(Path(__file__).with_suffix(".mjs")), action],
        env=env, capture_output=True, text=True, encoding="utf-8", timeout=70,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name=="nt" else 0)
    assert result.returncode == 0, result.stderr[-5000:]
    assert json.loads(result.stdout.splitlines()[-1])["passed"]


async def autonomous_publication(client):
    from astrbot.api.star import Context
    from astrbot.api.provider import LLMResponse
    from astrbot.core.provider.provider import Provider
    from unittest.mock import AsyncMock
    from astrbot_plugin_sylulive.approved_media import ApprovedMedia
    from astrbot_plugin_sylulive.community_publisher import CommunityPublisher
    from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess
    from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory
    from test_bot_post_media import library

    reader=ManagedBotAccess(client)
    catalogue=await reader('/api/integrations/v1/public/community/stickers',params={'limit':20})
    sticker=catalogue['data']['items'][0]['sticker_id']
    with tempfile.TemporaryDirectory(prefix='sylulive-publication-qa-') as directory:
        base=Path(directory)
        media,row,_=library(base)
        for kind in ('post','reply'):
            class Model(Provider):
                def get_current_key(self): return 'synthetic-unused'
                def set_key(self,key): pass
                async def get_models(self): return ['synthetic']
                async def text_chat(self,**kwargs):
                    self.calls+=1
                    names={t.name for t in kwargs['func_tool'].tools}
                    assert not names.intersection({'send_meme','send_message','sylulive_grades','private_memory'})
                    if self.calls==1:
                        roles=[getattr(message,'role',None) for message in kwargs['contexts']]
                        assert roles==['system','user'],roles
                        assert 'private-history-sentinel' not in str(kwargs['contexts'])
                        name,args='read_public_post',{'post_id':1}
                    elif self.calls==2:
                        name,args='read_public_replies',{'post_id':1}
                    elif self.calls==3 and kind=='post':
                        name,args='publish_public_post',{'title':'合成自主讨论','content':'合成自主浏览后的公开分享','post_type':'campus_life','source_post_ids':[1],'image_ids':[row['id']]}
                    elif self.calls==3:
                        name,args='comment_public_post',{'post_id':1,'content':'合成自主评论','sticker_id':sticker}
                    else:
                        return LLMResponse(role='assistant',completion_text='合成公开操作完成')
                    assert name in names
                    return LLMResponse(role='assistant',tools_call_name=[name],tools_call_args=[args],tools_call_ids=[kind+'-'+str(self.calls)])
            model=Model({'id':'synthetic-provider','type':'synthetic'},{})
            model.calls=0
            context=Context.__new__(Context)
            context.provider_manager=SimpleNamespace(get_provider_by_id=AsyncMock(return_value=model))
            config={'community_agent_enabled':True,'community_allowed_sections':['campus_life'],'community_browse_topic':'跨端公开合成帖子','community_agent_provider_id':'synthetic-provider','community_auto_post':kind=='post','community_auto_comment':kind=='reply'}
            agent=PublicAgent(config,reader,PublicMemory(base/(kind+'.sqlite3')))
            agent.publisher=CommunityPublisher(agent,client,media=ApprovedMedia(media))
            try:
                result=await agent.browse(context)
                assert result['state']=='completed' and result['read_count']==1,(kind,result,model.calls)
                assert model.calls==4
            finally: await agent.close()


async def main():
    origin=os.environ["SYLULIVE_FULL_CHAIN_ORIGIN"]
    assert urlsplit(origin).hostname == "127.0.0.1"
    client=BusinessClient(origin,MemoryStore())
    steps=[]
    try:
        device=await client.begin(str(uuid.uuid4()),"跨端合成 AstrBot",True,personal=True,bot_reply=True,bot_post=True)
        await web("approve",device["user_code"])
        await asyncio.sleep(max(0,client.pending["next"]-time.monotonic())+.1)
        await client.poll()
        assert "academic:grades:read" in client.tokens["scope"]
        steps.append("web_device_authorization")
        await web("bot")
        steps.append("web_create_explicit_permissions_enable_bot")
        await web("sync")
        steps.append("web_preview_confirm_upload_grades_and_erke")
        grades=await client.call("GET","/me/grades",params={"offset":0,"limit":20})
        erke=await client.call("GET","/me/erke")
        assert grades["data"]["grades"][0]["course_name"] == "跨端合成课程"
        assert erke["data"]["summary"]["graduation"]["earned_total"]==12
        assert grades["data"]["live_query"] is False
        steps.append("python_client_real_http_readback")
        # SDK event, permission layer and deterministic command use the actual HTTP client.
        from test_persona_permissions import enabled
        plugin,event,_=enabled(group="",sender="owner")
        plugin.client=client
        plugin.accounts=SimpleNamespace(get=lambda *args,**kwargs:(client,"synthetic-installation"))
        for dataset in ("grades","erke"):
            text=await plugin.personal_result(event,dataset)
            assert ("你的已同步成绩" if dataset=="grades" else "你的已同步二课摘要") in text
            assert "非学校实时查询" in text
        steps.append("astrbot_sdk_private_query_with_real_backend")
        await autonomous_publication(client)
        steps.append("native_sdk_autonomous_browse_post_image_comment_sticker")
        from verify_multibot_runtime import verify_multi_account_runtime
        await verify_multi_account_runtime(client)
        steps.append("two_account_runtime_native_sdk_pause_isolation_post_comment_and_readback")
        try: await client.call("GET","/me/grades",params={"user_id":2})
        except IntegrationProblem as error: assert error.code=="invalid_request"
        else: raise AssertionError("Arbitrary target user accepted")
        steps.append("cross_user_request_rejected")
        old_refresh=client.tokens["refresh_token"]
        client.tokens["expires_at"]=0
        await asyncio.gather(client.call("GET","/binding"),client.call("GET","/me/erke"))
        assert client.tokens["refresh_token"]!=old_refresh
        steps.append("concurrent_refresh_rotation")
        await web("revoke")
        try: await client.call("GET","/binding")
        except IntegrationProblem as error: assert error.code in ("invalid_token","reconnect_required","connect_first")
        else: raise AssertionError("Revoked credential accepted")
        assert client.tokens is None
        steps.append("web_revoke_invalidates_python_credentials")
        await client.begin(str(uuid.uuid4()),"跨端取消测试",False,personal=True)
        await client.disconnect()
        assert client.pending is None and client.tokens is None
        steps.append("pending_device_cancellation")
        print(json.dumps({"passed":True,"steps":steps,"production_requests":0,"qq_sends":0},ensure_ascii=True))
    finally:
        await client.close()


if __name__=="__main__": asyncio.run(main())

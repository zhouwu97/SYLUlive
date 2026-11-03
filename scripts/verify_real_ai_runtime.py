"""Opt-in real-provider acceptance against the disposable Go loopback fixture only."""
import asyncio
import copy
import hashlib
import json
import os
from pathlib import Path
import time
from types import SimpleNamespace
from urllib.parse import urlsplit
import uuid

import httpx

class MemoryStore:
    persistent=False
    def load(self): return None
    def save(self,value): pass
    def delete(self): pass

async def main():
    import astrbot
    astrbot.logger.setLevel(100)
    from astrbot.api.star import Context
    from astrbot.core.provider.sources.openai_responses_source import ProviderOpenAIResponses
    from astrbot_plugin_sylulive.bot_runtime import BotRuntimeManager
    from astrbot_plugin_sylulive.client import BusinessClient
    from astrbot_plugin_sylulive.public_agent import PublicAgent,PublicMemory
    from astrbot_plugin_sylulive.managed_bot_access import ManagedBotAccess
    assert os.environ.get("SYLULIVE_REAL_AI_TEST")=="1"
    origin=os.environ["SYLULIVE_FULL_CHAIN_ORIGIN"]
    parts=urlsplit(origin)
    assert parts.scheme=="http" and parts.hostname=="127.0.0.1"
    output=Path(os.environ["SYLULIVE_REAL_AI_EVIDENCE_DIR"]);output.mkdir(parents=True,exist_ok=True)
    live=json.loads(Path(os.environ["SYLULIVE_REAL_AI_CONFIG_PATH"]).read_text(encoding="utf-8-sig"))
    provider_id=os.environ.get("SYLULIVE_REAL_AI_PROVIDER_ID","gpt-6-luna")
    model=next(item for item in live["provider"] if item.get("id")==provider_id)
    source=next(item for item in live["provider_sources"] if item.get("id")==model["provider_source_id"])
    merged={**copy.deepcopy(source),**copy.deepcopy(model)}
    assert merged["type"]=="openai_responses"
    assert urlsplit(merged["api_base"]).scheme=="https"
    merged["timeout"]=40
    merged.setdefault("custom_extra_body",{})["max_output_tokens"]=4096
    real_keys=[v for v in merged.get("key",[]) if isinstance(v,str) and len(v)>12]
    clients=[BusinessClient(origin,MemoryStore()),BusinessClient(origin,MemoryStore())]
    tokens=[os.environ["SYLULIVE_REAL_AI_FIRST_JWT"],os.environ["SYLULIVE_REAL_AI_SECOND_JWT"]]
    providers=[];model_calls=[];http_calls=[];workers=[];manager=None
    result={"passed":False,"real_model":model["model"],"provider_id":provider_id,"model_calls":model_calls,"requests":http_calls,"accounts":[],"production_writes":0,"qq_sends":0}
    def save():
        (output/"real-ai-runtime.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    async with httpx.AsyncClient(base_url=origin,trust_env=False) as app:
        async def own(index,method,path,body=None):
            response=await app.request(method,path,json=body,headers={"Authorization":"Bearer "+tokens[index]})
            assert response.status_code==200,(path,response.status_code)
            return response.json()
        try:
            async def connect(index):
                client=clients[index]
                device=await client.begin(str(uuid.uuid4()),"真实模型隔离验收",True,bot_reply=index==0,bot_post=index==1,community_read=True)
                consent=await own(index,"POST","/api/connected-apps/device-requests/lookup",{"user_code":device["user_code"]})
                await own(index,"POST","/api/connected-apps/device-requests/"+consent["consent_id"]+"/decision",
                    {"allow":True,"scopes":consent["requested_scopes"],"confirmation_nonce":consent["confirmation_nonce"]})
                await asyncio.sleep(max(0,client.pending["next"]-time.monotonic())+.1)
                await client.poll()
                await own(index,"POST","/api/connected-apps/bot",{"name":"真实模型隔离机器人"+str(index+1),"enabled":True,
                    "policy":{"public_read_enabled":True,"reply_enabled":index==0,"sticker_enabled":False,"post_enabled":index==1,"image_enabled":False,
                    "allowed_post_types":["course_study"],"blocked_terms":[],"block_links":True,"daily_reply_limit":3,"min_reply_interval_minutes":30}})
            await asyncio.gather(connect(0),connect(1))
            class ObservedProvider(ProviderOpenAIResponses):
                async def text_chat(self,**kwargs):
                    context_json=json.dumps([m.model_dump() if hasattr(m,"model_dump") else m for m in kwargs.get("contexts",[])],ensure_ascii=False,default=str)
                    assert "TEST_PRIVATE_CONTACT_CANARY_MUST_NOT_REACH_MODEL" not in context_json
                    assert all(key not in context_json for key in real_keys+tokens)
                    tool_names=[t.name for t in kwargs["func_tool"].tools]
                    self.account_index=0 if "comment_public_post" in tool_names else 1
                    assert not {"private_memory","sylulive_grades","send_message","send_meme","astrbot_execute_shell"}.intersection(tool_names)
                    entry={"account_index":self.account_index,"input_roles":[getattr(m,"role",None) if not isinstance(m,dict) else m.get("role") for m in kwargs.get("contexts",[])],"available_tools":tool_names,"started_at":time.time()}
                    model_calls.append(entry);save()
                    try:
                        kwargs["request_max_retries"]=1
                        response=await super().text_chat(**kwargs)
                        raw=response.raw_completion
                        entry.update(tool_names=response.tools_call_name,tool_args=response.tools_call_args,completion=response.completion_text,
                            response_id=getattr(raw,"id",None),response_model=getattr(raw,"model",None))
                        return response
                    except Exception as error:
                        entry.update(error_type=type(error).__name__,http_status=getattr(error,"status_code",None))
                        raise
                    finally: save()
            next_account=[0]
            async def provider_lookup(ident):
                assert ident==provider_id
                provider=ObservedProvider(copy.deepcopy(merged),{"enable":True})
                provider.account_index=next_account[0];next_account[0]+=1
                assert provider.account_index<2
                providers.append(provider)
                original=provider.client.responses.create
                async def observed_request(*args,**kwargs):
                    count=sum(row["account_index"]==provider.account_index for row in http_calls)
                    if count>=8: raise RuntimeError("real_model_request_budget_exhausted")
                    assert kwargs.get("store") is False
                    assert not kwargs.get("previous_response_id") and not kwargs.get("conversation")
                    record={"account_index":provider.account_index,"model":kwargs.get("model"),"store":False,"started_at":time.time()}
                    http_calls.append(record);save()
                    try:
                        response=await original(*args,**kwargs)
                        record.update(response_id=response.id,response_model=response.model,usage=response.usage.model_dump() if response.usage else None)
                        return response
                    except Exception as error:
                        record.update(error_type=type(error).__name__,http_status=getattr(error,"status_code",None));raise
                    finally: save()
                provider.client.responses.create=observed_request
                return provider
            context=Context.__new__(Context)
            context.provider_manager=SimpleNamespace(get_provider_by_id=provider_lookup)
            config={"community_agent_enabled":True,"community_multi_user_runtime_enabled":True,"allow_multi_user":True,
                "community_auto_browse":True,"community_auto_comment":True,"community_auto_post":True,
                "community_agent_provider_id":provider_id,"community_allowed_sections":["course_study"],"community_browse_topic":"学习"}
            # Each disposable server has new bot identities; never reuse a prior run's cooldown.
            directory=output/("runtime-data-"+uuid.uuid4().hex);directory.mkdir()
            owner=PublicAgent(config,ManagedBotAccess(clients[0]),PublicMemory(directory/"owner.sqlite3"))
            slots=SimpleNamespace(clients=lambda:[(hashlib.sha256(b"real-ai-second").hexdigest(),clients[1],"synthetic")],restore=lambda:None)
            manager=BotRuntimeManager(config,context,directory,slots,clients[0],hashlib.sha256(b"real-ai-first").hexdigest(),owner)
            manager.task=asyncio.create_task(manager.run())
            deadline=time.monotonic()+120
            while True:
                workers=list(manager.workers.values())
                if len(workers)==2 and all(w.agent and w.agent.last_result for w in workers):break
                if time.monotonic()>deadline:raise TimeoutError("real_ai_runtime_round_deadline")
                await asyncio.sleep(.25)
            for index,client in enumerate(clients):
                worker=manager.workers[client]
                view=await own(index,"GET","/api/connected-apps/bot/runtime")
                row={"index":index,"agent_result":worker.agent.last_result,"server_runtime":view["runtime"],"bot_user_id":worker.bot["bot_user_id"],
                    "public_session":worker.agent.isolation_id,"memory_sources":worker.agent.memory.db.execute("SELECT COUNT(*) FROM posts").fetchone()[0]}
                result["accounts"].append(row)
                assert worker.agent.last_result["state"]=="completed",row
                assert worker.agent.last_result["read_count"]>=1,row
                action=view["runtime"].get("last_action")
                assert action and action["kind"]==("reply" if index==0 else "post"),row
            assert result["accounts"][0]["public_session"]!=result["accounts"][1]["public_session"]
            before_controls = len(http_calls)
            await own(1,"POST","/api/connected-apps/bot",{"enabled":False})
            await manager.sync(manager.workers[clients[1]],schedule=False)
            paused=await own(1,"GET","/api/connected-apps/bot/runtime")
            assert paused["runtime"]["state"]=="paused"
            assert manager.workers[clients[0]].bot["enabled"] is True
            await clients[0].disconnect()
            await manager.discover(start_workers=False)
            assert clients[0] not in manager.workers
            bindings=await own(0,"GET","/api/connected-apps")
            assert all(row["state"]!="active" for row in bindings["bindings"])
            assert len(http_calls)==before_controls
            result["controls"]={"pause_second":"paused","first_unaffected_before_revoke":True,"first_revoked":True,"extra_model_calls":0}
            result["passed"]=True
        except Exception as error:
            result.update(error_type=type(error).__name__,http_status=getattr(error,"status_code",None))
        finally:
            if manager:await manager.close()
            for provider in providers:await provider.terminate()
            for client in clients:await client.close()
            save()
    print(json.dumps({"passed":result["passed"],"real_model":result["real_model"],"real_http_model_requests":len(http_calls),"account_count":len(result["accounts"]),"error_type":result.get("error_type"),"production_writes":0,"qq_sends":0},ensure_ascii=False))
    return int(not result["passed"])
if __name__=="__main__":raise SystemExit(asyncio.run(main()))

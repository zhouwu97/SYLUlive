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
    from astrbot.core.provider.sources.xiaomi_source import ProviderXiaomi
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
    provider_type=merged["type"]
    assert provider_type in {"openai_responses","xiaomi_chat_completion"}
    provider_class=ProviderOpenAIResponses if provider_type=="openai_responses" else ProviderXiaomi
    assert urlsplit(merged["api_base"]).scheme=="https"
    merged["timeout"]=40
    output_limit="max_output_tokens" if provider_type=="openai_responses" else "max_tokens"
    merged.setdefault("custom_extra_body",{})[output_limit]=4096
    real_keys=[v for v in merged.get("key",[]) if isinstance(v,str) and len(v)>12]
    clients=[BusinessClient(origin,MemoryStore()),BusinessClient(origin,MemoryStore())]
    tokens=[os.environ["SYLULIVE_REAL_AI_FIRST_JWT"],os.environ["SYLULIVE_REAL_AI_SECOND_JWT"]]
    providers=[];model_calls=[];http_calls=[];workers=[];manager=None
    phase={"followup":False,"target":None}
    result={"passed":False,"execution_mode":"commissioned_capability_acceptance","real_model":model["model"],"provider_id":provider_id,"provider_type":provider_type,"model_calls":model_calls,"requests":http_calls,"accounts":[],"production_writes":0,"qq_sends":0,
        "acceptance_contract":"This isolated run tests explicit user-commissioned capabilities. An uncommissioned autonomous choice to remain silent is valid product behavior and is not a publication failure."}
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
                installation=str(uuid.uuid4())
                async def approve(device, *, replacement=False):
                    consent=await own(index,"POST","/api/connected-apps/device-requests/lookup",{"user_code":device["user_code"]})
                    payload={"allow":True,"scopes":consent["requested_scopes"],"confirmation_nonce":consent["confirmation_nonce"]}
                    if replacement:
                        binding=consent["existing_binding"]
                        payload.update(replace_binding_id=binding["binding_id"],expected_epoch=binding["epoch"])
                    await own(index,"POST","/api/connected-apps/device-requests/"+consent["consent_id"]+"/decision",payload)
                    await asyncio.sleep(max(0,client.pending["next"]-time.monotonic())+.1)
                    await client.poll()
                baseline=await client.begin(installation,"真实模型隔离验收",False,community_read=True)
                await approve(baseline)
                before_generation=client.generation
                device=await client.begin(installation,"真实模型隔离验收",True,bot_reply=True,bot_post=index==1,community_read=True)
                assert device.get("upgrade") is True
                assert not any(scope in client.tokens["scope"].split() for scope in ("community:bot_post","community:bot_reply"))
                await approve(device,replacement=True)
                assert client.generation>before_generation
                await own(index,"POST","/api/connected-apps/bot",{"name":"真实模型隔离机器人"+str(index+1),"enabled":True,
                    "policy":{"public_read_enabled":True,"reply_enabled":index==0,"sticker_enabled":False,"post_enabled":index==1,"image_enabled":False,
                    "allowed_post_types":["course_study"],"blocked_terms":[],"block_links":True,"daily_reply_limit":3,"min_reply_interval_minutes":30}})
            await asyncio.gather(connect(0),connect(1))
            result["authorization_upgrade"]={"accounts":2,"owner_confirmed_replacement":True,"old_grants_not_expanded_before_confirmation":True}
            class ObservedProvider(provider_class):
                async def text_chat(self,**kwargs):
                    context_json=json.dumps([m.model_dump() if hasattr(m,"model_dump") else m for m in kwargs.get("contexts",[])],ensure_ascii=False,default=str)
                    assert "TEST_PRIVATE_CONTACT_CANARY_MUST_NOT_REACH_MODEL" not in context_json
                    assert all(key not in context_json for key in real_keys+tokens)
                    tool_names=[t.name for t in kwargs["func_tool"].tools]
                    self.account_index=1 if phase["followup"] else (0 if "comment_public_post" in tool_names else 1)
                    assert not {"private_memory","sylulive_grades","send_message","send_meme","astrbot_execute_shell"}.intersection(tool_names)
                    entry={"account_index":self.account_index,"input_roles":[getattr(m,"role",None) if not isinstance(m,dict) else m.get("role") for m in kwargs.get("contexts",[])],"available_tools":tool_names,"phase":"thread_followup" if phase["followup"] else "initial","started_at":time.time()}
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
                provider.account_index=1 if phase["followup"] else next_account[0]
                if not phase["followup"]: next_account[0]+=1
                assert provider.account_index<2
                providers.append(provider)
                endpoint=provider.client.responses if provider_type=="openai_responses" else provider.client.chat.completions
                original=endpoint.create
                async def observed_request(*args,**kwargs):
                    count=sum(row["account_index"]==provider.account_index for row in http_calls)
                    if count>=12: raise RuntimeError("real_model_request_budget_exhausted")
                    if provider_type=="openai_responses":assert kwargs.get("store") is False
                    assert not kwargs.get("previous_response_id") and not kwargs.get("conversation")
                    request_text=json.dumps(kwargs,ensure_ascii=False,default=str)
                    assert "TEST_PRIVATE_CONTACT_CANARY_MUST_NOT_REACH_MODEL" not in request_text
                    assert all(key not in request_text for key in real_keys+tokens)
                    record={"account_index":provider.account_index,"model":kwargs.get("model"),"protocol":provider_type,"store":kwargs.get("store"),"started_at":time.time()}
                    http_calls.append(record);save()
                    try:
                        response=await original(*args,**kwargs)
                        record.update(response_id=response.id,response_model=response.model,usage=response.usage.model_dump() if response.usage else None)
                        return response
                    except Exception as error:
                        record.update(error_type=type(error).__name__,http_status=getattr(error,"status_code",None));raise
                    finally: save()
                endpoint.create=observed_request
                return provider
            context=Context.__new__(Context)
            context.provider_manager=SimpleNamespace(get_provider_by_id=provider_lookup)
            native_loop=context.tool_loop_agent
            async def model_loop(**request):
                if phase["followup"]:
                    target=phase["target"]
                    request["prompt"] += f"\n本轮任务：请阅读你自己的帖子 #{target['post_id']} 及评论，针对人类的楼中楼评论 #{target['target_reply_id']} 的具体问题作一次精确回复。调用comment_public_post时务必填这个reply_to_reply_id；不要另发顶层评论或新帖子。内容由你根据实际读到的公开问题生成。"
                else:
                    names={tool.name for tool in request["tools"].tools}
                    if "publish_public_post" in names:
                        request["prompt"] += "\n使用者明确委托的一次隔离能力验收：请先实际阅读公开来源，再根据来源形成一篇有具体步骤的学习建议，使用publish_public_post发布一次纯文字讨论。不要用图片，不要尝试第二次发布。正文由你根据实际来源生成。如果真实权限不足、来源失效或没有足够来源，请说明并停止，不得伪造成功。"
                    elif "comment_public_post" in names:
                        request["prompt"] += "\n使用者明确委托的一次隔离能力验收：请先实际阅读帖子和评论，选择其中一条正常人类评论，针对其实际问题生成具体建议，并使用comment_public_post精确回复一次（填写reply_to_reply_id）。不要另发顶层评论、不要重复尝试。如真实权限不足、来源失效或没有合适的人类目标，请说明并停止，不得伪造成功。"
                return await native_loop(**request)
            context.tool_loop_agent=model_loop
            config={"community_agent_enabled":True,"community_multi_user_runtime_enabled":True,"allow_multi_user":True,
                "community_auto_browse":True,"community_auto_comment":True,"community_auto_post":True,
                "community_agent_provider_id":provider_id,"community_allowed_sections":["course_study"],"community_browse_topic":"学习"}
            # Each disposable server has new bot identities; never reuse a prior run's cooldown.
            directory=output/("runtime-data-"+uuid.uuid4().hex);directory.mkdir()
            owner=PublicAgent(config,ManagedBotAccess(clients[0]),PublicMemory(directory/"owner.sqlite3"))
            slots=SimpleNamespace(clients=lambda:[(hashlib.sha256(b"real-ai-second").hexdigest(),clients[1],"synthetic")],restore=lambda:None)
            wall,mono=[time.time()],[time.monotonic()]
            manager=BotRuntimeManager(config,context,directory,slots,clients[0],hashlib.sha256(b"real-ai-first").hexdigest(),owner,clock=lambda:wall[0],monotonic=lambda:mono[0])
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
            # Only isolated clocks advance. Production ledgers, quotas and timers are never touched.
            manager.task.cancel();await asyncio.gather(manager.task,return_exceptions=True);manager.task=None
            for worker in manager.workers.values():
                if worker.task: worker.task.cancel()
            await asyncio.gather(*(w.task for w in manager.workers.values() if w.task),return_exceptions=True)
            phase["followup"]=True
            phase["target"]=await own(1,"POST","/__fixture/thread-human")
            await own(1,"POST","/api/connected-apps/bot",{"enabled":True,"policy":{"public_read_enabled":True,"reply_enabled":True,"sticker_enabled":False,"post_enabled":False,"image_enabled":False,"allowed_post_types":["course_study"],"blocked_terms":[],"block_links":True,"daily_reply_limit":3,"min_reply_interval_minutes":30}})
            config["community_auto_post"]=False
            wall[0]+=1861;mono[0]+=1861
            worker=manager.workers[clients[1]]
            await manager.sync(worker)
            follow_task=worker.round_task
            assert follow_task is not None
            follow_result=await asyncio.wait_for(follow_task,120)
            assert follow_result["state"]=="completed",follow_result
            follow_view=await own(1,"GET","/api/connected-apps/bot/runtime")
            action=follow_view["runtime"]["last_action"]
            assert action["kind"]=="reply"
            data=await clients[1].call("GET",f"/community/posts/{phase['target']['post_id']}/replies",params={"limit":20})
            published=next(row for row in data["data"]["items"] if row["reply_id"]==action["reply_id"])
            assert published["reply_to_reply_id"]==phase["target"]["target_reply_id"]
            assert published["parent_reply_id"]==phase["target"]["root_reply_id"]
            assert published["author"]["ai_bot"]["owner_id"]==129002
            assert worker.agent.memory.db.execute("SELECT reply_id,state FROM reply_outbox").fetchall()==[(phase["target"]["target_reply_id"],"published")]
            result["thread_followup"]={"passed":True,"agent_result":follow_result,"post_id":published["post_id"],"reply_id":published["reply_id"],"target_reply_id":published["reply_to_reply_id"],"root_reply_id":published["parent_reply_id"],"content":published["content"],"ai_bot":published["author"]["ai_bot"],"isolated_clock_advanced_seconds":1861}
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
    print(json.dumps({"passed":result["passed"],"execution_mode":result["execution_mode"],"real_model":result["real_model"],"real_http_model_requests":len(http_calls),"account_count":len(result["accounts"]),"error_type":result.get("error_type"),"production_writes":0,"qq_sends":0},ensure_ascii=False))
    return int(not result["passed"])
if __name__=="__main__":raise SystemExit(asyncio.run(main()))

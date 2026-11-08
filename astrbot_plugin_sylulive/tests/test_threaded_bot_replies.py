import json
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from test_public_agent import config, post
from astrbot_plugin_sylulive.client import IntegrationProblem
from astrbot_plugin_sylulive.community_publisher import CommunityPublisher
from astrbot_plugin_sylulive.public_agent import PublicAgent, PublicMemory


def reply(ident=11, **changes):
    return {"reply_id": ident, "post_id": 1, "status": "normal", "content": "能具体回复我吗？", "source_version": "b"*64, "author": {"nickname": "同学"}, **changes}


def fixture(tmp_path, target=None):
    target=target or reply()
    async def read(path, **kwargs):
        if path.endswith("/context"): return {"data": {"reply": target}}
        if path.endswith("/replies"): return {"data": {"items": [target], "next_after_id": 0}}
        if path.endswith("/stickers"): return {"data": {"items": []}}
        if path.endswith("/posts"): return {"data": {"items": [post(source_version="a"*64)]}}
        return {"data": post(source_version="a"*64)}
    agent=PublicAgent(config(community_auto_comment=True),read,PublicMemory(tmp_path/"thread.db"))
    client=SimpleNamespace(tokens={"scope":"community:bot_reply"},call=AsyncMock(return_value={"state":"published","reply_id":20}))
    agent.publisher=CommunityPublisher(agent,client)
    return agent,client,target


@pytest.mark.asyncio
async def test_target_reply_does_not_erase_legacy_top_level_ledger_and_survives_restart(tmp_path):
    agent,client,target=fixture(tmp_path)
    publisher=agent.publisher
    await publisher.publish(1,"原来的顶层参与","",agent.stamp(),set())
    result=await publisher.publish(1,"具体回答","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=target)
    assert result["state"]=="published"
    payload=client.call.call_args.kwargs["payload"]
    assert payload["reply_to_reply_id"]==11 and payload["reply_source_version"]=="b"*64
    assert publisher.db.execute("SELECT post_id,state FROM outbox").fetchall()==[(1,"published")]
    publisher=CommunityPublisher(agent,client)
    with pytest.raises(IntegrationProblem,match="bot_reply_already_attempted"):
        await publisher.publish(1,"重复回答","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=target)
    assert client.call.await_count==2
    agent.memory.clear()
    assert publisher.db.execute("SELECT reply_id,state FROM reply_outbox").fetchall()==[(11,"published")]
    await agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("kind",["unread","changed","deleted","cross_post","ai","missing_context"])
async def test_bad_targets_never_reserve_ledger_or_call_write(tmp_path,kind):
    target=reply()
    expected=reply()
    if kind=="changed": target["source_version"]="c"*64
    if kind=="deleted": target["status"]="deleted"
    if kind=="cross_post": target["post_id"]=2
    if kind=="ai": target["author"]={"nickname":"无AI昵称", "ai_bot":{}}
    agent,client,_=fixture(tmp_path,target)
    if kind=="missing_context": agent.public_call=AsyncMock(side_effect=IntegrationProblem("source_unavailable"))
    with pytest.raises(IntegrationProblem):
        await agent.publisher.publish(1,"不能发送","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=None if kind=="unread" else expected)
    assert not client.call.called
    assert agent.memory.db.execute("SELECT COUNT(*) FROM reply_outbox").fetchone()[0]==0
    assert agent.memory.db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]==0
    await agent.close()


@pytest.mark.asyncio
async def test_native_tool_targets_only_the_comment_actually_read_this_round(tmp_path):
    agent,client,target=fixture(tmp_path)
    async def model(**request):
        tools=request["tools"];event=request["event"]
        await tools.get_tool("read_public_post").handler(event,1)
        await tools.get_tool("read_public_replies").handler(event,1)
        tool=tools.get_tool("comment_public_post")
        assert "reply_to_reply_id" in tool.parameters["properties"]
        assert "read_reply_first" in await tool.handler(event,1,"回复",reply_to_reply_id=99)
        result=json.loads(await tool.handler(event,1,"具体回复",reply_to_reply_id=11))
        assert result["state"]=="published"
        assert "quota" in await tool.handler(event,1,"再次",reply_to_reply_id=11)
    result=await agent.browse(SimpleNamespace(tool_loop_agent=model))
    assert result["state"]=="completed"
    assert client.call.call_args.kwargs["payload"]["reply_to_reply_id"]==11
    await agent.close()


@pytest.mark.asyncio
async def test_owned_post_is_followed_when_interest_search_does_not_return_it(tmp_path):
    agent,client,target=fixture(tmp_path)
    agent.memory.db.execute("INSERT INTO post_outbox VALUES(?,?,?,?,?)",("existing","digest",1000,"published",1));agent.memory.db.commit()
    original=agent.public_call
    async def read(path,**kwargs):
        if path.endswith("/posts"): return {"data":{"items":[]}}
        return await original(path,**kwargs)
    agent.public_call=read
    async def model(**request):
        assert request["tools"].get_tool("read_public_post").parameters["properties"]["post_id"]["enum"]==[1]
        await request["tools"].get_tool("read_public_post").handler(request["event"],1)
    result=await agent.browse(SimpleNamespace(tool_loop_agent=model))
    assert result["state"]=="completed" and result["read_count"]==1
    await agent.close()


@pytest.mark.asyncio
async def test_uncertain_target_publish_is_not_retried_after_public_memory_clear(tmp_path):
    agent,client,target=fixture(tmp_path)
    client.call.side_effect=IntegrationProblem("network_unavailable")
    with pytest.raises(IntegrationProblem,match="bot_publish_unconfirmed"):
        await agent.publisher.publish(1,"回复","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=target)
    agent.memory.clear()
    with pytest.raises(IntegrationProblem,match="bot_reply_already_attempted"):
        await agent.publisher.publish(1,"不重试","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=target)
    assert client.call.await_count==1
    assert agent.memory.db.execute("SELECT reply_id,state FROM reply_outbox").fetchall()==[(11,"uncertain")]
    await agent.close()


@pytest.mark.asyncio
async def test_human_nickname_cannot_claim_system_ai_identity(tmp_path):
    target=reply(author={"nickname":"[AI] 自称机器人"})
    agent,client,target=fixture(tmp_path,target)
    result=await agent.publisher.publish(1,"仍是普通用户","",agent.stamp(),set(),reply_to_reply_id=11,expected_reply=target)
    assert result["state"]=="published"
    await agent.close()


def test_followup_pool_rotates_without_starving_other_peoples_threads(tmp_path):
    agent,_,_=fixture(tmp_path)
    db=agent.memory.db
    for ident in (1,2,3): db.execute("INSERT INTO post_outbox VALUES(?,?,?,?,?)",(str(ident),"digest",ident,"published",ident))
    db.execute("INSERT INTO outbox VALUES(?,?,?,?)",(9,"legacy","digest","published"));db.commit()
    publisher=agent.publisher
    assert publisher.conversation_post_ids()==[3,2]
    assert publisher.conversation_post_ids()==[1,9]
    publisher=CommunityPublisher(agent,publisher.client)
    assert publisher.conversation_post_ids()==[3,2]
    agent.memory.close()


@pytest.mark.asyncio
async def test_deleted_first_followups_do_not_block_next_rounds_public_threads(tmp_path):
    agent,_,_=fixture(tmp_path)
    for ident in (1,2): agent.memory.db.execute("INSERT INTO post_outbox VALUES(?,?,?,?,?)",(str(ident),"digest",ident,"published",ident))
    agent.memory.db.execute("INSERT INTO outbox VALUES(?,?,?,?)",(9,"legacy","digest","published"));agent.memory.db.commit()
    seen=[]
    async def read(path,**kwargs):
        if path.endswith("/posts") or path.endswith("/stickers"): return {"data":{"items":[]}}
        ident=int(path.rsplit("/",1)[-1]);seen.append(ident)
        if ident!=9: raise IntegrationProblem("post_not_found")
        return {"data":post(9,source_version="a"*64)}
    agent.public_call=read
    async def model(**request):
        await request["tools"].get_tool("read_public_post").handler(request["event"],9)
    first=await agent._browse(SimpleNamespace(tool_loop_agent=model),agent.stamp())
    assert first["state"]=="empty"
    second=await agent._browse(SimpleNamespace(tool_loop_agent=model),agent.stamp())
    assert second["state"]=="completed" and 9 in seen
    await agent.close()


@pytest.mark.asyncio
@pytest.mark.parametrize("kind",["own_bot","other_bot","human_ai_nickname"])
async def test_top_level_comments_never_target_an_ai_post(tmp_path,kind):
    agent,client,target=fixture(tmp_path)
    original=agent.public_call
    async def read(path,**kwargs):
        result=await original(path,**kwargs)
        if path.endswith("/posts/1"):
            result["data"]["author"]={"nickname":"[AI] 名字不代表身份"}
            if kind!="human_ai_nickname": result["data"]["author"]["ai_bot"]={"owner_id":1 if kind=="own_bot" else 2,"owner_nickname":"公开创建者"}
        return result
    agent.public_call=read
    if kind=="human_ai_nickname":
        assert (await agent.publisher.publish(1,"公开讨论","",agent.stamp(),set()))["state"]=="published"
    else:
        with pytest.raises(IntegrationProblem,match="bot_reply_target_not_human"):
            await agent.publisher.publish(1,"不能自评","",agent.stamp(),set())
        assert not client.call.called
        assert agent.memory.db.execute("SELECT COUNT(*) FROM outbox").fetchone()[0]==0
        async def model(**request):
            tools,event=request["tools"],request["event"]
            await tools.get_tool("read_public_post").handler(event,1)
            await tools.get_tool("read_public_replies").handler(event,1)
            tool=tools.get_tool("comment_public_post")
            assert "bot_reply_target_not_human" in await tool.handler(event,1,"不能顶层自回")
            assert json.loads(await tool.handler(event,1,"回答人类",reply_to_reply_id=11))["state"]=="published"
        assert (await agent.browse(SimpleNamespace(tool_loop_agent=model)))["state"]=="completed"
    await agent.close()



def paging_fixture(tmp_path):
    agent,client,_=fixture(tmp_path)
    state={"rows":[reply(i) for i in range(1,82)],"version":"a"*64,"change_during_page":False}
    async def public(path,**kwargs):
        if path.endswith("/posts"):return {"data":{"items":[post(source_version=state["version"])]}}
        if path.endswith("/stickers"):return {"data":{"items":[]}}
        if path.endswith("/replies"):
            after=kwargs["params"]["after_id"];remaining=[r for r in state["rows"] if r["reply_id"]>after];rows=remaining[:20]
            if state["change_during_page"]:state["version"]="c"*64;state["change_during_page"]=False
            return {"data":{"items":rows,"next_after_id":rows[-1]["reply_id"] if len(remaining)>20 else 0}}
        if path.endswith("/context"):
            ident=int(path.split("/")[-2]);target=next(r for r in state["rows"] if r["reply_id"]==ident)
            result={"reply":target}
            if target.get("parent_reply_id"):result["root_reply"]=state["rows"][0]
            if target.get("reply_to_reply_id") and target["reply_to_reply_id"]!=target.get("parent_reply_id"):result["target_reply"]=state["rows"][1]
            return {"data":result}
        return {"data":post(source_version=state["version"])}
    agent.public_call=public
    return agent,client,state


@pytest.mark.asyncio
async def test_late_81st_comment_is_reached_across_rounds_restart_empty_page_and_new_arrival(tmp_path):
    agent,_,state=paging_fixture(tmp_path)
    observed=[]
    async def initial(**request):
        tools,event=request["tools"],request["event"]
        await tools.get_tool("read_public_post").handler(event,1)
        for _ in range(4):
            page=json.loads(await tools.get_tool("read_public_replies").handler(event,1));observed.extend(r["reply_id"] for r in page["items"])
        assert "budget" in await tools.get_tool("read_public_replies").handler(event,1)
    await agent._browse(SimpleNamespace(tool_loop_agent=initial),agent.stamp())
    assert observed==list(range(1,81))
    await agent.close()
    agent,_,state=paging_fixture(tmp_path)
    pages=[]
    async def later(**request):
        tools,event=request["tools"],request["event"]
        await tools.get_tool("read_public_post").handler(event,1)
        pages.append(json.loads(await tools.get_tool("read_public_replies").handler(event,1)))
    await agent._browse(SimpleNamespace(tool_loop_agent=later),agent.stamp())
    assert [r["reply_id"] for r in pages[-1]["items"]]==[81]
    assert pages[-1]["page_after_id"]==80 and pages[-1]["partial"] is True and pages[-1]["has_more"] is False
    await agent._browse(SimpleNamespace(tool_loop_agent=later),agent.stamp())
    assert pages[-1]["items"]==[] and pages[-1]["page_after_id"]==81
    state["rows"].append(reply(82))
    await agent._browse(SimpleNamespace(tool_loop_agent=later),agent.stamp())
    assert [r["reply_id"] for r in pages[-1]["items"]]==[82]
    await agent.close()


@pytest.mark.asyncio
async def test_model_cursor_cannot_skip_persistent_history_and_source_change_does_not_commit(tmp_path):
    agent,_,state=paging_fixture(tmp_path)
    async def model(**request):
        tools,event=request["tools"],request["event"]
        await tools.get_tool("read_public_post").handler(event,1)
        await tools.get_tool("read_public_replies").handler(event,1,after_id=999999)
        assert agent.memory.reply_cursor(1,"a"*64)==0
        first=json.loads(await tools.get_tool("read_public_replies").handler(event,1))
        assert first["page_after_id"]==0
        assert agent.memory.reply_cursor(1,"a"*64)==20
        state["change_during_page"]=True
        assert "source_changed" in await tools.get_tool("read_public_replies").handler(event,1)
        assert agent.memory.reply_cursor(1,"a"*64)==20 and agent.memory.reply_cursor(1,"c"*64)==0
    await agent._browse(SimpleNamespace(tool_loop_agent=model),agent.stamp())
    await agent.close()


@pytest.mark.asyncio
async def test_incremental_nested_target_requires_actual_thread_context_then_can_publish(tmp_path):
    agent,client,state=paging_fixture(tmp_path)
    state["rows"][-1].update(parent_reply_id=1,reply_to_reply_id=2)
    async def model(**request):
        tools,event=request["tools"],request["event"]
        await tools.get_tool("read_public_post").handler(event,1)
        page=json.loads(await tools.get_tool("read_public_replies").handler(event,1,after_id=80))
        assert page["items"][0]["thread_context_complete"] is False
        assert "read_reply_context_first" in await tools.get_tool("comment_public_post").handler(event,1,"先补上下文",reply_to_reply_id=81)
        assert not client.call.called
        context=json.loads(await tools.get_tool("read_public_replies").handler(event,1,reply_id=81))
        assert context["reply_context"]["root_reply"]["reply_id"]==1
        assert context["reply_context"]["target_reply"]["reply_id"]==2
        result=json.loads(await tools.get_tool("comment_public_post").handler(event,1,"结合上下文回答",reply_to_reply_id=81))
        assert result["state"]=="published"
    assert (await agent.browse(SimpleNamespace(tool_loop_agent=model)))["state"]=="completed"
    assert client.call.call_args.kwargs["payload"]["reply_to_reply_id"]==81
    await agent.close()

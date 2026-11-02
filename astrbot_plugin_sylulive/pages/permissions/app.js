"use strict";
(() => {
  const $ = id => document.getElementById(id);
  const bridge = window.AstrBotPluginPage || window.AstrBotPluginView;
  let epoch = 0, statusEpoch = 0;
  const labels = {denied:"规则拒绝",disabled:"功能关闭",scope_required:"缺少本人授权",public_allowed:"公开入口允许",server_check_required:"本机条件通过"};
  const states = {completed:"已完成",empty:"暂无可读帖子",idle:"等待运行",loading:"正在浏览",error:"最近一次失败",paused:"已暂停",cancelled:"已取消",disabled:"未启用",not_started:"尚未启动",scope_required:"尚未配置阅读范围",cooldown:"间隔等待中",busy:"上一轮仍在运行"};
  function node(tag, text, cls) { const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(cls)el.className=cls;return el; }
  function timed(promise) {let timer;return Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error("timeout")),10000);})]).finally(()=>clearTimeout(timer));}
  function clearPreview(message="信息已变化，请重新预览。") {epoch++;$("result-list").replaceChildren();$("preview-message").textContent=message;$("preview-message").hidden=false;$("result-context").textContent="";$("result-list").setAttribute("aria-busy","false");$("preview-submit").disabled=false;}
  function renderOverview(data) {
    const b=data.build,r=data.runtime;
    const buildLabel={verified:"包内文件摘要一致",changed:"安装文件与构建记录不一致",source_tree:"本地源码，未附构建清单"}[b.state]||"构建来源待核对";
    const next=r.auto_browse?`下次尝试约 ${Math.ceil((r.next_in_seconds||0)/60)} 分钟后`:"定时浏览关闭";
    const last=r.last_result?`最近结果：${new Date(r.last_result.at*1000).toLocaleString('zh-CN',{hour12:false})} · ${states[r.last_result.state]||'待核对'}`:"启动后暂无浏览结果";
    const rows=[
      ["安装版本",b.version,`${buildLabel}${b.fingerprint?" · "+b.fingerprint:""}${b.source_dirty?"；含未提交源码":""}`],
      ["人格与记忆",r.agent_enabled?r.persona:"沿用 AstrBot 人格",r.memory_mode==="lexical"?"关键词检索；未启用语义向量召回":r.memory_mode],
      ["公开浏览",r.auto_browse?(states[r.state]||"状态待核对"):"未开启",`${next}。${last}`],
      ["自主发布",r.comment_configured?(r.comment_authorized?"评论有本机授权":"评论缺少专用授权"):"自动评论关闭","仍须服务端开放及机器人启用；此版本不提供自主发帖配图"]
    ];
    $("summary").replaceChildren(...rows.map(([title,value,detail])=>{const item=node("dl",undefined,"summary-item");const dd=node("dd",value);dd.append(node("small",detail));item.append(node("dt",title),dd);return item;}));
    $("summary").setAttribute("aria-busy","false");
    if(!$("platform").value)$("platform").value=data.platform_id||"";
  }
  async function load() {
    clearPreview("填写会话信息，查看每项功能的判断。");
    const stamp=++statusEpoch;$("refresh").disabled=true;$("global-error").hidden=true;$("summary").setAttribute("aria-busy","true");
    try {
      if(!bridge)throw new Error("no bridge");
      await timed(bridge.ready());const result=await timed(bridge.apiGet("/permissions/status"));
      if(stamp!==statusEpoch)return;renderOverview(result);
    } catch (_) {
      if(stamp!==statusEpoch)return;
      $("global-error").textContent="暂时无法读取插件状态。请从 AstrBot 的插件页打开本面板；登录失效时重新登录，然后点击刷新状态。";
      $("global-error").hidden=false;$("summary").replaceChildren(node("p","状态尚未读取；不会据此判定功能已开启。"));
    } finally {if(stamp===statusEpoch){$("refresh").disabled=false;$("summary").setAttribute("aria-busy","false");}}
  }
  function renderResult(result) {
    $("preview-message").hidden=true;
    $("result-context").textContent=(result.target.group_id?"群聊":"私聊")+" · "+(result.is_admin?"原生管理员":"普通发起人");
    $("result-list").replaceChildren(...result.items.map(item=>{
      const article=node("article",undefined,"result-row");const heading=node("div",undefined,"section-title");
      const cls=item.state==="denied"||item.state==="disabled"?"bad":item.state==="public_allowed"?"":"wait";
      heading.append(node("h3",item.title),node("span",labels[item.state]||"待核对","badge "+cls));
      const checks=node("div",undefined,"checks");
      const scope=item.required_scope?(item.local_scope_present?"本机已存该授权":"本机未找到该授权"):"无需额外数据授权";
      checks.append(node("span","规则："+(item.rule.allowed?"允许":"拒绝")+(item.rule.name?" · "+item.rule.name:"")),node("span","功能："+(item.feature_enabled?"开启":"关闭")),node("span",scope),node("span",item.server==="not_checked"?"服务端：待实际请求校验":"服务端：读取时复核可见性"));
      article.append(heading,node("p",item.reason),checks);return article;
    }));
    if(result.grant.state==="stored"&&result.grant.access_expired){const note=node("p","本机访问凭据已到期；正常请求由插件处理刷新，这不等于账号已解绑。本次预览没有刷新凭据。","notice");$("result-list").prepend(note);}
  }
  $("preview-form").addEventListener("input",()=>clearPreview());
  $("preview-form").addEventListener("submit",async event=>{
    event.preventDefault();clearPreview("正在按当前规则判断…");const stamp=epoch;
    $("preview-submit").disabled=true;$("result-list").setAttribute("aria-busy","true");
    const body={platform_id:$("platform").value.trim(),bot_id:$("bot").value.trim(),sender_id:$("sender").value.trim(),group_id:$("group").value.trim(),member_isolated:$("isolated").checked};
    try {if(!bridge)throw new Error("no bridge");const result=await timed(bridge.apiPost("/permissions/preview",body));if(stamp!==epoch)return;if(!Array.isArray(result.items))throw new Error("invalid result");renderResult(result);}
    catch(_){if(stamp===epoch){$("preview-message").hidden=false;$("preview-message").textContent="未能取得判断。请核对输入与后台登录状态，再点击预览权限重试。";}}
    finally {if(stamp===epoch){$("preview-submit").disabled=false;$("result-list").setAttribute("aria-busy","false");}}
  });
  $("refresh").addEventListener("click",load);
  if(bridge?.onContext)bridge.onContext(context=>document.documentElement.setAttribute("data-theme",context.isDark?"dark":"light"));
  load();
})();

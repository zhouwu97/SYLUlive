import {useState,useEffect} from 'react';
import {Link} from 'react-router-dom';
import {mergeCourses,teachingWeek,gradeStats} from '@sylulive/academic-contracts';
import {useAcademic} from './academic';
import {useAuth} from './auth';
import {useAssistantProbe} from './use-assistant-probe';
import {AssistantInstallGuide} from './assistant-guide';
import {useApi,write,entity} from './api';
import {Empty,Form,Head,QueryState,useUI} from './ui';
const initial=['gpa','free','physical','checkin','lottery','diagnostic'];
const names:Record<string,string>={gpa:'GPA 计算',free:'空闲时间',physical:'体测资料',checkin:'校园签到',lottery:'校园抽奖',diagnostic:'教务连接诊断'};
export function Toolbox(){
  const ui=useUI(),auth=useAuth();const [order,setOrder]=useState<string[]>(()=>{try{const value=JSON.parse(localStorage.getItem('sylulive-tool-order')||'null');return Array.isArray(value)&&value.length===6&&new Set(value).size===6&&value.every(x=>initial.includes(x))?value:initial}catch{return initial}});
  function open(id:string){if(['checkin','lottery'].includes(id)&&!auth.requireUser())return;ui.open(names[id],id==='gpa'?<Gpa/>:id==='free'?<Free/>:id==='checkin'?<Checkin/>:id==='lottery'?<Lottery/>:<Diagnostic/>)}
  return <><Head title="工具箱" description="常用校园计算与查询，可调整入口顺序"/><div className="three-col">{order.map((id,i)=><section className="panel panel-pad" key={id}><h3>{names[id]}</h3><p className="muted">{id==='gpa'?'按学分加权计算，以学校公布结果为准':id==='free'?'从当前课表计算本周无课节次':id==='physical'?'通过教务助手从本机查询体测资料':id==='checkin'?'查看连续签到和补签状态':id==='lottery'?'查看当前活动、参与状态与结果':'检测助手版本及本机连接能力'}</p><div className="form-actions">{id==='physical'?<Link className="btn" to="/grades?tab=physical">打开体测</Link>:<button className="btn" onClick={()=>open(id)}>打开</button>}<button className="link-btn" disabled={i===0} onClick={()=>{const next=[...order];[next[i-1],next[i]]=[next[i],next[i-1]];setOrder(next);localStorage.setItem('sylulive-tool-order',JSON.stringify(next))}}>上移</button></div></section>)}</div></>;
}
function Gpa(){const {data}=useAcademic();const stats=gradeStats(data.grades);const [result,setResult]=useState<number|null>(null);return <><p>已导入成绩的加权 GPA：{stats.gpa?.toFixed(2)||'暂无数据'}</p><Form fields={[{name:'rows',label:'每行填写：学分,绩点',type:'textarea',required:true}]} submit="计算" onSubmit={async values=>{let total=0,weighted=0;for(const line of String(values.rows).split('\n').filter(s=>s.trim())){const pair=line.split(/[,，]/).map(Number);if(pair.length!==2||!pair.every(Number.isFinite)||pair[0]<=0||pair[1]<0||pair[1]>5)throw new Error('请输入有效学分和 0–5 的绩点');total+=pair[0];weighted+=pair[0]*pair[1]}if(!total)throw new Error('请输入至少一门课程');setResult(weighted/total)}}/>{result!==null&&<p className="metric">加权 GPA：{result.toFixed(3)}</p>}</>}
function Free(){const {data}=useAcademic();const week=teachingWeek(data.termStart);const courses=mergeCourses(data.courses,data.overrides).filter(c=>c.weeks.includes(week));return <><p>第 {week} 周 · 基于当前课表，本地计算</p>{Array.from({length:7},(_,i)=><p key={i}>周{'一二三四五六日'[i]}：{Array.from({length:12},(_,p)=>p+1).filter(p=>!courses.some(c=>c.day===i+1&&c.periods.includes(p))).join('、')||'没有空闲节次'}</p>)}<Link to="/schedule">前往课表核对</Link></>}
function Checkin(){const q=useApi('/api/user/checkin/status'),ui=useUI();return <QueryState query={q}><p>{q.data?.check_in_date} · {q.data?.checked_in?'今天已签到':'今天未签到'}</p><p>连续 {q.data?.streak_days||0} 天 · 补签卡 {q.data?.makeup_cards||0} 张</p><button className="btn primary" disabled={q.data?.checked_in} onClick={()=>void ui.act(()=>write('/api/user/checkin'),'签到成功')}>今日签到</button><Form fields={[{name:'check_in_date',label:'补签日期',type:'date',required:true}]} submit="使用补签卡" onSubmit={async values=>{await write('/api/user/checkin/makeup',values);await q.refetch();ui.notify('补签成功')}}/></QueryState>}
function Lottery(){const q=useApi('/api/lottery/current'),ui=useUI(),event=entity(q.data,'event');return <QueryState query={q}><h3>{event.title||event.prize_name||'校园抽奖'}</h3><p>{event.description}</p><p>参与人数 {q.data?.participant_count||0} · 开奖时间 {event.draw_time}</p><p>{event.winner?.nickname?`获奖者：${event.winner.nickname}`:''}</p><button className="btn primary" disabled={q.data?.joined||event.status!==0} onClick={()=>void ui.act(()=>write(`/api/lottery/${event.id}/join`),'参与状态已保存')}>{q.data?.joined?'已参与':'参加本期活动'}</button></QueryState>}
const providerNames:Record<string,string>={undergraduate:'本科教务',graduate:'研究生教务',erke:'二课 WebVPN',physical:'体测'};
function Diagnostic(){
  const assistant=useAssistantProbe({autoStart:false});
  const [status,setStatus]=useState('点击检测，检查网页与教务助手的连接');
  useEffect(()=>{
    if(assistant.state==='ready'){
      // 新版助手会在握手时报告本机授权位，这里据此区分「装了但没授权」和「还没装」。
      const granted=assistant.authorized?Object.entries(assistant.authorized).filter(([,ok])=>ok).map(([p])=>providerNames[p]||p):[];
      setStatus(`已连接助手 ${assistant.extensionVersion||'未知版本'}，提供 ${assistant.capabilityCount} 个系统适配器。${granted.length?`本机已授权：${granted.join('、')}。`:''}学校登录与查询状态请在对应资料页面核对。`);
    }
    else if(assistant.state==='missing')setStatus('未检测到教务助手，请按下方说明安装，装好后本页会自动复检，不必刷新。');
  },[assistant.state,assistant.extensionVersion,assistant.capabilityCount,assistant.authorized]);
  return <><p role="status">{status}</p><button className="btn" onClick={assistant.recheck}>检测助手</button><AssistantInstallGuide state={assistant.state} onRecheck={assistant.recheck}/></>;
}

import {useState,useEffect} from 'react';
import {Link} from 'react-router-dom';
import {mergeCourses,teachingWeek,gradeStats} from '@sylulive/academic-contracts';
import {useAcademic} from './academic';
import {useAuth} from './auth';
import {useAssistantProbe} from './use-assistant-probe';
import {AssistantInstallGuide} from './assistant-guide';
import {useApi,write,entity} from './api';
import {Empty,Form,Head,Icon,QueryState,useUI} from './ui';
// 工具箱分组与 App（client/lib/screens/toolbox_screen.dart）保持一致；Web 独有的计算与诊断放在「更多工具」。
type Tool = { id: string; title: string; subtitle: string; icon: string; to?: string; href?: string; modal?: string };
const groups: { title: string; tools: Tool[] }[] = [
  { title: '常用工具', tools: [
    { id: 'erke', title: '二课分查询', subtitle: '支持 WebVPN 穿透', icon: 'grades', to: '/grades?tab=erke' },
    { id: 'physical', title: '体测成绩', subtitle: '通过教务助手查询', icon: 'ratings', to: '/grades?tab=physical' },
    { id: 'exams', title: '考试日程', subtitle: '考试安排与倒计时', icon: 'exams', to: '/exams' },
    { id: 'papers', title: '试卷库', subtitle: '历年试卷 / 投稿审核', icon: 'file', to: '/exams?tab=papers' },
    { id: 'sites', title: '网站大全', subtitle: '用得到的网站', icon: 'campus', modal: 'sites' },
  ] },
  { title: '校园与娱乐', tools: [
    { id: 'genshin', title: '云原神', subtitle: '点击即玩', icon: 'ai', href: 'https://ys.mihoyo.com/cloud/' },
    { id: 'lottery', title: '抽奖活动', subtitle: '公平福利派送', icon: 'competition', modal: 'lottery' },
  ] },
  { title: '更多工具', tools: [
    { id: 'gpa', title: 'GPA 计算', subtitle: '按学分加权计算，以学校公布结果为准', icon: 'trending', modal: 'gpa' },
    { id: 'free', title: '空闲时间', subtitle: '从当前课表计算本周无课节次', icon: 'clock', modal: 'free' },
    { id: 'checkin', title: '校园签到', subtitle: '查看连续签到和补签状态', icon: 'check', modal: 'checkin' },
    { id: 'diagnostic', title: '教务连接诊断', subtitle: '检测助手版本及本机连接能力', icon: 'monitor', modal: 'diagnostic' },
  ] },
];
// 与 App「网站大全」同一份清单。
const sites: [string, string, string][] = [
  ['省大创平台', '创新创业训练计划', 'https://cxcy.upln.cn/'],
  ['教务处', '教务通知与公告', 'https://jwc.sylu.edu.cn/'],
  ['创院', '创新创业学院', 'https://cxcyxy.sylu.edu.cn/'],
  ['查二课', 'WebVPN 入口', 'https://webvpn.sylu.edu.cn/'],
  ['图书馆', '馆藏与资源服务', 'https://tsg.sylu.edu.cn/'],
  ['沈理就业网', '招聘就业信息', 'https://job.sylu.edu.cn/'],
  ['蓝桥杯成绩', '竞赛成绩快速查询', 'https://c16h22o4.github.io/'],
  ['四六级', 'CET 报名与成绩查询', 'https://cet.neea.edu.cn/'],
  ['计算机等级考试', 'NCRE 报名与证书查询', 'https://ncre.neea.edu.cn/'],
  ['教师资格证', 'NTCE 报名与认定', 'https://ntce.neea.edu.cn/'],
];
export function Toolbox(){
  const ui=useUI(),auth=useAuth();
  function open(tool:Tool){
    if(['checkin','lottery'].includes(tool.id)&&!auth.requireUser())return;
    ui.open(tool.title,tool.modal==='gpa'?<Gpa/>:tool.modal==='free'?<Free/>:tool.modal==='checkin'?<Checkin/>:tool.modal==='lottery'?<Lottery/>:tool.modal==='sites'?<Sites/>:<Diagnostic/>);
  }
  const body=(tool:Tool)=><><span className="tool-icon"><Icon name={tool.icon} size={24}/></span><span className="tool-tile-copy"><b>{tool.title}</b><small>{tool.subtitle}</small></span><Icon name={tool.href?'share':'chevron'} size={16}/></>;
  return <><Head title="工具箱" description="学习、查询与校园工具"/>
    {groups.map(group=><section className="tool-group" key={group.title} aria-label={group.title}>
      <h2 className="tool-group-title">{group.title}</h2>
      <div className="tool-grid">{group.tools.map(tool=>tool.to?<Link key={tool.id} className="tool-tile" to={tool.to}>{body(tool)}</Link>
        :tool.href?<a key={tool.id} className="tool-tile" href={tool.href} target="_blank" rel="noopener noreferrer">{body(tool)}</a>
        :<button key={tool.id} type="button" className="tool-tile" onClick={()=>open(tool)}>{body(tool)}</button>)}</div>
    </section>)}
  </>;
}
function Sites(){return <div className="site-list">{sites.map(([title,subtitle,url])=><a key={url} className="site-link" href={url} target="_blank" rel="noopener noreferrer"><b>{title}</b><small>{subtitle}</small><Icon name="share" size={15}/></a>)}</div>}
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

import {useState} from 'react';
import {Link} from 'react-router-dom';
import {useAuth} from './auth';
import {useAcademic, AcademicSettings} from './academic';
import {asset,downloadJSON,rows,upload,useApi,write,type Entity} from './api';
import {Empty,Form,Head,QueryState,Tabs,useUI} from './ui';
import {PostCard} from './community';
export function Profile(){
  const auth=useAuth(),ui=useUI(),store=useAcademic();const [tab,setTab]=useState('posts');
  if(!auth.user)return <Empty title="登录后查看个人主页"><button className="btn primary" onClick={auth.login}>登录</button></Empty>;
  const user=auth.user;
  return <><Head title="我的主页"><button className="btn" onClick={()=>ui.open('账号安全',<Security/>)}>账号安全</button><button className="btn" onClick={auth.logout}>退出登录</button></Head>
    <section className="panel panel-pad">{user.background&&<img className="profile-cover" src={asset(user.background)} alt="个人背景"/>}<div className="profile-head"><img className="avatar" src={asset(user.avatar)} alt="头像"/><div><h2>{user.nickname}</h2><p>账号 #{user.id}</p></div></div>
    <div className="form-actions"><button className="btn" onClick={()=>ui.open('编辑资料',<EditProfile user={user}/>)}>编辑资料与图片</button><button className="btn" onClick={()=>ui.open('本地资料',<AcademicSettings/>)}>导入与导出校园资料</button><button className="btn" onClick={()=>ui.open('隐私与本地数据',<><p>校园资料默认仅保留在当前页面会话。扩展中启用的缓存和提醒可在课表连接及提醒设置内清除。</p><a className="btn" href="/api/user/privacy/export" target="_blank" rel="noreferrer">导出服务器个人数据</a><button className="btn" onClick={()=>{store.setData(s=>({...s,courses:[],grades:[],exams:[],overrides:{}}));store.setUpdated('');ui.notify('当前页面的校园资料已清除');ui.close()}}>清除当前页面校园资料</button><p><Link to="/feedback" onClick={ui.close}>提交数据更正或删除请求</Link></p></>)}>隐私与数据管理</button></div></section>
    <Tabs value={tab} tabs={[["posts","我的帖子"],["market","我的闲置"],["bookmarks","我的收藏"],["evaluations","课程评价"],["following","关注"],["followers","粉丝"]]} onChange={setTab}/><MyContent key={tab} tab={tab} userId={user.id}/>
  </>;
}
function EditProfile({user}:{user:Entity}){const ui=useUI();return <Form fields={[{name:'nickname',label:'昵称',value:user.nickname,required:true},{name:'gender',label:'性别',value:user.gender||'',options:[['','不公开'],['male','男'],['female','女']]},{name:'avatar',label:'更新头像',type:'file'},{name:'background',label:'更新背景',type:'file'}]} onSubmit={async(values,form)=>{await write('/api/user/profile',{nickname:values.nickname,gender:values.gender},'PUT');for(const key of ['avatar','background']){const file=form.get(key);if(file instanceof File&&file.size){const url=await upload(file);await write(`/api/user/${key}`,{[key]:url},'PUT')}}await ui.act(async()=>{},'资料已保存');ui.close()}}/>}
function MyContent({tab,userId}:{tab:string;userId:number}){
  const ui=useUI();const path=tab==='bookmarks'?'/api/user/bookmarks':tab==='evaluations'?'/api/user/course-evaluations':`/api/user/${userId}/${tab==='market'?'market-posts':tab}`;const q=useApi(path);const people=['following','followers'].includes(tab);
  return <QueryState query={q}><div className="panel">{rows(q.data,'users','following','followers').map(x=>people?<div className="list-row" key={x.id}><img className="avatar" src={asset(x.avatar)} alt=""/><div className="list-main"><b>{x.nickname}</b></div>{tab==='following'&&<button className="btn" onClick={()=>void ui.act(()=>write(`/api/user/${x.id}/follow`,{},'DELETE'),'已取消关注')}>取消关注</button>}</div>:tab==='evaluations'?<div className="list-row" key={x.id}><div className="list-main"><b>{x.subject_name||x.course_name||'课程评价'}</b><p>{x.status} · {x.comment||x.content}</p></div></div>:<PostCard key={x.id} post={x.post||x}/>)}{!rows(q.data,'users','following','followers').length&&<Empty title="暂无内容"/>}</div></QueryState>;
}
function Security(){const q=useApi('/api/user/account-security'),ui=useUI();return <QueryState query={q}><p>绑定邮箱：{q.data?.email_masked||q.data?.email||'未绑定'}</p><Form fields={[{name:'old_password',label:'当前密码',type:'password',required:true},{name:'new_password',label:'新密码（8–32 位）',type:'password',required:true}]} submit="修改密码" onSubmit={async values=>{await write('/api/change_password',values);ui.notify('密码已修改，请按服务器状态重新登录');ui.close()}}/></QueryState>}

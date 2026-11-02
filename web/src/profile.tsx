import {useId,useState,type KeyboardEvent} from 'react';
import {Link} from 'react-router-dom';
import {useAuth} from './auth';
import {useAcademic, AcademicSettings} from './academic';
import {asset,rows,upload,useApi,write,type Entity} from './api';
import {Empty,Form,Head,Icon,QueryState,useUI} from './ui';
import {PostCard} from './community';
const profileTabs: [string, string][] = [["posts", "我的帖子"], ["market", "我的闲置"], ["bookmarks", "我的收藏"], ["evaluations", "课程评价"], ["following", "关注"], ["followers", "粉丝"]];
const profileEmpty: Record<string, {title: string; description: string; to: string; action: string}> = {
  posts: {title: '还没有发布帖子', description: '分享校园日常，发布的内容会出现在这里。', to: '/community', action: '去校园社区'},
  market: {title: '还没有发布闲置', description: '让闲置物品找到需要它的人。', to: '/market', action: '去二手集市'},
  bookmarks: {title: '还没有收藏内容', description: '遇到喜欢的帖子，收藏后就能在这里找到。', to: '/community', action: '浏览校园社区'},
  evaluations: {title: '还没有课程评价', description: '分享上课体验，帮助同学了解课程。', to: '/ratings', action: '浏览课程评价'},
  following: {title: '还没有关注同学', description: '在校园社区发现感兴趣的同学。', to: '/community', action: '去校园社区'},
  followers: {title: '还没有粉丝', description: '分享你的校园生活，让更多同学认识你。', to: '/community', action: '去校园社区'},
};

export function Profile() {
  const auth = useAuth(), ui = useUI(), store = useAcademic();
  const [tab, setTab] = useState('posts');
  const contentId = useId();
  if (auth.loading) return <div className="profile-page"><Head title="我的主页"/><div className="loading-state" role="status">正在加载个人资料…</div></div>;
  if (!auth.user) return <div className="profile-page"><Head title="我的主页" description="记录校园日常，整理个人资料。"/><Empty title="登录后查看个人主页" description="你的发布、收藏和校园资料，在这里集中整理。"><button className="btn primary" onClick={auth.login}>登录</button></Empty></div>;
  const user = auth.user, nickname = user.nickname || '校园同学';
  const avatar = asset(user.avatar), cover = asset(user.background);
  function openPrivacy() {
    ui.open('隐私与本地数据', <><p>校园资料默认仅保留在当前页面会话。扩展中启用的缓存和提醒可在课表连接及提醒设置内清除。</p><a className="btn" href="/api/user/privacy/export" target="_blank" rel="noreferrer">导出服务器个人数据</a><button className="btn" onClick={() => {store.setData(s => ({...s, courses: [], grades: [], exams: [], overrides: {}}));store.setUpdated('');ui.notify('当前页面的校园资料已清除');ui.close()}}>清除当前页面校园资料</button><p><Link to="/feedback" onClick={ui.close}>提交数据更正或删除请求</Link></p></>);
  }
  return <div className="profile-page">
    <Head title="我的主页" description="记录校园日常，整理个人资料。">
      <button className="btn" onClick={() => ui.open('账号安全', <Security/>)}><Icon name="admin" size={16}/>账号安全</button>
      <button className="btn profile-logout" onClick={auth.logout}>退出登录</button>
    </Head>
    <section className="panel profile-card" aria-label="个人资料">
      <div className="profile-cover-wrap"><ProfilePhoto key={`${user.id}:${cover}`} src={cover} cover/></div>
      <div className="profile-card-body">
        <div className="profile-identity-row">
          <div className="profile-identity">
            <div className="profile-avatar"><ProfilePhoto key={`${user.id}:${avatar}`} src={avatar} name={nickname}/></div>
            <div className="profile-name"><h2>{nickname}</h2><span className="profile-account">账号 #{user.id}</span>
              {(typeof user.following_count === 'number' || typeof user.followers_count === 'number') && <div className="profile-social" aria-label="关注与粉丝">
                {typeof user.following_count === 'number' && <button onClick={() => setTab('following')}><b>{user.following_count}</b><span>关注</span></button>}
                {typeof user.followers_count === 'number' && <button onClick={() => setTab('followers')}><b>{user.followers_count}</b><span>粉丝</span></button>}
              </div>}
            </div>
          </div>
          <button className="btn primary profile-edit" aria-label="编辑资料与图片" onClick={() => ui.open('编辑资料', <EditProfile user={user}/>)}><Icon name="profile" size={16}/>编辑资料</button>
        </div>
      </div>
    </section>
    <div className="profile-columns">
      <aside className="panel profile-tools" aria-label="个人工具">
        <h2>资料与设置</h2>
        <button className="profile-tool" aria-label="导入与导出校园资料" onClick={() => ui.open('本地资料', <AcademicSettings/>)}><span className="profile-tool-icon"><Icon name="grades"/></span><span><b>校园资料</b><small>导入或导出课表与成绩</small></span><span className="profile-tool-arrow" aria-hidden="true">›</span></button>
        <button className="profile-tool" aria-label="隐私与数据管理" onClick={openPrivacy}><span className="profile-tool-icon"><Icon name="admin"/></span><span><b>隐私与数据</b><small>导出数据、管理本地资料</small></span><span className="profile-tool-arrow" aria-hidden="true">›</span></button>
      </aside>
      <div className="profile-content"><div className="profile-content-tabs"><ProfileTabs value={tab} onChange={setTab} contentId={contentId}/></div>
      <section id={contentId} className="profile-content-region" role="tabpanel" aria-labelledby={`${contentId}-${tab}`} tabIndex={0}><MyContent key={tab} tab={tab} userId={user.id}/></section></div>
    </div>
  </div>;
}

function ProfileTabs({value, onChange, contentId}: {value: string; onChange: (value: string) => void; contentId: string}) {
  function navigate(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    let next: number;
    switch (event.key) {
      case 'ArrowRight': next = (index + 1) % profileTabs.length; break;
      case 'ArrowLeft': next = (index + profileTabs.length - 1) % profileTabs.length; break;
      case 'Home': next = 0; break;
      case 'End': next = profileTabs.length - 1; break;
      default: return;
    }
    event.preventDefault();
    onChange(profileTabs[next][0]);
    const button = event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>('[role="tab"]')[next];
    button?.focus({preventScroll: true});
    button?.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'});
  }
  return <div className="tabs" role="tablist" aria-label="个人内容">{profileTabs.map(([key, label], index) => <button key={key} id={`${contentId}-${key}`} className={`tab ${value === key ? 'active' : ''}`} role="tab" aria-selected={value === key} aria-controls={contentId} tabIndex={value === key ? 0 : -1} onClick={event => {onChange(key);event.currentTarget.scrollIntoView({block: 'nearest', inline: 'nearest', behavior: 'instant'})}} onKeyDown={event => navigate(event, index)}>{label}</button>)}</div>;
}

function ProfilePhoto({src, name = '', cover = false}: {src?: string; name?: string; cover?: boolean}) {
  const ui = useUI();
  const [failed, setFailed] = useState(false);
  const label = cover ? '完整封面' : '头像';
  const fallback = <span className="profile-avatar-fallback" role="img" aria-label={`${name}的头像`}>{Array.from(name)[0] || '同'}</span>;
  if (!src) return cover ? null : fallback;
  return <button type="button" className="profile-photo-button" aria-label={failed ? `${label}加载失败，点击重试` : `查看${label}`} title={failed ? '图片加载失败，点击重试' : `查看${label}`} onClick={() => failed ? setFailed(false) : ui.open(cover ? '个人封面' : '头像', <ProfileImagePreview src={src} label={label}/>)}>
    {failed ? cover ? <span className="profile-photo-error">封面加载失败 · 点击重试</span> : fallback : <img src={src} alt={cover ? '个人封面' : `${name}的头像`} onError={() => setFailed(true)}/>}
    {cover && !failed && <span className="profile-photo-hint"><Icon name="search" size={14}/>查看完整封面</span>}
  </button>;
}

function ProfileImagePreview({src, label}: {src: string; label: string}) {
  const [failed, setFailed] = useState(false);
  return <div className="profile-image-preview">
    <div className="profile-image-stage">{failed ? <Empty title="图片暂时无法加载" description="请重试，或打开原图查看。"><button className="btn" onClick={() => setFailed(false)}>重试</button></Empty> : <img src={src} alt={label} onError={() => setFailed(true)}/>}</div>
    <a className="btn" href={src} target="_blank" rel="noreferrer">打开原图<Icon name="search" size={16}/></a>
  </div>;
}
function EditProfile({user}:{user:Entity}){const ui=useUI();return <Form fields={[{name:'nickname',label:'昵称',value:user.nickname,required:true},{name:'gender',label:'性别',value:user.gender||'',options:[['','不公开'],['male','男'],['female','女']]},{name:'avatar',label:'更新头像',type:'file'},{name:'background',label:'更新背景',type:'file'}]} onSubmit={async(values,form)=>{await write('/api/user/profile',{nickname:values.nickname,gender:values.gender},'PUT');for(const key of ['avatar','background']){const file=form.get(key);if(file instanceof File&&file.size){const url=await upload(file);await write(`/api/user/${key}`,{[key]:url},'PUT')}}await ui.act(async()=>{},'资料已保存');ui.close()}}/>}
function MyContent({tab,userId}:{tab:string;userId:number}){
  const ui=useUI();const path=tab==='bookmarks'?'/api/user/bookmarks':tab==='evaluations'?'/api/user/course-evaluations':`/api/user/${userId}/${tab==='market'?'market-posts':tab}`;const q=useApi(path);const people=['following','followers'].includes(tab);
  const items=rows(q.data,'users','following','followers'), empty=profileEmpty[tab] || profileEmpty.posts;
  if (!q.isPending && !q.error && !items.length) return <Empty title={empty.title} description={empty.description}><Link className="btn profile-empty-action" to={empty.to}>{empty.action}<span aria-hidden="true">→</span></Link></Empty>;
  return <QueryState query={q}><div className={`profile-feed ${people||tab==='evaluations'?'panel':''}`}>{items.map(x=>people?<div className="list-row" key={x.id}><img className="avatar" src={asset(x.avatar)} alt=""/><div className="list-main"><b>{x.nickname}</b></div>{tab==='following'&&<button className="btn" onClick={()=>void ui.act(()=>write(`/api/user/${x.id}/follow`,{},'DELETE'),'已取消关注')}>取消关注</button>}</div>:tab==='evaluations'?<div className="list-row" key={x.id}><div className="list-main"><b>{x.subject_name||x.course_name||'课程评价'}</b><p>{x.status} · {x.comment||x.content}</p></div></div>:<PostCard key={x.id} post={x.post||x}/>)}</div></QueryState>;
}
function Security(){const q=useApi('/api/user/account-security'),ui=useUI();return <QueryState query={q}><p>绑定邮箱：{q.data?.email_masked||q.data?.email||'未绑定'}</p><Form fields={[{name:'old_password',label:'当前密码',type:'password',required:true},{name:'new_password',label:'新密码（8–32 位）',type:'password',required:true}]} submit="修改密码" onSubmit={async values=>{await write('/api/change_password',values);ui.notify('密码已修改，请按服务器状态重新登录');ui.close()}}/></QueryState>}

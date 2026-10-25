import {useState, type ReactNode} from 'react';
import {Link, useParams} from 'react-router-dom';
import {useAuth} from './auth';
import {useAcademic, AcademicSettings} from './academic';
import {entity, rows, upload, useApi, write, type Entity} from './api';
import {Empty, Form, Head, Icon, QueryState, Tabs, useUI} from './ui';
import {PostCard} from './community';
import {Avatar, ServerImage} from './post-media';

function ProfileStats({user}: {user: Entity}) {
  const stats = [
    ['following_count', '关注'],
    ['followers_count', '粉丝'],
    ['total_likes_received', '获赞'],
  ].filter(([field]) => typeof user[field] === 'number' && Number.isFinite(user[field]) && user[field] >= 0);
  if (!stats.length) return null;
  return <div className="profile-stats">
    {stats.map(([field, label]) => <div key={field}><b>{user[field].toLocaleString('zh-CN')}</b><span>{label}</span></div>)}
  </div>;
}

function ProfileSummary({user, children}: {user: Entity; children?: ReactNode}) {
  return <section className="panel profile-summary">
    {(user.background_preview_url || user.background) && <ServerImage
      className="profile-cover"
      sources={[user.background_preview_url, user.background]}
      alt={`${user.nickname || '校园同学'}的个人背景`}
    />}
    <div className="profile-head">
      <Avatar user={user} className="avatar profile-avatar" />
      <div><h2>{user.nickname || '校园同学'}</h2><p>校园账号 #{user.id}</p></div>
    </div>
    <ProfileStats user={user} />
    {children}
  </section>;
}

export function Profile() {
  const auth = useAuth(), ui = useUI(), store = useAcademic();
  const [tab, setTab] = useState('posts');
  if (auth.loading) return <div className="profile-page"><Head title="我的主页"/><div className="loading-state" role="status">正在加载个人资料…</div></div>;
  if (!auth.user) return <div className="profile-page">
    <Head title="我的主页" />
    <section className="panel profile-guest">
      <Icon name="profile" size={30} />
      <div><h2>把校园日常留在这里</h2><p>登录后查看自己的帖子、闲置和收藏，管理个人资料。</p></div>
      <div className="profile-actions"><button className="btn primary" onClick={auth.login}>登录</button><Link className="btn" to="/community">先逛逛社区</Link></div>
    </section>
  </div>;
  const user = auth.user;
  return <div className="profile-page">
    <Head title="我的主页"><button className="btn" onClick={() => ui.open('账号安全', <Security />)}>账号安全</button><button className="btn" onClick={auth.logout}>退出登录</button></Head>
    <ProfileSummary user={user}>
      <div className="profile-actions form-actions">
        <button className="btn primary" onClick={() => ui.open('编辑资料', <EditProfile user={user} />)}>编辑资料与图片</button>
        <button className="btn" onClick={() => ui.open('本地资料', <AcademicSettings />)}>导入与导出校园资料</button>
        <button className="btn" onClick={() => ui.open('隐私与本地数据', <>
          <p>校园资料默认仅保留在当前页面会话。扩展中启用的缓存和提醒可在课表连接及提醒设置内清除。</p>
          <a className="btn" href="/api/user/privacy/export" target="_blank" rel="noreferrer">导出服务器个人数据</a>
          <button className="btn" onClick={() => {
            store.setData(s => ({...s, courses: [], grades: [], exams: [], overrides: {}}));
            store.setUpdated(''); ui.notify('当前页面的校园资料已清除'); ui.close();
          }}>清除当前页面校园资料</button>
          <p><Link to="/feedback" onClick={ui.close}>提交数据更正或删除请求</Link></p>
        </>)}>隐私与数据管理</button>
      </div>
    </ProfileSummary>
    <Tabs value={tab} tabs={[["posts", "我的帖子"], ["market", "我的闲置"], ["bookmarks", "我的收藏"], ["evaluations", "课程评价"], ["following", "关注"], ["followers", "粉丝"]]} onChange={setTab} />
    <MyContent key={tab} tab={tab} userId={user.id} />
  </div>;
}

export function UserProfile() {
  const {id} = useParams();
  const validID = !!id && /^[1-9]\d*$/.test(id);
  const q = useApi(validID ? `/api/user/${id}` : null);
  const [tab, setTab] = useState('posts');
  const user = entity(q.data, 'user');
  if (!validID) return <Empty title="用户不存在"><Link className="btn" to="/community">返回社区</Link></Empty>;
  return <div className="profile-page">
    <Head title="个人主页"><Link className="btn" to="/community">返回社区</Link></Head>
    <QueryState query={q}>
      {user.id ? <>
        <ProfileSummary user={user} />
        <Tabs value={tab} tabs={[["posts", "帖子"], ["market", "闲置"], ["following", "关注"], ["followers", "粉丝"]]} onChange={setTab} />
        <MyContent key={`${id}:${tab}`} tab={tab} userId={Number(user.id)} own={false} />
      </> : <Empty title="暂无公开资料"><Link className="btn" to="/community">返回社区</Link></Empty>}
    </QueryState>
  </div>;
}

function EditProfile({user}: {user: Entity}) {
  const ui = useUI();
  return <Form fields={[
    {name: 'nickname', label: '昵称', value: user.nickname, required: true},
    {name: 'gender', label: '性别', value: user.gender || '', options: [['', '不公开'], ['male', '男'], ['female', '女']]},
    {name: 'avatar', label: '更新头像', type: 'file'},
    {name: 'background', label: '更新背景', type: 'file'},
  ]} onSubmit={async (values, form) => {
    await write('/api/user/profile', {nickname: values.nickname, gender: values.gender}, 'PUT');
    for (const key of ['avatar', 'background']) {
      const file = form.get(key);
      if (file instanceof File && file.size) {
        const url = await upload(file);
        await write(`/api/user/${key}`, {[key]: url}, 'PUT');
      }
    }
    await ui.act(async () => {}, '资料已保存'); ui.close();
  }} />;
}

function MyContent({tab, userId, own = true}: {tab: string; userId: number; own?: boolean}) {
  const ui = useUI();
  const path = tab === 'bookmarks' ? '/api/user/bookmarks' : tab === 'evaluations' ? '/api/user/course-evaluations' : `/api/user/${userId}/${tab === 'market' ? 'market-posts' : tab}`;
  const q = useApi(path), people = ['following', 'followers'].includes(tab);
  const items = rows(q.data, 'users', 'following', 'followers');
  return <QueryState query={q}>
    <div className="panel profile-content">
      {items.map(x => people ? <div className="list-row" key={x.id}>
        <Link to={`/user/${x.id}`} aria-label={`查看${x.nickname || '校园同学'}的主页`}><Avatar user={x} className="avatar" /></Link>
        <div className="list-main"><Link to={`/user/${x.id}`}><b>{x.nickname || '校园同学'}</b></Link></div>
        {own && tab === 'following' && <button className="btn" onClick={() => void ui.act(() => write(`/api/user/${x.id}/follow`, {}, 'DELETE'), '已取消关注')}>取消关注</button>}
      </div> : tab === 'evaluations' ? <div className="list-row" key={x.id}><div className="list-main"><b>{x.subject_name || x.course_name || '课程评价'}</b><p>{x.status} · {x.comment || x.content}</p></div></div> : <PostCard key={x.id} post={x.post || x} />)}
      {!items.length && <Empty title={people ? tab === 'following' ? '暂无关注' : '暂无粉丝' : tab === 'bookmarks' ? '暂无收藏' : '暂无内容'} />}
    </div>
  </QueryState>;
}

function Security() {
  const q = useApi('/api/user/account-security'), ui = useUI();
  return <QueryState query={q}><p>绑定邮箱：{q.data?.email_masked || q.data?.email || '未绑定'}</p><Form fields={[{name: 'old_password', label: '当前密码', type: 'password', required: true}, {name: 'new_password', label: '新密码（8–32 位）', type: 'password', required: true}]} submit="修改密码" onSubmit={async values => {await write('/api/change_password', values); ui.notify('密码已修改，请按服务器状态重新登录'); ui.close();}} /></QueryState>;
}

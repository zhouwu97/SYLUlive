import {useLocation, useNavigate, useParams, useSearchParams} from 'react-router-dom';
import {entity, query, useApi} from './api';
import {useAuth} from './auth';
import {Empty, Icon, QueryState} from './ui';
import {PostForm} from './post-composer';

export function usePostEditor() {
  const auth = useAuth(), navigate = useNavigate(), location = useLocation();
  return ({market = location.pathname === '/market', postId}: {market?: boolean; postId?: number} = {}) => {
    if (!auth.requireUser()) return;
    const type = new URLSearchParams(location.search).get('type');
    navigate(postId ? `/post/${postId}/edit` : query('/compose', {board: market ? 2 : undefined, type: type || undefined}), {
      state: {from: location.pathname + location.search + location.hash, fromKey: location.key},
    });
  };
}

export function PostEditorPage() {
  const auth = useAuth(), location = useLocation(), navigate = useNavigate(), {id} = useParams();
  const [params] = useSearchParams();
  const editing = id !== undefined;
  const validId = !!id && /^[1-9]\d*$/.test(id);
  const postQuery = useApi(auth.user && validId ? `/api/posts/${id}` : null);
  const post = entity(postQuery.data, 'post');
  const market = editing ? post.board_id === 2 : params.get('board') === '2';
  const fallback = editing && validId ? `/post/${id}` : market ? '/market' : '/community';
  const source = location.state as {from?: unknown; fromKey?: unknown} | null;
  const supplied = source?.from;
  // 只接受站内来源，直达和刷新时使用稳定的返回位置。
  const from = typeof supplied === 'string' && /^\/(?![\\/])/.test(supplied) && !/^\/(?:compose|post\/[^/]+\/edit)(?:[/?#]|$)/.test(supplied) ? supplied : fallback;
  const back = () => typeof source?.fromKey === 'string' && window.history.state?.idx > 0 ? navigate(-1) : navigate(from, {replace: true});
  const title = editing ? '编辑帖子' : market ? '发布闲置' : '发布帖子';
  const unavailable = (body: React.ReactNode) => <section className="post-editor-page"><div className="post-editor-unavailable"><header className="post-editor-heading"><button className="link-btn" onClick={back}><Icon name="chevron" size={16}/>返回</button><h1>{title}</h1></header>{body}</div></section>;
  if (auth.loading) return unavailable(<p role="status">正在读取账号…</p>);
  if (!auth.user) return unavailable(<Empty icon="lock" title="登录后发布内容"><button className="btn primary" onClick={auth.login}>登录</button></Empty>);
  if (editing && (!validId || !postQuery.isPending && !postQuery.error && !post.id)) return unavailable(<Empty title="未找到可编辑的帖子"/>);
  if (editing && (postQuery.isPending || postQuery.error)) return unavailable(<QueryState query={postQuery}><></></QueryState>);
  if (editing && !post.viewer_permissions?.can_edit) return unavailable(<Empty icon="lock" title="当前账号不能编辑此帖" description="返回帖子查看内容，或切换到拥有编辑权限的账号。"/>);
  return <section className="post-editor-page" aria-label={title}><PostForm key={`${auth.user.id}:${id || (market ? 'market' : 'community')}`} market={market} post={editing ? post : undefined} onBack={back} origin={from}/></section>;
}

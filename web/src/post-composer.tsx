import {useEffect, useLayoutEffect, useRef, useState, type FormEvent} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {useNavigate, useSearchParams} from 'react-router-dom';
import {ApiError, captureAuthSession, errorText, request, rows, useApi, write, type Entity} from './api';
import {useAuth} from './auth';
import {Empty, Icon, useDialogCloseGuard, useUI} from './ui';
import {LegalConfirmation} from './legal-consent';
import {mediaURL, MediaUploadPicker, uploadIDs, type MediaItem} from './media';
import {readPostDraft, removePostDraft, savePostDraft, type PostDraft} from './post-drafts';
import {ServerAvatar} from './server-avatar';
import './post-composer.css';

const marketTypes = [['marketplace_sell', '出售'], ['marketplace_buy', '求购'], ['lost', '寻物'], ['found', '招领'], ['proxy', '办事']];
const length = (value: string) => Array.from(value).length;
const fileID = (image: MediaItem) => Number(image.file_id || image.file?.id || 0);
type Phase = 'editing' | 'uploading' | 'posting';

export function PostForm({market = false, post, onBack, origin}: {market?: boolean; post?: Entity; onBack: () => void; origin: string}) {
  const auth = useAuth(), ui = useUI(), nav = useNavigate(), qc = useQueryClient();
  const [params] = useSearchParams();
  market = market || post?.board_id === 2;
  const key = `${auth.user?.id}:${market ? 'market' : 'community'}:${post?.id || 'new'}`;
  const initialType = post?.post_type || params.get('type') || '';
  const resolvedType = ({sell: 'marketplace_sell', buy: 'marketplace_buy'} as Record<string, string>)[initialType] || initialType;
  const base = useRef<PostDraft>({title: post?.title || '', content: post?.content || '', postType: market ? marketTypes.some(([type]) => type === resolvedType) || resolvedType === 'exposure' && post ? resolvedType : 'marketplace_sell' : resolvedType, price: post?.price == null ? '' : String(post.price), contactType: post?.contact_type || 'wechat', contact: post?.contact || '', files: [], existing: post?.images || [], imagesChanged: false, uncertain: false});
  const [draft, setDraft] = useState<PostDraft>(() => readPostDraft(key) || base.current);
  const [preview, setPreview] = useState(false), [phase, setPhase] = useState<Phase>('editing');
  const [keyboardFocus, setKeyboardFocus] = useState(false);
  const [error, setError] = useState(''), [rulesRequired, setRulesRequired] = useState(false), [legalRequired, setLegalRequired] = useState(false);
  const [confirmingRules, setConfirmingRules] = useState(false), [clearing, setClearing] = useState(false);
  const [progress, setProgress] = useState({done: 0, total: 0});
  const [pickerKey, setPickerKey] = useState(0);
  const alive = useRef(true), locked = useRef(false), published = useRef(false), session = useRef(captureAuthSession());
  const abort = useRef<AbortController | null>(null), formRef = useRef<HTMLFormElement>(null);
  const current = () => alive.current && session.current();
  const sections = useApi(market ? null : '/api/water/sections');
  const available = rows(sections.data, 'sections').filter(section => section.status === undefined || section.status === 'active');
  const selected = available.find(section => section.slug === draft.postType);
  const selectedType = market ? marketTypes.find(([value]) => value === draft.postType)?.[1] : selected?.title || selected?.name;
  const busy = phase !== 'editing';
  const dirty = draft.files.length > 0 || draft.imagesChanged || draft.uncertain || ['title', 'content', 'price', 'contact', 'contactType'].some(field => draft[field as keyof PostDraft] !== base.current[field as keyof PostDraft]) || Boolean(post && draft.postType !== base.current.postType);
  const ready = market || (!sections.isPending && !sections.error && Boolean(selected));

  useEffect(() => {formRef.current?.querySelector<HTMLElement>('[data-autofocus]')?.focus({preventScroll: true});}, []);
  useLayoutEffect(() => {
    const field = formRef.current?.querySelector<HTMLTextAreaElement>('textarea[name="content"]');
    if (!field || preview) return;
    const resize = () => {field.style.height = 'auto'; field.style.height = `${field.scrollHeight}px`;};
    resize(); window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, [draft.content, preview]);

  useEffect(() => {
    if (!market && !draft.postType && available.length) {
      const preferred = available.find(section => section.slug === 'campus_life') || available[0];
      setDraft(value => ({...value, postType: preferred.slug}));
    }
  }, [market, draft.postType, sections.data]);
  useEffect(() => {
    if (!current() || published.current) return;
    if (dirty) savePostDraft(key, draft); else removePostDraft(key);
  }, [key, draft, dirty]);
  useEffect(() => {
    alive.current = true;
    return () => {alive.current = false; abort.current?.abort(); if (!session.current()) removePostDraft(key);};
  }, [key]);
  useEffect(() => {
    if (!dirty) return;
    const leave = (event: BeforeUnloadEvent) => {event.preventDefault(); event.returnValue = '';};
    window.addEventListener('beforeunload', leave);
    return () => window.removeEventListener('beforeunload', leave);
  }, [dirty]);
  useEffect(() => {
    if (!error && !rulesRequired && !legalRequired && !draft.uncertain) return;
    const feedback = formRef.current?.querySelector<HTMLElement>('.post-composer-warning, .post-composer-error, .post-composer-legal');
    feedback?.scrollIntoView({block: 'nearest'});
    feedback?.focus({preventScroll: true});
  }, [error, rulesRequired, legalRequired, draft.uncertain]);
  useDialogCloseGuard(() => {
    if (phase === 'posting') {ui.notify('正在确认发布结果，请稍候再关闭。'); return false;}
    return true;
  });
  function requestBack() {
    if (phase === 'posting') {ui.notify('正在确认发布结果，请稍候再返回。'); return;}
    abort.current?.abort();
    if (dirty && session.current()) {
      savePostDraft(key, draft);
      ui.notify(phase === 'uploading' ? '已停止上传，重新进入发帖页可继续。' : '草稿已暂存，重新进入发帖页可继续。刷新页面后清除。');
    }
    onBack();
  }
  function update<K extends keyof PostDraft>(field: K, value: PostDraft[K]) {
    setDraft(previous => ({...previous, [field]: value}));
    setClearing(false);
  }
  function showMyPosts() {
    ui.close();
    nav(`${market ? '/market' : '/community'}?sort=mine`);
  }
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (locked.current || !current() || !ready || draft.uncertain || rulesRequired || legalRequired) return;
    if (!draft.content.trim()) {setError('请先写一点内容，不能只填写空格。'); return;}
    if (length(draft.title.trim()) > 120 || length(draft.content.trim()) > 10000) {setError('标题最多 120 字，正文最多 10000 字，请精简后再发布。'); return;}
    if (market && (!draft.title.trim() || !draft.contact.trim())) {setError('请填写物品名称和联系方式。'); return;}
    if (market && !['lost', 'found', 'exposure'].includes(draft.postType) && (draft.price === '' || !Number.isFinite(Number(draft.price)) || Number(draft.price) < 0)) {setError('请填写有效的价格或预算，免费可填写 0。'); return;}
    if (market && draft.postType !== 'exposure' && !draft.existing.length && !draft.files.length) {setError('请至少添加一张图片，方便同学了解物品或需求。'); return;}
    const retained = draft.existing.map(fileID);
    if ((draft.files.length || draft.imagesChanged) && retained.some(id => !Number.isInteger(id) || id <= 0)) {setError('原图片信息不完整，请重新打开帖子后再编辑图片。正文和新图片已保留。'); return;}
    locked.current = true; setError('');
    const controller = new AbortController(); abort.current = controller;
    let sent = false;
    try {
      setPhase(draft.files.length ? 'uploading' : 'posting');
      const files = new FormData(); draft.files.forEach(file => files.append('images', file));
      const uploaded = await uploadIDs(files, undefined, {signal: controller.signal, onProgress: (done, total) => {if (current()) setProgress({done, total});}});
      if (!current() || controller.signal.aborted) return;
      const body = new FormData();
      body.set('title', draft.title.trim()); body.set('content', draft.content.trim()); body.set('board_id', market ? '2' : '1'); body.set('post_type', draft.postType);
      if (market) {body.set('price', draft.price || '0'); body.set('contact_type', draft.contactType); body.set('contact', draft.contact.trim());}
      // 编辑时只有图片发生变化才替换关联，新增图片必须与保留的原图一起提交。
      if (!post || draft.imagesChanged || uploaded.length) body.set('file_ids', JSON.stringify([...retained, ...uploaded]));
      setPhase('posting'); sent = true;
      // 页面后退或导航会中止本页等待，但业务请求可能已经成功，重开时先核对。
      savePostDraft(key, {...draft, uncertain: true});
      const result = await request(post ? `/api/posts/${post.id}` : '/api/posts', {method: post ? 'PUT' : 'POST', body, signal: AbortSignal.any([controller.signal, AbortSignal.timeout(45000)])});
      if (!current()) return;
      const id = Number(post?.id || result.post?.id || result.id);
      if (!Number.isInteger(id) || id <= 0) {setDraft(value => ({...value, uncertain: true})); setError('服务器已接收内容，但没有返回帖子编号。请先到“我的发布”核对，避免重复发布。'); return;}
      published.current = true; removePostDraft(key);
      void qc.invalidateQueries({queryKey: ['api']});
      ui.close(); ui.notify(post ? '修改已保存' : ['pending', 'pending_review'].includes(result.post?.status || result.status) ? '已提交，等待审核' : '发布成功');
      nav(`/post/${id}`, {replace: true, state: {from: origin.startsWith('/post/') ? market ? '/market' : '/community' : origin}});
    } catch (failure) {
      if (!current() || controller.signal.aborted) return;
      setError(errorText(failure));
      if (failure instanceof ApiError && failure.code === 'community_rules_required') setRulesRequired(true);
      else if (failure instanceof ApiError && failure.code === 'legal_consent_required') setLegalRequired(true);
      else if (sent && (!(failure instanceof ApiError) || failure.status >= 500)) setDraft(value => ({...value, uncertain: true}));
      if (sent && failure instanceof ApiError && failure.status < 500) setDraft(value => ({...value, uncertain: false}));
    } finally {
      locked.current = false;
      if (current()) {setPhase('editing'); abort.current = null;}
    }
  }

  if (auth.loading) return <p role="status">正在读取账号…</p>;
  if (!auth.user) return <Empty title="登录后发布内容"><button className="btn primary" onClick={auth.login}>登录</button></Empty>;
  return <form className="post-composer" data-keyboard-focus={keyboardFocus} noValidate ref={formRef} onSubmit={submit} onPointerDownCapture={() => setKeyboardFocus(false)} onKeyDownCapture={event => {if (event.key === 'Tab') setKeyboardFocus(true);}} onKeyDown={event => {
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter' && !event.nativeEvent.isComposing) {event.preventDefault(); if (!busy) formRef.current?.requestSubmit();}
  }}>
    <header className="post-editor-heading"><button className="icon-btn post-editor-back" type="button" aria-label="返回上一页" onClick={requestBack}><Icon name="arrow" size={19}/></button><div className="post-editor-title"><h1>{post ? '编辑帖子' : market ? '发布闲置' : '发布帖子'}</h1><p>{post ? '整理内容，继续和同学交流' : market ? '让闲置找到需要它的同学' : '分享校园里值得记录的小事'}</p></div>
      <div className="post-composer-switch" role="group" aria-label="编辑与预览"><button type="button" aria-pressed={!preview} disabled={busy} onClick={() => setPreview(false)}><Icon name="file" size={15}/>编辑</button><button type="button" aria-pressed={preview} disabled={busy} onClick={() => setPreview(true)}><Icon name="eye" size={16}/>预览</button></div>
    </header>
    <div className="post-composer-scroll">
      <div className="post-composer-sheet">
      <div className="post-composer-top">
        <div className="post-composer-author"><span><ServerAvatar src={auth.user.avatar} name={auth.user.nickname}/></span><div><b>{auth.user.nickname}</b><small>{post ? '编辑已发布内容' : '发布新内容'}</small></div></div>
        <label className="post-composer-destination"><span>{market ? '发布类型' : '分区'}</span><select name="post_type" aria-label={market ? '发布类型' : '分区'} value={draft.postType} disabled={busy || (!market && (sections.isPending || !!sections.error || !available.length))} onChange={event => update('postType', event.target.value)}>
          {market ? <>{post?.post_type === 'exposure' && <option value="exposure">曝光</option>}{marketTypes.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</> : <><option value="" disabled>{sections.isPending ? '正在加载分区…' : '请选择分区'}</option>{draft.postType && !selected && <option value={draft.postType} disabled>原分区不可用，请重新选择</option>}{available.map(section => <option key={section.slug} value={section.slug}>{section.title || section.name}</option>)}</>}
        </select></label>
      </div>
      {!market && (sections.error || (!sections.isPending && !available.length)) && <div className="post-composer-section-error"><p role="alert">{sections.error ? errorText(sections.error) : '暂无可用分区'}</p><button className="link-btn" type="button" onClick={() => void sections.refetch()}>重新加载分区</button></div>}
      {!market && selected?.description && <p className="post-section-description">{selected.description}</p>}
      <div className="post-composer-layout" hidden={preview}>
        <fieldset className="post-composer-editor" disabled={busy}>
          <label className="post-composer-title"><span className="sr-only">{market ? '物品名称' : '标题'}</span><input name="title" data-autofocus={market ? true : undefined} aria-label={market ? '物品名称' : '标题'} value={draft.title} maxLength={240} placeholder={market ? '给物品起个清楚的名字' : '添加一个标题（选填）'} required={market} onChange={event => update('title', event.target.value)}/></label>
          <label className="post-composer-content"><span className="sr-only">内容</span><textarea name="content" aria-label="内容" data-autofocus={market ? undefined : true} value={draft.content} maxLength={20000} required placeholder={market ? '介绍成色、使用情况、交易地点，或写清你的需求…' : '最近有什么新鲜事？\n分享一个想法、一段经历，或向同学们提个问题…'} onChange={event => update('content', event.target.value)}/></label>
          <div className="post-composer-count"><span>{length(draft.title) > 120 ? '标题超出 120 字' : '支持换行与粘贴图片'}</span><span className={length(draft.content) > 10000 ? 'field-error' : ''}>{length(draft.content)} / 10000</span></div>
          <section className="post-composer-media" aria-label="帖子图片">{draft.existing.length + draft.files.length > 0 && <div className="section-head"><b>图片 <span>{draft.existing.length + draft.files.length} / 9</span></b><small>按显示顺序发布</small></div>}
            {draft.existing.length > 0 && <div className="post-existing-grid">{draft.existing.map((item, index) => <div className="post-existing-image" key={item.id || index}><ExistingImage image={item} index={index}/><button className="icon-btn" disabled={busy} type="button" aria-label={`移除已发布图片${index + 1}`} onClick={() => setDraft(value => ({...value, imagesChanged: true, existing: value.existing.filter((_, i) => i !== index)}))}><Icon name="close" size={16}/></button><small>已发布 · {index + 1}</small></div>)}</div>}
            <MediaUploadPicker compact key={pickerKey} initialFiles={draft.files} disabled={busy} maxCount={9 - draft.existing.length} onFilesChange={files => update('files', files)}/>
          </section>
        </fieldset>
        {market && <fieldset className="post-composer-settings" disabled={busy}><legend>交易信息</legend>
          <label className="field">价格或预算<input name="price" aria-label="价格或预算" type="number" min="0" step="0.01" value={draft.price} placeholder="免费可填 0" onChange={event => update('price', event.target.value)}/></label><label className="field">联系方式类型<select name="contact_type" value={draft.contactType} onChange={event => update('contactType', event.target.value)}>{[['wechat', '微信'], ['qq', 'QQ'], ['phone', '电话']].map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label><label className="field">联系方式<input name="contact" value={draft.contact} required maxLength={100} placeholder="填写可用于联系你的方式" onChange={event => update('contact', event.target.value)}/></label>
        </fieldset>}
      </div>
      {preview && <PostPreview draft={draft} nickname={auth.user.nickname} avatar={auth.user.avatar} section={selectedType} market={market}/>}
      {draft.uncertain && <section className="post-composer-warning" role="alert" tabIndex={-1}><h3>发布结果尚未确认</h3><p>{error || '请先检查“我的发布”，确认没有重复内容后再继续提交。'}</p><div><button className="btn" type="button" onClick={showMyPosts}>查看我的发布</button><button className="link-btn" type="button" onClick={() => {update('uncertain', false); setError('');}}>已核对，继续编辑</button></div></section>}
      {!draft.uncertain && error && <p className="field-error post-composer-error" role="alert" tabIndex={-1}>{error}</p>}
      {rulesRequired && <section className="post-composer-warning" aria-label="确认社区规则" tabIndex={-1}><h3>请先阅读社区规则</h3><p>不得发布违法违规、侵犯隐私、侮辱诽谤、诈骗或违禁交易内容。分享他人信息、图片或资料前，应取得合法授权。</p><button className="btn" type="button" disabled={confirmingRules} onClick={async () => {
        setConfirmingRules(true);
        try {await write('/api/user/community-rules', {accepted: true}); if (current()) {setRulesRequired(false); setError('规则已确认，请重新提交当前内容。');}}
        catch (failure) {if (current()) setError(errorText(failure));}
        finally {if (current()) setConfirmingRules(false);}
      }}>{confirmingRules ? '正在确认…' : '我已阅读并同意社区规则'}</button></section>}
      {legalRequired && <div className="post-composer-legal" tabIndex={-1}><LegalConfirmation onAccepted={() => {setLegalRequired(false); setError('协议已确认，请重新提交当前内容。');}}/></div>}
      </div>
      <details className="post-publishing-notes"><summary>发布须知</summary><div className="post-composer-tip"><Icon name="info" size={15}/><p>友善交流，尊重隐私。分享他人的照片或信息前，请先取得同意。</p></div></details>
    </div>
    <footer className="post-composer-footer">
      {clearing ? <div className="post-composer-clear" role="alert"><span>清空当前草稿？</span><button className="link-btn" type="button" onClick={() => {setDraft(base.current); setPickerKey(value => value + 1); setError(''); setClearing(false); removePostDraft(key);}}>确认清空</button><button className="link-btn" type="button" onClick={() => setClearing(false)}>取消</button></div> : <div className="post-composer-save-state"><span className="post-composer-status" role="status"><Icon name={busy ? 'clock' : dirty ? 'check' : 'file'} size={15}/>{phase === 'uploading' ? `正在上传图片（${progress.done}/${progress.total}）…` : phase === 'posting' ? '正在确认发布结果…' : dirty ? '草稿已在本页暂存' : '准备好后，分享给同学'}</span><small>当前标签页暂存 · 刷新或切号后清除</small></div>}
      <div className="post-composer-actions"><button className="link-btn post-clear-button" type="button" disabled={busy || !dirty || draft.uncertain} onClick={() => setClearing(true)}>清空</button><button className="btn" type="button" disabled={phase === 'posting'} onClick={requestBack}>{phase === 'uploading' ? '停止上传并返回' : '暂存并返回'}</button><button className="btn primary" type="submit" disabled={busy || !ready || draft.uncertain || rulesRequired || legalRequired || confirmingRules} aria-busy={busy}>{busy ? phase === 'uploading' ? '正在上传…' : '正在发布…' : draft.uncertain ? '待核对结果' : post ? '保存修改' : error ? '重新发布' : '发布'}</button></div>
    </footer>
  </form>;
}

function ExistingImage({image, index}: {image: MediaItem; index: number}) {
  const [failed, setFailed] = useState(false);
  return failed ? <div className="post-image-error"><span>原图暂不可用</span><button type="button" className="link-btn" onClick={() => setFailed(false)}>重试</button></div> : <img src={mediaURL(image, 'thumb') || mediaURL(image, 'origin')} alt={`已发布图片${index + 1}`} onError={() => setFailed(true)}/>;
}
function PostPreview({draft, nickname, avatar, section, market}: {draft: PostDraft; nickname: string; avatar?: string; section?: string; market: boolean}) {
  const [urls, setURLs] = useState<string[]>([]);
  useEffect(() => {const value = draft.files.map(file => URL.createObjectURL(file)); setURLs(value); return () => value.forEach(url => URL.revokeObjectURL(url));}, [draft.files]);
  return <section className="post-composer-preview" role="region" aria-label="帖子预览"><div className="post-preview-note"><Icon name="eye" size={17}/>发布前预览 · 实际展示以发布后的帖子为准</div><article><div className="post-composer-author"><span><ServerAvatar src={avatar} name={nickname}/></span><div><b>{nickname}</b><small>{section || '待选择分区'} · 即将发布</small></div></div>{draft.title && <h2>{draft.title}</h2>}<p className="post-preview-content">{draft.content || '在编辑页写下想分享的内容…'}</p>{market && draft.price !== '' && <p className="post-preview-price">¥ {draft.price}</p>}<div className="post-preview-images">{[...draft.existing.map(item => mediaURL(item, 'origin')), ...urls].filter(Boolean).map((url, index) => <img key={`${url}:${index}`} src={url} alt={`待发布图片${index + 1}`}/>)}</div></article></section>;
}

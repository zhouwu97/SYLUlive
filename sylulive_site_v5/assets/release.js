/* Download presentation follows the existing stable-release API contract. */
(() => {
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname) || location.protocol === 'file:';
  const api = '/api/app/update?platform=android&channel=stable&version_name=0.0.0&version_code=1';
  const ids = ['versionName', 'fileSize', 'publishedAt', 'changelog', 'downloadBtn', 'downloadText', 'downloadHint', 'shaText', 'retryBtn', 'releaseState', 'releaseCard'];
  const el = Object.fromEntries(ids.map(id => [id, document.getElementById(id)]));
  if (!el.releaseCard) return;
  let targetUrl = '', generation = 0, pending;
  const safeUrl = raw => {
    if (typeof raw !== 'string' || !raw.trim()) return '';
    try {
      const url = new URL(raw, 'https://sylulive.online');
      return url.protocol === 'https:' && !url.username && !url.password ? url.href : '';
    } catch { return ''; }
  };
  function bytes(raw) {
    let n = Number(raw), i = 0;
    if (!Number.isFinite(n) || n <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    while (n >= 1024 && i < 3) { n /= 1024; i++; }
    return `${n >= 100 ? n.toFixed(0) : n.toFixed(1)} ${units[i]}`;
  }
  function date(raw) {
    const value = raw ? new Date(raw) : null;
    return value && !Number.isNaN(value.getTime()) ? new Intl.DateTimeFormat('zh-CN', {year:'numeric',month:'2-digit',day:'2-digit',timeZone:'Asia/Shanghai'}).format(value) : '—';
  }
  function unavailable(empty = false) {
    targetUrl = '';
    el.downloadBtn.disabled = true;
    el.downloadText.textContent = empty ? '暂无可下载版本' : '暂时无法下载';
    el.versionName.textContent = local ? '待连接' : empty ? '尚未发布' : '获取失败';
    if (local) el.downloadText.textContent = '本地预览暂不下载';
    el.releaseState.textContent = empty ? '待发布' : local ? '本地预览' : '连接失败';
    el.downloadHint.classList.toggle('error', !empty && !local);
    el.downloadHint.textContent = local ? '本地预览不连接线上版本服务。部署后会自动读取当前稳定版。' : empty ? '当前还没有可用的稳定版安装包，可稍后重新获取。' : '版本信息获取失败，请检查网络后重试，或查看 GitHub 发布页。';
    el.changelog.textContent = empty ? '稳定版发布后，这里会显示版本与更新说明。' : local ? '在官网线上环境中可查看真实版本、更新说明和安装包信息。' : '暂时无法读取更新说明。';
    el.retryBtn.hidden = local;
  }
  async function loadRelease() {
    const current = ++generation;
    pending?.abort();
    targetUrl = '';
    el.downloadBtn.disabled = true;
    el.downloadText.textContent = '正在获取版本…';
    el.retryBtn.hidden = true;
    el.releaseCard.setAttribute('aria-busy', 'true');
    el.releaseState.textContent = '正在获取';
    el.versionName.textContent = '正在获取…';
    el.fileSize.textContent = el.publishedAt.textContent = '—';
    el.shaText.textContent = '版本加载后显示安装包的 SHA-256 校验值。';
    el.downloadHint.classList.remove('error');
    el.downloadHint.textContent = '正在读取 Android 稳定版，请稍候。';
    if (local) { unavailable(); el.releaseCard.setAttribute('aria-busy', 'false'); return; }
    const controller = new AbortController(); pending = controller;
    const timer = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(api, {headers:{Accept:'application/json'},cache:'no-store',signal:controller.signal});
      if (!response.ok) throw new Error('release request failed');
      const data = await response.json();
      if (current !== generation) return;
      if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('invalid release');
      if (!data.latest_version_name && data.update_available === false) { unavailable(true); return; }
      const market = data.delivery_mode === 'external_market';
      targetUrl = safeUrl(market ? data.action_url : data.download_url);
      if (!targetUrl) throw new Error('unavailable download');
      el.versionName.textContent = typeof data.latest_version_name === 'string' && data.latest_version_name.trim() ? `v${data.latest_version_name.replace(/^v/i, '')}` : '当前稳定版';
      el.fileSize.textContent = bytes(data.file_size);
      el.publishedAt.textContent = date(data.published_at);
      el.changelog.textContent = typeof data.changelog === 'string' && data.changelog.trim() ? data.changelog.trim() : '当前稳定版已发布，具体更新以应用内说明为准。';
      el.shaText.textContent = typeof data.sha256 === 'string' && /^[a-f0-9]{64}$/i.test(data.sha256) ? data.sha256 : market ? '当前由应用市场分发，完整性信息以应用市场为准。' : '当前版本未提供校验值。';
      el.releaseState.textContent = '已就绪';
      el.downloadText.textContent = market ? '前往应用市场' : '下载 Android APK';
      el.downloadHint.textContent = market ? '将打开当前稳定版指定的应用市场页面。' : '点击后开始获取当前稳定版安装包。';
      el.downloadBtn.disabled = false;
    } catch { if (current === generation) unavailable(); }
    finally {
      clearTimeout(timer);
      if (current === generation) { pending = null; el.releaseCard.setAttribute('aria-busy', 'false'); }
    }
  }
  el.retryBtn.addEventListener('click', loadRelease);
  el.downloadBtn.addEventListener('click', () => { if (targetUrl) location.assign(targetUrl); });
  loadRelease();
})();

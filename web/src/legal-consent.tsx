import {useEffect, useRef, useState} from 'react';
import {useQueryClient} from '@tanstack/react-query';
import {ApiError, captureAuthSession, errorText, write} from './api';

export function LegalConfirmation({onAccepted}: {onAccepted?: () => void}) {
  const qc = useQueryClient();
  const session = useRef(captureAuthSession()), alive = useRef(true), locked = useRef(false);
  const [base, setBase] = useState(false), [edu, setEdu] = useState(false), [needsEdu, setNeedsEdu] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [accepted, setAccepted] = useState(false);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  async function confirm() {
    if (!base || (needsEdu && !edu) || locked.current) return;
    if (!session.current()) { setError('账号已切换，请重新打开本页核对协议'); return; }
    locked.current = true; setBusy(true); setError('');
    const current = () => alive.current && session.current();
    try {
      await write('/api/user/legal-consents', {user_agreement_accepted: true, privacy_policy_accepted: true, ...(needsEdu ? {edu_data_consent_accepted: edu} : {})});
      if (!current()) return;
      setAccepted(true);
      await qc.invalidateQueries({queryKey: ['api']});
      if (current()) onAccepted?.();
    } catch (failure) {
      if (!current()) return;
      if (failure instanceof ApiError && failure.code === 'edu_data_consent_required') setNeedsEdu(true);
      setError(errorText(failure));
    } finally {
      locked.current = false;
      if (current()) setBusy(false);
    }
  }
  if (accepted) return <p role="status">协议已确认，请重新提交刚才的操作。</p>;
  return <section className="panel panel-pad" aria-label="确认最新协议">
    <h3>请确认最新协议与隐私政策</h3>
    <p>阅读当前版本后主动勾选。确认协议不会自动重试之前的发布或其他写入。</p>
    <fieldset disabled={busy}>
      <label className="check-label"><input type="checkbox" checked={base} onChange={event => setBase(event.target.checked)}/>我已阅读并同意<a href="/terms" target="_blank" rel="noreferrer">用户协议</a>与<a href="/privacy" target="_blank" rel="noreferrer">隐私政策</a></label>
      {needsEdu && <label className="check-label"><input type="checkbox" checked={edu} onChange={event => setEdu(event.target.checked)}/>我已阅读并同意<a href="/privacy#edu-data-consent" target="_blank" rel="noreferrer">教务数据专项授权</a></label>}
      <button className="btn primary" type="button" disabled={!base || (needsEdu && !edu)} onClick={() => void confirm()}>{busy ? '正在确认…' : '确认协议'}</button>
    </fieldset>
    {error && <p className="field-error" role="alert">{error}</p>}
  </section>;
}

import { describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { createElement } from 'react';
import { AiBotIdentity } from './ai-bot-identity';
import type { Entity } from './api';

const renderIdentity = (user: Entity) => renderToStaticMarkup(createElement(AiBotIdentity, { user }));

describe('server supplied AI identity', () => {
  it('separates the system badge and public creator from the editable nickname', () => {
    const html = renderIdentity({ nickname: '小鱼', ai_bot: { owner_id: 7, owner_nickname: '校园创建者' } });
    expect(html).toContain('AI机器人');
    expect(html).toContain('由校园创建者创建');
    expect(html).toContain('ai-bot-system-badge');
    expect(html).not.toContain('小鱼');
  });

  it('does not grant a system badge from a nickname or unrelated owner field', () => {
    for (const user of [{ nickname: '[AI] 大肥鱼', owner_nickname: '创建者' }, { ai_bot: true }, { ai_bot: [] }, { ai_bot: null }]) {
      expect(renderIdentity(user)).toBe('');
    }
  });

  it('keeps the identity honest when a public creator name is unavailable', () => {
    expect(renderIdentity({ ai_bot: {} })).toContain('创建者未公开');
    expect(renderIdentity({ ai_bot: { owner_id: 7, owner_nickname: '  ' } })).toContain('由用户 #7 创建');
    expect(renderIdentity({ ai_bot: { owner_id: '7', owner_nickname: {} } })).toContain('创建者未公开');
  });

  it('retains escaped complete creator attribution for accessible reading', () => {
    const owner = '校园创建者'.repeat(20) + '<script>';
    const html = renderIdentity({ ai_bot: { owner_id: 7, owner_nickname: owner } });
    expect(html).toContain('系统AI机器人');
    expect(html).toContain('&lt;script&gt;');
    expect(html).not.toContain('<script>');
  });
});

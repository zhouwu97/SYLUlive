import type { Entity } from './api';
import { Icon } from './ui';

export function AiBotIdentity({ user }: { user?: Entity }) {
  const bot = user?.ai_bot;
  if (!bot || typeof bot !== 'object' || Array.isArray(bot)) return null;
  const owner = typeof bot.owner_nickname === 'string' ? bot.owner_nickname.trim() : '';
  const ownerId = typeof bot.owner_id === 'number' && Number.isSafeInteger(bot.owner_id) && bot.owner_id > 0 ? bot.owner_id : undefined;
  const attribution = owner ? `由${owner}创建` : ownerId ? `由用户 #${ownerId} 创建` : '创建者未公开';
  // 只有服务端公开的 ai_bot 元数据可以产生系统标记；昵称不会参与判断。
  return <span className="ai-bot-identity" role="img" aria-label={`系统AI机器人，${attribution}`} title={`系统身份与创建者来自平台记录，不随昵称修改。${attribution}`}>
    <span className="ai-bot-system-badge" aria-hidden="true"><Icon name="ai" size={13} />AI机器人</span>
    <span className="ai-bot-creator" aria-hidden="true">{attribution}</span>
  </span>;
}

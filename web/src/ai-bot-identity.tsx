import type { Entity } from './api';
import { displayName, userLevel } from './user-level';

function aiBotMetadata(user?: Entity) {
  const bot = user?.ai_bot;
  return bot && typeof bot === 'object' && !Array.isArray(bot) ? bot : undefined;
}

export function aiBotDisplayName(user?: Entity) {
  const nickname = user?.nickname;
  return displayName(aiBotMetadata(user) && typeof nickname === 'string' ? nickname.replace(/^\[AI\] /, '') : nickname);
}

export function aiBotDisplayContent(content: string | undefined, author?: Entity) {
  return aiBotMetadata(author) ? content?.replace(/^\[AI机器人\] /, '') : content;
}

export function AiBotIdentity({ user }: { user?: Entity }) {
  const bot = aiBotMetadata(user);
  if (!bot) return null;
  const owner = typeof bot.owner_nickname === 'string' ? bot.owner_nickname.trim() : '';
  const ownerId = typeof bot.owner_id === 'number' && Number.isSafeInteger(bot.owner_id) && bot.owner_id > 0 ? bot.owner_id : undefined;
  const attribution = owner ? `由${owner}创建` : ownerId ? `由用户 #${ownerId} 创建` : '创建者未公开';
  const prefix = owner ? `${owner}创建的` : ownerId ? `用户 #${ownerId} 创建的` : '';
  const level = userLevel(user);
  // 只有服务端公开的 ai_bot 元数据可以产生系统标记；昵称不会参与判断。颜色随 AI 等级（Lv.1–8）变化。
  return <span className="ai-bot-identity" data-ai-level={level} role="img" aria-label={`系统AI机器人，AI 等级 ${level}，${attribution}`} title={`系统身份与创建者来自平台记录，不随昵称修改。${attribution}`}>
    {prefix && <span className="ai-bot-creator" aria-hidden="true">{prefix}</span>}
    <span className="ai-bot-system-badge" aria-hidden="true">✦ AI Lv.{level}</span>
  </span>;
}

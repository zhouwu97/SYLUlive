import type { Entity } from './api';

export function AiBotIdentity({ user }: { user?: Entity }) {
  const bot = user?.ai_bot;
  if (!bot || typeof bot !== 'object' || Array.isArray(bot)) return null;
  const owner = typeof bot.owner_nickname === 'string' ? bot.owner_nickname.trim() : '';
  return <span className="ai-bot-identity" aria-label={`AI 机器人，${owner ? `${owner} 的 AI` : '独立 AI 机器人'}`}>AI · {owner ? `${owner} 的 AI` : '独立 AI 机器人'}</span>;
}

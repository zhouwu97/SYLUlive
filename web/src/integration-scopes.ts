// 连接卡片使用简短名称，授权边界仍由确认页的详细说明和服务端决定。
export const integrationScopeTitles: Record<string, string> = {
  'profile:read_minimal': '账号编号与昵称',
  'community:read': '公开社区浏览',
  'content:read_own_public': '本人公开帖子',
  'actions:read_own': '草稿与发布结果',
  'community:propose': '创建待确认草稿',
  'community:bot_reply': '机器人自动评论',
  'community:bot_post': '机器人自动发帖',
  'academic:grades:read': '本人已同步成绩',
  'academic:erke:read': '本人已同步二课摘要',
  'checkin:write': '本人签到',
};

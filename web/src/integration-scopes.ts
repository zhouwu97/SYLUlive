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

// 管理中心逐条展示授权边界，使用完整说明；连接卡片仍用上面的简短名称。
export const integrationScopeLabels: Record<string, string> = {
  'profile:read_minimal': '账号编号与昵称',
  'community:read': '公开帖子与评论、作者昵称、互动统计、公开图片和表情目录',
  'content:read_own_public': '本人公开帖子',
  'actions:read_own': '本授权创建的草稿与发布结果',
  'community:propose': '创建待本人确认的帖子或评论草稿',
  'community:bot_reply': '允许独立 AI 机器人自主评论',
  'community:bot_post': '允许独立 AI 机器人自主发帖',
  'checkin:write': '查看本人签到状态，并按本人指令每日签到（不含补签）',
  'academic:grades:read': '本账号已同步成绩（本人查询，非学校实时查询）',
  'academic:erke:read': '本账号已同步二课摘要（本人查询）',
};

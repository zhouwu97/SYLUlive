import 'package:flutter/material.dart';

class WaterPostCategory {
  final String value;
  final String label;
  final String hint;
  final String actionHint;
  final String emptyTitle;
  final String emptyDescription;
  final IconData icon;
  final Color color;

  const WaterPostCategory({
    required this.value,
    required this.label,
    required this.hint,
    required this.actionHint,
    required this.emptyTitle,
    required this.emptyDescription,
    required this.icon,
    required this.color,
  });
}

const List<WaterPostCategory> kWaterPostCategories = [
  WaterPostCategory(
    value: 'freshman_help',
    label: '新生求助',
    hint: '新生群、宿舍、入学流程、校园问题',
    actionHint: '有问题可以直接问，学长学姐更容易看见',
    emptyTitle: '还没有「新生求助」相关帖子',
    emptyDescription: '可以提问新生群、宿舍、入学流程、校园卡、军训等问题。',
    icon: Icons.school_outlined,
    color: Color(0xFF2F80ED),
  ),
  WaterPostCategory(
    value: 'course_study',
    label: '课程学习',
    hint: '课程、考试、选课、老师、学习资料',
    actionHint: '分享课程经验，让后来的人少踩坑',
    emptyTitle: '还没有「课程学习」相关帖子',
    emptyDescription: '可以分享课程评价、考试经验、选课建议或学习资料线索。',
    icon: Icons.menu_book_outlined,
    color: Color(0xFF27AE60),
  ),
  WaterPostCategory(
    value: 'competition',
    label: '比赛竞赛',
    hint: '竞赛通知、经验、组队、避坑',
    actionHint: '分享信息，帮更多人看见机会',
    emptyTitle: '还没有「比赛竞赛」相关帖子',
    emptyDescription: '可以发布竞赛通知、组队信息、经验总结或避坑提醒。',
    icon: Icons.emoji_events_outlined,
    color: Color(0xFFF2994A),
  ),
  WaterPostCategory(
    value: 'campus_life',
    label: '校园生活',
    hint: '日常、宿舍、食堂、校园见闻',
    actionHint: '记录校园日常，也可以分享身边新鲜事',
    emptyTitle: '还没有「校园生活」相关帖子',
    emptyDescription: '可以分享校园日常、宿舍生活、食堂体验或身边见闻。',
    icon: Icons.local_florist_outlined,
    color: Color(0xFF00A6A6),
  ),
  WaterPostCategory(
    value: 'complaint',
    label: '吐槽树洞',
    hint: '吐槽、情绪、校园日常倾诉',
    actionHint: '可以表达感受，但请勿挂人、曝光隐私或攻击他人',
    emptyTitle: '还没有「吐槽树洞」相关帖子',
    emptyDescription: '可以聊聊校园日常和情绪感受，请注意不要发布挂人、隐私曝光或攻击性内容。',
    icon: Icons.chat_bubble_outline,
    color: Color(0xFF9B51E0),
  ),
  WaterPostCategory(
    value: 'experience',
    label: '经验分享',
    hint: '攻略、总结、避坑、长期有用内容',
    actionHint: '把有用经验沉淀下来，方便更多同学参考',
    emptyTitle: '还没有「经验分享」相关帖子',
    emptyDescription: '可以发布攻略、避坑总结、流程说明或长期有用的信息。',
    icon: Icons.lightbulb_outline,
    color: Color(0xFFEB5757),
  ),
  WaterPostCategory(
    value: 'campus_news',
    label: '校园消息',
    hint: '校内安排、通知讨论、身边消息',
    actionHint: '分享你看到的校园消息，方便大家及时了解',
    emptyTitle: '还没有「校园消息」相关帖子',
    emptyDescription: '可以讨论校内安排、活动通知、楼宇变化或身边消息。',
    icon: Icons.campaign_outlined,
    color: Color(0xFF56CCF2),
  ),
];

WaterPostCategory? waterCategoryOf(String? value) {
  if (value == null || value.isEmpty) return null;
  for (final item in kWaterPostCategories) {
    if (item.value == value) return item;
  }
  return null;
}

String waterCategoryLabelOf(String? value) {
  return waterCategoryOf(value)?.label ?? '校园生活';
}

bool isValidWaterPostCategory(String? value) {
  if (value == null || value.isEmpty) return false;
  return kWaterPostCategories.any((item) => item.value == value);
}

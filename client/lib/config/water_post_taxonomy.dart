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
    label: '避雷专区',
    hint: '校园避坑、风险提醒、真实体验反馈',
    actionHint: '分享避坑提醒时请描述事实，避免挂人、造谣或曝光隐私',
    emptyTitle: '还没有「避雷专区」相关帖子',
    emptyDescription: '可以发布校园避坑、消费提醒、流程坑点或真实体验反馈，请注意避免挂人和隐私曝光。',
    icon: Icons.report_problem_outlined,
    color: Color(0xFFEF4444),
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

extension WaterPostCategoryUiCopy on WaterPostCategory {
  List<String> get quickTags {
    switch (value) {
      case 'freshman_help':
        return ['宿舍', '报到流程', '军训', '校园卡', '新生群'];
      case 'course_study':
        return ['选课', '考试', '老师', '学习资料', '绩点'];
      case 'competition':
        return ['组队', '通知', '经验', '避坑', '获奖'];
      case 'campus_life':
        return ['食堂', '宿舍', '日常', '校园卡', '随手拍'];
      case 'complaint':
        return ['吐槽', '情绪', '树洞', '避雷', '建议'];
      case 'experience':
        return ['攻略', '总结', '流程', '避坑', '长期有用'];
      case 'campus_news':
        return ['风险提醒', '消费避坑', '流程坑点', '真实反馈'];
      default:
        return ['提问', '经验', '求助', '交流'];
    }
  }

  List<String> get starterQuestions {
    switch (value) {
      case 'freshman_help':
        return ['宿舍怎么分？', '新生群在哪？', '军训要带什么？', '校园卡怎么用？', '报到流程是什么？'];
      case 'course_study':
        return ['这门课难不难？', '老师给分怎么样？', '考试怎么复习？', '选课有什么建议？', '学习资料去哪找？'];
      case 'competition':
        return ['这个比赛值不值得报？', '怎么找队友？', '往年难度怎么样？', '学校认不认？', '需要准备什么？'];
      case 'campus_life':
        return ['食堂哪家好吃？', '宿舍生活怎么样？', '校园卡怎么补办？', '学校附近有什么推荐？'];
      case 'complaint':
        return ['想吐槽一件事', '有没有人也遇到过？', '这件事合理吗？', '该怎么处理比较好？'];
      case 'experience':
        return ['流程攻略', '避坑总结', '工具推荐', '办事经验', '长期有用的信息'];
      case 'campus_news':
        return ['消费避坑', '校园风险提醒', '流程坑点', '真实体验反馈'];
      default:
        return ['提一个问题', '分享经验', '求助同学', '补充信息'];
    }
  }

  String get publishActionText {
    switch (value) {
      case 'freshman_help':
      case 'course_study':
        return '提一个问题';
      case 'competition':
        return '发布信息';
      case 'complaint':
        return '说说看';
      case 'experience':
        return '分享经验';
      case 'campus_news':
        return '发布提醒';
      default:
        return '发布帖子';
    }
  }

  String get emptyLeadText {
    switch (value) {
      case 'freshman_help':
        return '还没人提问，先把新生最关心的问题问出来。';
      case 'course_study':
        return '还没有课程经验，可以先分享选课、考试或老师评价。';
      case 'competition':
        return '还没有竞赛信息，可以发布通知、组队或经验总结。';
      case 'campus_life':
        return '还没有校园生活内容，可以分享日常、食堂、宿舍或校园见闻。';
      case 'complaint':
        return '还没有树洞内容，可以聊聊校园日常和情绪感受。';
      case 'experience':
        return '还没有经验沉淀，可以发布攻略、流程或避坑总结。';
      case 'campus_news':
        return '还没有避雷内容，可以发布风险提醒或真实体验反馈。';
      default:
        return emptyDescription;
    }
  }
}

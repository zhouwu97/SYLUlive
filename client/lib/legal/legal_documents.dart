class LegalDocument {
  final String id;
  final String title;
  final String summary;
  final String body;
  final bool requiredForRegistration;
  final bool eduOnly;

  const LegalDocument({
    required this.id,
    required this.title,
    required this.summary,
    required this.body,
    this.requiredForRegistration = true,
    this.eduOnly = false,
  });
}

/// 法律文档版本必须和服务端 models.LegalDocumentVersion 同步更新。
class LegalDocuments {
  static const version = '2026-07-18';

  static const userAgreement = LegalDocument(
    id: 'user_agreement',
    title: '用户协议',
    summary: '账号、服务范围、行为规范与账号注销规则',
    body: '''
版本：2026-07-18

一、服务说明
本服务提供校园信息、社区互动、课程与其他校园工具。请在合法、善意且不侵害他人权益的前提下使用。

二、账号与内容
请妥善保管账号。不得冒用他人身份、发布违法或侵权内容、实施欺诈、骚扰、恶意营销或绕过安全机制。你应对自行发布的内容负责。

三、账号注销
你可以在“隐私与数据权利”中使用密码确认注销账号。注销后，身份资料、教务凭证和设备推送标识会被清除或匿名化；为履行内容治理、投诉处理和法定义务，内容关联与必要审计记录可能在法定期限内保留。

四、联系我们
个人信息与账号相关请求可在“隐私与数据权利”中提交并查看处理状态。
''',
  );

  static const privacyPolicy = LegalDocument(
    id: 'privacy_policy',
    title: '隐私政策',
    summary: '个人信息处理目的、范围、保存与权利行使方式',
    body: '''
版本：2026-07-18

一、我们处理的信息
注册与使用服务时，可能处理学号或 QQ 号、昵称、头像、账号密码摘要、设备推送标识、你主动发布的内容和图片。使用教务功能时，还会按专项授权处理教务账号、认证凭证、课表、成绩、学籍相关信息。

二、处理目的与最小化
账号信息用于身份认证和服务提供；设备推送标识仅用于消息提醒；教务数据仅用于已启用的教务功能。密码、Cookie 和会话令牌不出现在个人数据导出文件中。

三、保存期限
账号信息保存至账号注销或实现服务目的所需的期限；安全日志和必要审计记录按适用法律留存。教务授权撤回或账号注销后，服务端将清除教务凭证和绑定状态。

四、你的权利
你可以在“隐私与数据权利”中提交查阅、更正、导出、删除或撤回同意请求，并查看处理状态；也可以直接导出账户资料和授权记录。

五、联系信息
个人信息保护请求可在“隐私与数据权利”中提交并查看处理状态。
''',
  );

  static const communityRules = LegalDocument(
    id: 'community_rules',
    title: '社区规则',
    summary: '内容发布、二手交易与互动行为要求',
    body: '''
版本：2026-07-18

不得发布违法违规、侵犯隐私、侮辱诽谤、诈骗、色情低俗、暴力恐怖、违禁交易或侵犯知识产权的内容。发布他人信息、照片、联系方式或试卷资料前，应取得合法授权。

二手交易仅用于信息交流。请自行核验交易对象与商品，不要在平台外泄露密码、验证码或支付凭证。平台可依据举报和审核规则处理违规内容，并向内容发布者说明处置理由和申诉渠道。
''',
  );

  static const minorProtection = LegalDocument(
    id: 'minor_protection',
    title: '未成年人保护规则',
    summary: '未成年人使用、内容与个人信息保护要求',
    body: '''
版本：2026-07-18

如你是未成年人，请在监护人同意和指导下使用服务。我们不以未成年人为对象开展不适当营销；发现可能危害未成年人身心健康或侵犯其个人信息的内容时，可采取限制展示、删除、账号限制等措施。

监护人可通过“隐私与数据权利”请求查询、删除或处理未成年人相关个人信息。
''',
  );

  static const contentComplaintRules = LegalDocument(
    id: 'content_complaint_rules',
    title: '投诉举报规则',
    summary: '举报入口、审核处理与申诉机制',
    body: '''
版本：2026-07-18

对帖子和评论可使用应用内举报入口提交理由。管理员会记录处理结论；必要时可删除或限制内容。内容被处置后，发布者可以通过应用内申诉流程请求复核。

涉及紧急违法风险、未成年人安全或个人信息泄露时，请通过应用内举报入口反馈。
''',
  );

  static const sdkDisclosure = LegalDocument(
    id: 'sdk_disclosure',
    title: '第三方服务说明',
    summary: '推送、图片选择、WebView 与可选 AI 服务的处理说明',
    body: '''
版本：2026-07-18

一、极光推送
用于向已登录用户发送回复、私信和系统通知。应用会在获得通知权限后上传设备推送标识；你可以在系统设置中关闭通知，退出登录或注销账号时会清除服务端绑定。

二、图片选择与裁剪
仅在你主动上传头像、帖子或商品图片时请求相册访问。图片会在上传前由你选择，上传后用于展示你发布的内容。

三、教务 WebView
教务网页仅在你主动使用相关功能时加载，并按专项授权使用必要的登录状态。你可以在教务功能中清除 Cookie 或解除绑定。

四、可选 AI 功能
若启用课表解析等 AI 功能，应用应在发送数据前展示实际服务名称、传输内容和处理目的；未启用时不向该服务提供数据。
''',
  );

  static const eduDataConsent = LegalDocument(
    id: 'edu_data_consent',
    title: '教务数据专项授权',
    summary: '教务认证、凭证保存、课表成绩读取及撤回方式',
    eduOnly: true,
    body: '''
版本：2026-07-18

你授权本服务在你主动注册、绑定或刷新教务功能时，使用你输入的教务账号和密码完成身份认证，并保存经加密处理的必要认证凭证、登录 Cookie 和绑定状态，以读取你主动请求的课表、成绩、考试和学籍相关信息。

处理目的仅限教务功能和身份核验，不用于公开展示、广告营销或向无关用户提供。你可以随时解除教务绑定并撤回本项授权；解绑后，将清除服务端教务凭证和绑定资料，基础社区功能不受影响。
''',
  );

  static const all = <LegalDocument>[
    userAgreement,
    privacyPolicy,
    communityRules,
    minorProtection,
    contentComplaintRules,
    sdkDisclosure,
    eduDataConsent,
  ];

  static LegalDocument byId(String id) =>
      all.firstWhere((document) => document.id == id);
}

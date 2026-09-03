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
  static const version = '2026-09-03-r1';

  static const userAgreement = LegalDocument(
    id: 'user_agreement',
    title: '用户协议',
    summary: '账号、服务范围、行为规范与账号注销规则',
    body: '''
版本：2026-09-03

一、服务说明
本服务提供校园信息、社区互动、课程与其他校园工具。请在合法、善意且不侵害他人权益的前提下使用。

二、账号与内容
请妥善保管账号。不得冒用他人身份、发布违法或侵权内容、实施欺诈、骚扰、恶意营销或绕过安全机制。你应对自行发布的内容负责。

三、分项授权与账号注销
本机教务授权、远程消息推送和本地提醒分别管理，可在对应功能入口关闭或撤回。你也可以使用密码确认注销账号，注销后身份资料会被清除或匿名化。

四、联系我们
个人信息与账号相关请求可在“隐私与数据权利”中提交并查看处理状态。
''',
  );

  static const privacyPolicy = LegalDocument(
    id: 'privacy_policy',
    title: '隐私政策',
    summary: '个人信息处理目的、范围、保存与权利行使方式',
    body: '''
版本：2026-09-03

一、我们处理的信息
注册与使用服务时，可能处理学号或 QQ 号、昵称、头像、账号密码摘要、设备推送标识、你主动发布的内容和图片。使用教务功能时，教务账号、认证凭证、课表、成绩和学籍相关信息仅在设备上按专项授权处理；教务密码、Cookie、会话令牌及原始教务响应不会发送给 SYLUlive 服务器。

二、处理目的与最小化
账号信息用于身份认证和服务提供；设备推送标识仅用于消息提醒；本机教务数据仅用于已启用的教务功能。教务结果保存在设备端的加密保险箱中，密码、Cookie 和会话令牌不出现在个人数据导出文件中。

三、保存期限
账号信息保存至账号注销或实现服务目的所需的期限；安全日志和必要审计记录按适用法律留存。教务会话仅保存在设备运行时内存，本机教务缓存可在教务入口清除；SYLUlive 服务器不保存教务凭证或原始教务数据。

四、你的权利
你可以在“隐私与数据权利”中直接查阅账户资料和授权记录、导出个人数据，申请更正或删除特定信息、内容并查看处理状态。

五、联系信息
个人信息保护请求可在“隐私与数据权利”中提交并查看处理状态。
''',
  );

  static const communityRules = LegalDocument(
    id: 'community_rules',
    title: '社区规则',
    summary: '内容发布、二手交易与互动行为要求',
    requiredForRegistration: false,
    body: '''
版本：2026-09-03

不得发布违法违规、侵犯隐私、侮辱诽谤、诈骗、色情低俗、暴力恐怖、违禁交易或侵犯知识产权的内容。发布他人信息、照片、联系方式或试卷资料前，应取得合法授权。

二手交易仅用于信息交流。请自行核验交易对象与商品，不要在平台外泄露密码、验证码或支付凭证。平台可依据举报和审核规则处理违规内容，并向内容发布者说明处置理由和申诉渠道。
''',
  );

  static const minorProtection = LegalDocument(
    id: 'minor_protection',
    title: '未成年人保护规则',
    summary: '未成年人使用、内容与个人信息保护要求',
    requiredForRegistration: false,
    body: '''
版本：2026-09-03

如你是未成年人，请在监护人同意和指导下使用服务。我们不以未成年人为对象开展不适当营销；发现可能危害未成年人身心健康或侵犯其个人信息的内容时，可采取限制展示、删除、账号限制等措施。

监护人可通过“隐私与数据权利”直接查阅相关账户资料，或提交删除、处理未成年人相关个人信息的请求。
''',
  );

  static const contentComplaintRules = LegalDocument(
    id: 'content_complaint_rules',
    title: '投诉举报规则',
    summary: '举报入口、审核处理与申诉机制',
    requiredForRegistration: false,
    body: '''
版本：2026-09-03

对帖子和评论可使用应用内举报入口提交理由。管理员会记录处理结论；必要时可删除或限制内容。内容被处置后，发布者可以通过应用内申诉流程请求复核。

涉及紧急违法风险、未成年人安全或个人信息泄露时，请通过应用内举报入口反馈。
''',
  );

  static const sdkDisclosure = LegalDocument(
    id: 'sdk_disclosure',
    title: '第三方服务说明',
    summary: '推送、图片选择、本机教务网络与可选 AI 服务的处理说明',
    requiredForRegistration: false,
    body: '''
版本：2026-09-03

一、极光推送
远程消息推送默认关闭。只有你主动开启并确认推送处理摘要后，应用才初始化极光 SDK、获取 Registration ID、绑定 Alias 和上传设备标识。当前版本一个账号仅支持一台设备接收远程消息，后启用设备会替换此前设备；关闭入口在“消息与通知”。

二、图片选择与裁剪
仅在你主动上传头像、帖子或商品图片时请求相册访问。图片会在上传前由你选择，上传后用于展示你发布的内容。

三、本机教务直连
教务功能仅在你主动使用时由设备直接访问 jxw.sylu.edu.cn。登录凭证和 Cookie 只在本机教务会话内存中使用；成绩、课表等结果如需缓存，会写入设备端加密保险箱。SYLUlive 服务器不代理该访问，也不接收教务凭证。

四、课表识别提示词
应用生成提示词并由你自行复制到所选择的外部 AI 服务，再将标准 JSON 导回 App。提示词默认不包含班级号；你可主动选择加入班级号。复制后内容由对应外部服务商按照其规则处理。
''',
  );

  static const eduDataConsent = LegalDocument(
    id: 'edu_data_consent',
    title: '教务数据专项授权',
    summary: '本机教务认证、结果缓存、课表成绩读取及撤回方式',
    eduOnly: true,
    body: '''
版本：2026-09-03

你授权应用在你主动登录或刷新教务功能时，由设备直接访问 jxw.sylu.edu.cn，使用你输入的教务账号和密码完成身份认证，并读取你主动请求的课表、成绩、考试和学籍相关信息。教务密码、Cookie 和会话令牌不会上传到 SYLUlive 服务器，服务器也不代理这次访问。

处理目的仅限教务功能和身份核验，不用于公开展示、广告营销或向无关用户提供。登录会话结束或你主动退出教务时，应用会清除本机凭证和 Cookie；本机加密缓存可在隐私与数据权利中清除。
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

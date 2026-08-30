import '../common/jpush_client.dart';
export '../common/jpush_client.dart' show JPushClient;

/// 旧名称兼容层。新代码使用 JPushClient。
@Deprecated('Use JPushClient')
typedef AndroidJPushClient = JPushClient;

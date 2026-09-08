import '../../../platform/contracts/preferences_store.dart';
import '../domain/academic_provider.dart';
import 'academic_connection_store.dart';

/// 提醒和小组件是单槽投影，所有权必须与实际写入、删除串行提交。
final class AcademicAuxiliaryOwnership {
  static final Map<String, Future<void>> _tails = {};

  static Future<T> _serialize<T>(String kind, Future<T> Function() action) {
    final operation =
        (_tails[kind] ?? Future<void>.value()).then((_) => action());
    final tail =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tails[kind] = tail;
    return operation.whenComplete(() {
      if (identical(_tails[kind], tail)) _tails.remove(kind);
    });
  }

  static Future<T?> write<T>(String kind, AcademicIdentityKey? identity,
          Future<T> Function() action,
          {bool Function()? isCurrent}) =>
      _serialize(kind, () async {
        final prefs = await AppPreferencesStore.getInstance();
        if (isCurrent != null && !isCurrent()) return null;
        if (identity != null) {
          if (!AcademicConnectionStore(identity, prefs).connected) return null;
          if (!await prefs.setString(
              'academic_auxiliary_owner_$kind', identity.storageId)) {
            throw StateError('记录教务辅助数据归属失败');
          }
        } else if (!await prefs.remove('academic_auxiliary_owner_$kind')) {
          throw StateError('更新教务辅助数据归属失败');
        }
        return action();
      });

  static Future<void> clear(String kind, AcademicIdentityKey identity,
          Future<void> Function() action,
          {bool includeLegacy = false}) =>
      _serialize(kind, () async {
        final prefs = await AppPreferencesStore.getInstance();
        final key = 'academic_auxiliary_owner_$kind';
        final owner = prefs.getString(key);
        if (owner != identity.storageId && !(owner == null && includeLegacy)) {
          return;
        }
        // 先认领旧单槽数据；删除失败后即使身份已换绑，冷启动仍能按原身份重试。
        if (owner == null && !await prefs.setString(key, identity.storageId)) {
          throw StateError('记录旧教务辅助数据归属失败');
        }
        await action();
        if (!await prefs.remove(key)) throw StateError('清理教务辅助数据归属失败');
      });
}

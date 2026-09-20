import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../application/emoji_pack_installer.dart';
import 'emoji_pack_local_store.dart';

abstract final class EmojiPackRuntime {
  static final _stores = <String, Future<EmojiPackLocalStore>>{};
  static Future<EmojiPackLocalStore> forAccount(String? userId) {
    final scope = userId == null ? 'anonymous' : 'user:$userId';
    return _stores.putIfAbsent(
        scope,
        () => _open(scope).catchError((Object error) {
              _stores.remove(scope);
              throw error;
            }));
  }

  static Future<EmojiPackLocalStore> _open(String scope) async {
    final base = await getApplicationSupportDirectory();
    final id = sha256.convert(utf8.encode(scope));
    final store =
        EmojiPackLocalStore(Directory('${base.path}/emoji-packs/$id'));
    await EmojiPackInstaller(store).recover();
    return store;
  }
}

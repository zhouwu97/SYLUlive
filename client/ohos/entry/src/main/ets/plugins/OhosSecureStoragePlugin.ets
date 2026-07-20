import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * 为 Flutter 认证链提供鸿蒙系统安全存储。
 *
 * Asset Store Kit 将令牌和教务密码托管给系统安全服务，不在应用私有目录或
 * SharedPreferences 中落明文。这里不设置 IS_PERSISTENT，卸载应用时数据不会保留。
 */
export default class OhosSecureStoragePlugin implements FlutterPlugin, MethodCallHandler {
  private static readonly CHANNEL_NAME: string = 'shenliyuan/secure_storage';
  private static readonly ALIAS_PREFIX: string = 'shenliyuan.auth.';
  private channel: MethodChannel | null = null;
  private readonly encoder: util.TextEncoder = new util.TextEncoder();
  private readonly decoder: util.TextDecoder = new util.TextDecoder();

  getUniqueClassName(): string {
    return 'OhosSecureStoragePlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(
      binding.getBinaryMessenger(),
      OhosSecureStoragePlugin.CHANNEL_NAME,
    );
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.handleCall(call)
      .then((value: string | null): void => result.success(value))
      .catch((error: Error): void => {
        result.error('secure_storage_error', error.message, null);
      });
  }

  private async handleCall(call: MethodCall): Promise<string | null> {
    const key = this.requiredString(call, 'key');
    switch (call.method) {
      case 'read':
        return this.read(key);
      case 'write':
        await this.write(key, this.requiredString(call, 'value'));
        return null;
      case 'delete':
        await this.delete(key);
        return null;
      default:
        throw new Error(`不支持的安全存储操作: ${call.method}`);
    }
  }

  private requiredString(call: MethodCall, name: string): string {
    const value: string | null = call.argument(name) as string | null;
    if (typeof value !== 'string' || value.length === 0) {
      throw new Error(`安全存储参数无效: ${name}`);
    }
    return value;
  }

  private createAliasMap(key: string): asset.AssetMap {
    const attributes = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, this.encoder.encodeInto(this.aliasFor(key)));
    return attributes;
  }

  private async read(key: string): Promise<string | null> {
    const query = this.createAliasMap(key);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const records = await asset.query(query);
      if (records.length === 0) {
        return null;
      }
      const secret: asset.Value | undefined = records[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array)) {
        throw new Error('安全存储返回的数据格式无效');
      }
      return this.decoder.decodeToString(secret);
    } catch (error) {
      const businessError = error as BusinessError;
      if (this.isNotFound(businessError)) {
        return null;
      }
      throw new Error(`读取安全存储失败，错误码: ${businessError.code}`);
    }
  }

  private async write(key: string, value: string): Promise<void> {
    const attributes = this.createAliasMap(key);
    attributes.set(asset.Tag.SECRET, this.encoder.encodeInto(value));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attributes);
  }

  private async delete(key: string): Promise<void> {
    try {
      const query = this.createAliasMap(key);
      await asset.remove(query);
    } catch (error) {
      const businessError = error as BusinessError;
      if (!this.isNotFound(businessError)) {
        throw new Error(`删除安全存储失败，错误码: ${businessError.code}`);
      }
    }
  }

  private isNotFound(error: BusinessError): boolean {
    return error.code === asset.ErrorCode.NOT_FOUND;
  }

  private aliasFor(key: string): string {
    return `${OhosSecureStoragePlugin.ALIAS_PREFIX}${key}`;
  }
}

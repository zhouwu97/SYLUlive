# Build Notes

## Windows 跨盘符缓存与编译速度问题记录

在 Windows 系统下进行 Flutter Android 打包 (尤其是 Release 模式) 时，如果项目所在盘符（如 E 盘）与默认的 Pub 缓存路径（通常在 C 盘 `C:\Users\<User>\AppData\Local\Pub\Cache`）不同，开启 Kotlin 增量编译时可能会遇到类似以下的报错：

```text
this and base files have different roots:
C:\Users\...\AppData\Local\Pub\Cache\...
and
E:\AI\xynewui\client\android
```

如果为了绕过此错误强行关闭 `kotlin.incremental=false` 等加速配置，会导致打包耗时暴增（例如 7分钟+）。

### 最佳实践方案

**核心思路：将 PUB_CACHE 挪到与项目同一盘符。**

1. **设置环境变量**
   在 PowerShell 中执行以下命令进行永久配置：
   ```powershell
   setx PUB_CACHE "E:\AI\pub-cache"
   ```
   *注意：执行后需重新打开 PowerShell 终端，使用 `echo $env:PUB_CACHE` 确认输出为新路径才算彻底生效。*

2. **恢复加速配置**
   确保 `android/gradle.properties` 启用了加速项：
   ```properties
   kotlin.incremental=true
   kotlin.compiler.execution.strategy=daemon
   org.gradle.caching=true
   org.gradle.parallel=true
   # 根据电脑内存配置，16GB 推荐 6，32GB 可试 8
   org.gradle.workers.max=6
   ```

3. **清理与重构**
   如果之前因为路径不同构建失败，需重新下载依赖：
   ```powershell
   flutter clean
   flutter pub get
   ```
   之后使用 `flutter build apk --release` 打包。第一次编译需重新下载并编译会稍慢，第二次开始就会回到正常速度（约1分多钟）。

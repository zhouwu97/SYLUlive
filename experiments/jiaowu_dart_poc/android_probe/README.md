# Jiaowu Android Probe

> 状态：诊断工具。用于人工真机回归，不是正式客户端，也不应把测试输出或真实个人成绩提交到仓库。

Batch 7.1 Grade Detail 的 Android 真机验证应用。

## 功能

- 登录教务系统
- 获取学生 Profile
- 获取成绩列表
- 查询成绩详情（前两门课程）

## 运行步骤

### 1. 连接 Android 设备

**方式 A: USB 连接**
1. 手机开启开发者选项和 USB 调试
2. USB 连接电脑
3. 确认授权弹窗

**方式 B: 无线调试 (Android 11+)**
1. 手机开启开发者选项
2. 启用"无线调试"
3. 记下 IP 地址和端口（例如 192.168.1.100:12345）
4. 电脑执行：
   ```bash
   adb connect 192.168.1.100:12345
   ```

### 2. 验证设备连接

```bash
cd experiments/jiaowu_dart_poc/android_probe
flutter devices
```

应该看到 Android 设备出现在列表中。

### 3. 运行 Probe

```bash
flutter run
```

或者指定设备：
```bash
flutter run -d <设备ID>
```

### 4. 在手机上操作

1. 输入本地测试学号（不要写入仓库）
2. 输入本地测试密码（不要写入仓库）
3. 点击"运行 Probe"
4. 观察日志输出

### 预期输出

```
[时间] 开始登录...
[时间] ✓ 登录成功
[时间] 获取 Profile...
[时间] ✓ Profile: <REDACTED_PROFILE>
[时间] 获取成绩列表...
[时间] ✓ 成绩列表: <COUNT> 条
[时间] 开始查询成绩详情...
[时间] 查询课程: <REDACTED_COURSE>
[时间] ✓ 详情解析完成
[时间]
[时间] ========================================
[时间] ✓ Android Probe 完成
[时间] ========================================
```

## 构建 APK（可选）

如果需要独立 APK 文件：

```bash
flutter build apk --release
```

生成的 APK 位于：
```
android_probe/build/app/outputs/flutter-apk/app-release.apk
```

可以直接发送到手机安装。

## 网络权限

已配置：
- `INTERNET` 权限
- `usesCleartextTraffic="true"`（仅供隔离诊断环境；正式客户端不得因此放宽传输安全）

## 依赖

- `jiaowu_dart_poc`（本地包，path 依赖）
- `flutter`

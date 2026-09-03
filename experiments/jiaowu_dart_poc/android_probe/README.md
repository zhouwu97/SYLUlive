# Jiaowu Android Probe

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
cd E:/AI/xynewui/experiments/jiaowu_dart_poc/android_probe
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

1. 输入学号：`[REDACTED_STUDENT_ID]`
2. 输入密码：`[REDACTED_PASSWORD]`
3. 点击"运行 Probe"
4. 观察日志输出

### 预期输出

```
[时间] 开始登录...
[时间] ✓ 登录成功
[时间] 获取 Profile...
[时间] ✓ Profile: [REDACTED_NAME] ([REDACTED_STUDENT_ID])
[时间] 获取成绩列表...
[时间] ✓ 成绩列表: 13 条
[时间] 开始查询成绩详情 (2 门课程)...
[时间] 查询课程 1: 数据通信与机器人控制
[时间]   ✓ 总评: 良好
[时间]   ✓ 分项数: 4
[时间]     - 平时成绩: 100 40%
[时间]     - 作品成绩: 83 30%
[时间]     - 课程报告: 82 30%
[时间]     - 总评: 良好
[时间] 查询课程 2: 信号与系统
[时间]   ✓ 总评: 55.8
[时间]   ✓ 分项数: 3
[时间]     - 平时: 84.7 50%
[时间]     - 期末: 27 50%
[时间]     - 总评: 55.8
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
- `usesCleartextTraffic="true"`（允许 HTTP 流量）

## 依赖

- `jiaowu_dart_poc`（本地包，path 依赖）
- `flutter`

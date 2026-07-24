# 个人资料悬浮窗编辑 — 实施计划

## 目标

个人主页支持修改昵称、性别、背景图，通过底部悬浮窗统一操作。

---

## Step 1: 后端 — Gender 字段

### 1a) models/user.go

加字段（建议用 string，不用 int）：
```go
Gender string `gorm:"size:10;default:''" json:"gender"` // "male"/"female"/"" (未知)
```

### 1b) handlers/user.go — UpdateProfileInput

```go
type UpdateProfileInput struct {
    Nickname string `json:"nickname"`
    Gender   string `json:"gender"`
}
```

UpdateProfile 方法内 — `Update("nickname", ...)` 改为：
```go
h.db.Model(&models.User{}).Where("id = ?", userID).Updates(map[string]interface{}{
    "nickname": input.Nickname,
    "gender":   input.Gender,
})
```

---

## Step 2: 前端 — User 模型

### 2a) models/user.dart

加字段：
```dart
final String gender;
```
fromJson: `gender: json['gender'] ?? ''`
toJson: `'gender': gender`
构造函数默认值: `this.gender = ''`

---

## Step 3: 前端 — user_home_screen 改造

### 3a) 性别图标动态化 (L230-232)

```dart
// 改前
Icon(Icons.male, size: 12, color: Colors.blue[300])

// 改后
Icon(
  user.gender == 'female' ? Icons.female : Icons.male,
  size: 12,
  color: user.gender == 'female' ? Colors.pink[300] : Colors.blue[300],
),
```

### 3b) 背景图可点击

在 `SliverAppBar.flexibleSpace` 的 Container 外包 GestureDetector，onTap → `_showEditSheet()`

### 3c) 编辑资料按钮 → 唤起悬浮窗

"编辑资料"按钮 onPressed 改为 `_showEditSheet()`

### 3d) 底部悬浮窗 `_showEditSheet()`

```dart
void _showEditSheet() {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _EditProfileSheet(user: user),
  );
}
```

### 3e) _EditProfileSheet 组件

```
Container (底部弹出)
├── 拖动指示条
├── "编辑资料" 标题
├── 更改背景
│   └── GestureDetector → ImagePicker → PUT /api/user/background → 刷新 UI
├── 昵称
│   └── TextField(initialValue: user.nickname)
├── 性别
│   └── SegmentedButton / ToggleButtons: 男生 | 女生 | 保密
└── 保存按钮
    └── PUT /api/user/profile {nickname, gender} → authProvider.refreshUser()
```

背景上传直接复用 `auth_provider.dart` 已有的 `updateAvatar` 模式（upload file → 拿 URL → PUT background）。

---

## 验证

- [ ] 服务端 `AutoMigrate` 自动加 gender 列
- [ ] 修改性别后刷新页面，图标和颜色正确切换
- [ ] 修改昵称保存后实时显示
- [ ] 上传背景图后主页背景更新
- [ ] `go build ./...` + `flutter analyze` 通过

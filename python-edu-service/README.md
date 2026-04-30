# 沈理校园 - Python 教务服务

基于 FastAPI + httpx 实现的教务系统爬取服务。

## 功能

- 🎓 教务账号绑定（RSA加密登录）
- 📚 课表提取与同步
- ✏️ 课程自定义（颜色、别名、地点、课时长等）
- 📊 成绩查询

## 快速开始

### 1. 安装依赖

```bash
pip install -r requirements.txt
```

### 2. 运行服务

```bash
python main.py
```

或使用 uvicorn：

```bash
uvicorn main:app --reload --host 0.0.0.0 --port 8081
```

服务将在 http://localhost:8081 启动

### 3. API 文档

启动后访问：
- Swagger UI: http://localhost:8081/docs
- ReDoc: http://localhost:8081/redoc

## API 列表

### 认证
- `POST /api/edu/bind` - 绑定教务账号
- `DELETE /api/edu/bind` - 解绑教务账号
- `GET /api/edu/status` - 获取绑定状态
- `POST /api/edu/refresh_cookie` - 刷新Cookie

### 课程
- `POST /api/edu/courses/fetch` - 从教务提取课表
- `POST /api/edu/courses/sync` - 同步课表到本地
- `GET /api/edu/courses/local` - 获取本地课表
- `PUT /api/edu/courses/{id}` - 更新课程
- `DELETE /api/edu/courses/{id}` - 删除课程

### 成绩
- `POST /api/edu/grades` - 获取成绩

## 配置

环境变量：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| HOST | 服务地址 | 0.0.0.0 |
| PORT | 服务端口 | 8081 |
| DATABASE_URL | 数据库连接 | sqlite+aiosqlite:///./database/edu.db |

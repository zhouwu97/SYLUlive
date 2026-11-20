# 学校入口只读性能测试

本工具测量 Python 本科教务协议客户端的真实学校网络耗时，不等同于浏览器扩展、手机界面或生产服务 SLO。固定查询课表和成绩，每次均在查询前后核验新鲜学校身份，不写入业务数据库、学校成绩或选课，不把个人教务资料发送给 AI。

使用已安装 `python-edu-service/requirements.txt` 的 Python，在仓库根目录执行：

```powershell
python scripts/benchmark_academic_access.py --live --year 2026 --semester 1 --samples 3 --output _codex_evidence/school-live.json
python -m unittest discover -s scripts/tests -p test_benchmark_academic_access.py -v
```

工具隐藏输入学校学号和学校密码；不要把凭据加在命令行、重定向文件或报告中。自动化入口可用 `--credentials-stdin` 接收私有管道中的 JSON，仅限本机进程间传递，不将真实值写成脚本。没有 `--live` 时在读取凭据和导入爬虫前退出。最多五轮、64 次请求，只允许 `https://jxw.sylu.edu.cn`，所有会话在结束时关闭，内存凭据字典清空。

输出仅含认证是否成功、操作结果、请求次数、HTTP 状态和耗时，不含账号、姓名、课程名、成绩、Cookie 或响应正文。旧爬虫的进度输出仅进入临时内存缓冲并丢弃；异常只写稳定错误码/异常类别。p95 为小样本插值结果，不能当作长期尾延迟承诺。保留首次失败、测试时间、客户端版本与网络位置的非个人说明，再复测；不得缓存身份或跳过查询后核验来改善数字。

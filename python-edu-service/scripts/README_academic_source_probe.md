# 阶段 3A.2 学业数据源探针

该脚本仅用于调查教务系统的动态请求、登录后菜单和候选毕业数据源，不提供客户端 API，也不生成毕业结论。

## 单账号探测

每个账号必须由本人授权。命令行只接收匿名样本标签，学号和密码在运行时交互输入，不进入参数、日志或输出文件。

```bash
cd python-edu-service
python scripts/probe_academic_sources.py run \
  --sample-id sample-a \
  --cohort-alias cohort-a \
  --major-alias major-a \
  --college-alias college-a
```

默认输出到 `private-probe-output/`。该目录已加入仓库根 `.gitignore`，脚本还会在输出目录内生成独立 `.gitignore`。

输出只包含：

- URL 路径、请求方法和参数名；
- HTTP 状态和 Content-Type；
- form、table、iframe、script 和结构字段名；
- JSON 字段结构或 HTML 结构计数；
- 课程动态来源与毕业完成度字段的布尔证据；
- 不含个人内容的结构签名。

脚本不会保存 Cookie、密码、学号、姓名、身份证号、完整 HTML、课程名、成绩或响应字段值。

## 多样本汇总

最低覆盖两个年级和两个专业，最好覆盖两个学院。匿名标签必须以字母开头，只允许字母、数字、下划线和连字符。

```bash
python scripts/probe_academic_sources.py merge \
  private-probe-output/sample-a.json \
  private-probe-output/sample-b.json \
  --overwrite
```

覆盖不足时结果固定为 `INCONCLUSIVE`，不会产生 A/B/C。覆盖满足后：

- A：跨样本稳定的 JSON 来源同时包含培养模块、要求学分、已获学分、剩余学分和课程明细；
- B：没有合格 JSON 接口，但存在具备同样字段且结构稳定的官方 HTML 页面；
- C：完成最低多样本验证、所有候选参数均已解析、所有候选请求及外部脚本检查均成功后，仍没有可靠官方来源。

检测到菜单文字或 `$.ajax` 只会生成候选。候选必须通过同源真实请求并出现业务字段，才能标记为 `verified_business_response`。

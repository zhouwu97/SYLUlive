# Pad 验证记录

本记录汇总已执行的验证和首次失败，并记录本机原始输出的 SHA-256。按仓库 Git 提交规则，原始 `.log` 留在本机同目录，不进入提交；提交包含本记录、测试文件清单及渲染证据。各次运行的顺序与修正原因见对应审核／修复报告。

## analyze-results

审核阶段静态分析：80 个既存诊断；详细分类见审核报告。

原始输出：`analyze-results.log`，13651 字节。

SHA-256：`b0ae202409416ef806875cc3dbf8af94b4c1678d7c8d68d13c6659e43c988c9e`。

## course-results-final

课表探针最终 7 项通过；F1 挤压问题有测量证据，按用户要求不修复。

原始输出：`course-results-final.log`，1718 字节。

SHA-256：`b60ace7b48a7cd0427ba4c6fd30b2e472dcf23c3776716194d932f5114217bc4`。

## feed-results-final-rail

水帖分栏探针最终 3 项通过。

原始输出：`feed-results-final-rail.log`，890 字节。

SHA-256：`6afb5d43d8b4508ec5be60159b92018affaa6c4eb2c18a4ea70669f44a7a9790`。

## feed-results-rail

2 项通过、1 项失败；探针读取了不存在的 BottomNav，已修正。

原始输出：`feed-results-rail.log`，2447 字节。

SHA-256：`08f9683f20bfdfebe693d96c98032f8038ba41c955b437e575960d9e3ff619ec`。

## feed-results-retry

2 项失败；测试 AuthProvider 夹具缺 token，已修正。

原始输出：`feed-results-retry.log`，41930 字节。

SHA-256：`bd1fefdc05859d7c3452ab49c8db615bf6dd5381415bf0004e72146082372c8c`。

## feed-results

1 项失败；测试夹具缺失导致编译失败，已修正。

原始输出：`feed-results.log`，1941 字节。

SHA-256：`8f4acf2b6808a86d90a4d5e24c03781889b7d555addd0c162ac887415170b961`。

## market-detail-results

商品详情连续 resize 探针 2 项通过。

原始输出：`market-detail-results.log`，581 字节。

SHA-256：`8d95eac6dc0cc3d76b569221360e32648adfa94a4ca1c9fb42a6a68e4574a7d4`。

## widgets-results-retry

页面矩阵探针最终 23 项通过。

原始输出：`widgets-results-retry.log`，2845 字节。

SHA-256：`776cf1d33650ccd66cb78cce8f965b0c35cfbdc7eb1b4513ebfa73a3953a34be`。

## widgets-results

首次页面矩阵执行出现测试环境异常，终止进程；修正缓存 mock 和 pump 后重跑，保留首次记录。

原始输出：`widgets-results.log`，185461 字节。

SHA-256：`ceeb26daaba4d99319337c91343bf68f071d300261659c764d8b50f85f4f9406`。

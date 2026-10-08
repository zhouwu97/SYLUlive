# Pad 验证记录

本记录汇总已执行的验证和首次失败，并记录本机原始输出的 SHA-256。按仓库 Git 提交规则，原始 `.log` 留在本机同目录，不进入提交；提交包含本记录、测试文件清单及渲染证据。各次运行的顺序与修正原因见对应审核／修复报告。

## fix-all-final

最终集合首跑：270 项通过、6 项失败；登录焦点断言读取了允许为空的 TextField.focusNode。改用实际 EditableText 焦点后，原断言要求不变。

原始输出：`fix-all-final.log`，61683 字节。

SHA-256：`f8e1fa1877bfb00edbf1cafabbfb63a8d5bc7ea3db2a9fe7e252b0641671d621`。

## fix-all-verified

最终定向回归：31 个测试文件、276 项全部通过。

原始输出：`fix-all-verified.log`，52331 字节。

SHA-256：`5dcbe638a8cca9c99f1c5c1e640528b4d1ef2ef753ad4ec511c0d98db582a070`。

## fix-analyze-verified

最终定向静态分析：0 error、13 warning、25 info；不标记为完全通过。

原始输出：`fix-analyze-verified.log`，5926 字节。

SHA-256：`dedc830253003a0caa8d861419bd56e5683af5255f72bb0ef08be0e27c744283`。

## fix-golden-check

Golden 基础设施 11 项通过、1 项按既有开关跳过；没有执行产品像素比较，没有更新 canonical PNG。

原始输出：`fix-golden-check.log`，2031 字节。

SHA-256：`c73b49afa22b6e6ddf10525b4431b08fae8b4e2cd2efd610fc3ee2fb40684917`。

## fix-module-regression

178 项通过、3 项失败；夹具缺照片、缺学生认证、共享拦截器时序。已补齐前置条件并隔离响应。

原始输出：`fix-module-regression.log`，38355 字节。

SHA-256：`ba4ef6eb8ef07fa9389ed6ed6914a80fedbcb3d97bcaf51943e794bf89989d16`。

## fix-pad-final

47 项通过、1 项失败；校园失败重试受到拦截器时序影响，已使用隔离、确定性的失败响应修正。

原始输出：`fix-pad-final.log`，11353 字节。

SHA-256：`80afd517e1134812dcf5a267d55bdcdba53e4c7d647943939283408e33f3e69f`。

## fix-pad-first

43 项通过、11 项失败；图片对象夹具、视口 helper 和宽度测量对象不正确，修正后保留原有验证要求。

原始输出：`fix-pad-first.log`，27736 字节。

SHA-256：`7e79124aca892e61b6f18f86afc17fe80989ee322caf8fbc75d3ad4bf14b48e6`。

# 自主发帖发布与恢复

本流程适用于逐账号 AstrBot 0.5.1。后端、官网授权页和插件必须匹配，不能只打开本机发帖开关。

1. 在独立候选中保留现网的个人查询、同步、密码验证、管理员授权接口和审计字段；固定完整提交与构建哈希，执行相关测试和安全扫描。生产执行入口继续使用 DEPLOY.md 的 deploy/deploy-shenliyuan。
2. 备份数据库、原二进制、运行配置与现有官网子目录；确认备份可读取。Go 使用仓库声明的版本；若工具链通过符号链接安装，显式设置正确 GOROOT，不能跳过版本校验。
3. 发布 Go 后核实 /api/version 的 managed_bot_v1、managed_bot_runtime_v1，以及本人管理、策略、心跳接口的鉴权。匿名请求应被拒绝，不能返回404；旧管理接口、个人查询和密码验证路由继续存在。
4. 按明确放行范围设置 INTEGRATIONS_ENABLED、INTEGRATION_PROPOSALS_ENABLED、INTEGRATION_AUTO_POST_ENABLED。自动评论由 INTEGRATION_AUTO_REPLY_ENABLED 独立控制；不顺带开放 INTEGRATION_OWNER_PUBLISH_ENABLED。其他既有配置保留。
5. 官网只更新匹配的 /web/ 子目录，不覆盖独立首页、上传或下载文件。插件安装完整匹配包，保留现有群规则、平台、凭据和记忆；community_auto_post 与 community_multi_user_runtime_enabled 由部署者按放行范围启用。
6. 每位使用者本人在官网创建、配置并启用自己的机器人，在本人私聊发起连接后独立核对 community:bot_post 授权。若需在获准群发起，部署者另将精确群号加入 community_bot_authorization_group_ids，并保留原绑定权限裁决；链接仍只投递发起人，本人官网确认后才生效，不给群模型发布工具。已有连接缺少权限时由 /sylu-connect 申请更新，官网确认替换前不扩权，不要求先撤销原授权。评论和发帖 scope 默认不选；禁止脚本改库扩充旧 scope、借用其他账号或伪造资格。未完成授权时应显示缺授权，不发布。
7. 验收至少覆盖真实模型读帖后发帖、真实 bot 作者、来源版本、每日额度、幂等重放、暂停、撤权、旧执行会话及账号隔离。生产发言只在本人授权和允许版块内进行；模型可以跳过无价值内容。

回退先关闭自动评论／发帖并停止新 Agent 请求，再恢复已验证的二进制、官网和插件。保留新增兼容字段、授权撤销记录、公开帖子和发言账本，不用整库恢复抹掉发布后变化。原始配置恢复应逐项合并，保留他人后续修改。运行状态和发言成功必须以实际服务和数据库记录为准。

跨端隔离验收入口为 Go 的 TestIntegrationWebAstrBotCrossRuntime；候选应同时保留 scripts/verify-web-astrbot-chain.py、.mjs 和 verify_multibot_runtime.py，不能只复制 Go 测试壳。SYLULIVE_FULL_CHAIN_PYTHON 指向独立 AstrBot SDK 环境，SYLULIVE_FULL_CHAIN_WEB 只填本地 Web origin（例如 http://127.0.0.1:5188，不带 /web/），Go 夹具负责代理 /web/ 路由。Web 开发服务器的默认 API origin 应指向不可达的本地端口，防止测试遗漏路由时回落生产；该验收不连接真实学校或 QQ。

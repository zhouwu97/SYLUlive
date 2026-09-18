#!/usr/bin/env bash
# 旧版单体部署入口已下线。
# 它会绕过 Nginx 直接运行 Go 服务，无法保证真实来源、限流和安全环境变量配置，
# 因此保留路径但 fail closed，避免历史文档或人工误执行造成公网 8080 暴露。
set -Eeuo pipefail

printf '%s\n' '[ERR] deploy.sh 已废弃，不得作为生产部署入口。' >&2
printf '%s\n' '[ERR] 请使用 deploy/deploy-shenliyuan，并先确认 .env 已配置 TRUSTED_PROXY_CIDRS、SECURITY_EVENT_HMAC_SECRET、SECURITY_BLOCK_ENABLED、SECURITY_SOURCE_ATTRIBUTION_VALID_FROM。' >&2
exit 1

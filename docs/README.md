# SYLUlive 文档中心

这里是仓库文档的导航入口。根目录 README 只介绍产品和最短的开发路径，部署、隐私、设计和专项方案在本目录维护。

## 使用者与贡献者

- [根 README](../README.md)：产品定位、下载、能力和仓库概览
- [开发与交付规范](../DEVELOPMENT_STANDARD.md)：任务、测试、验收、发布和回滚的统一流程
- [贡献指南](../CONTRIBUTING.md)：本地检查和提交约定
- [客户端说明](../client/README.md)：Flutter 运行、客户端边界和本地教务
- [服务端说明](../server/README.md)：Go 服务、配置、测试和架构边界
- [后端 API](../server/API.md)：接口总览、认证方式和迁移期路由状态

## 生产与运维

- [部署总入口](../DEPLOY.md)
- [留存与备份清单](./retention-and-backup-inventory.md)
- [本地存储清单](./local-storage-inventory.md)
- [第三方服务清单](./third-party-service-inventory.md)
- [隐私发布检查](./privacy-release-checklist.md)
- [部署专项文档](./ops/)
- [部署配置与脚本](../deploy/)

## 隐私与安全

- [隐私数据台账](./privacy-data-inventory.md)
- [竞赛推荐产品契约](./plans/competition-recommendation-plan.md)
- [竞赛推荐算法契约](./plans/competition-recommendation-algorithm-plan.md)
- [架构决策记录](./design/adr/)

## 设计

- [设计文档导航](./design/README.md)
- [设计系统](./design/DESIGN_SYSTEM.md)
- [动效规范](./design/MOTION.md)
- [无障碍规范](./design/ACCESSIBILITY.md)
- [设计 QA](./design/DESIGN_QA.md)

## AI、知识库与教务协议

- [AI 文档](./ai/)
- [校园政策知识库](../knowledge-base/README.md)
- [RAG 服务](../python-rag-service/README.md)
- [MCP 适配器](../_mcp/README.md)
- [客户端教务协议库](../experiments/jiaowu_dart_poc/README.md)：正式客户端的本地依赖，保留源码、协议测试及夹具

## 历史记录

一次性任务计划、截图、诊断应用和构建产物不纳入软件源码。历史材料可从 Git 历史查阅；新的本地验收记录可放在已忽略的 `docs/reports/`，正式发布证据应随发布记录或 CI 产物保存。现有产品契约仍引用的报告继续保留，不作为当前生产状态的证明。

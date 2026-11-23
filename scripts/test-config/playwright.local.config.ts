import { webTestConfig } from './playwright.config';

// 将本机测试与 5173 的日常联调进程分开，仍由全局探针复核 API 环境。
export default webTestConfig(5187);

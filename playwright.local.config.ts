import {defineConfig} from '@playwright/test';
import baseConfig from './playwright.config';

// 将本机测试与 5173 的日常联调进程分开，仍由全局探针复核 API 环境。
export default defineConfig(baseConfig,{
  use:{baseURL:'http://127.0.0.1:5187/web/'},
  webServer:{
    command:'pnpm --filter @sylulive/web dev --port 5187',
    url:'http://127.0.0.1:5187/web/',
    reuseExistingServer:true,
    env:{SYLULIVE_API_ORIGIN:'http://127.0.0.1:8080'},
    timeout:30000,
  },
});

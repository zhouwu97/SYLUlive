import {defineConfig} from '@playwright/test';
export default defineConfig({testDir:'web/e2e',fullyParallel:false,workers:1,use:{baseURL:'http://127.0.0.1:5173/web/',viewport:{width:1440,height:1000}},webServer:{command:'pnpm dev',url:'http://127.0.0.1:5173/web/',reuseExistingServer:true,timeout:30000},reporter:'list'});

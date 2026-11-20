declare const __STORE_BUILD__: boolean;

// 商店包只提供 HTTPS 教务连接；本地开发与原有解包渠道保持各自权限契约。
export const storeBuild = typeof __STORE_BUILD__ !== 'undefined' && __STORE_BUILD__;

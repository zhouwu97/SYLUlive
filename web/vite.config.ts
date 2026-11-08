import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
const target=process.env.SYLULIVE_API_ORIGIN||'https://sylulive.online';
export default defineConfig({base:'/web/',plugins:[react()],server:{host:'127.0.0.1',port:5173,strictPort:true,watch:{ignored:['**/public/assistant/**']},proxy:{'/api':{target,changeOrigin:true,configure(proxy){proxy.on('proxyReq',(proxyReq,req)=>{/* 本地页面（任意主机名/局域网地址）发起的写请求，来源改写为目标站，其他来源原样转发；
  只比主机名不比端口：部分浏览器扩展会去掉 Origin 里的端口。 */
  const origin=req.headers.origin,host=(req.headers.host||'').replace(/:\d+$/,'');
  try{if(origin&&new URL(origin).protocol==='http:'&&new URL(origin).hostname===host)proxyReq.setHeader('Origin',new URL(target).origin)}catch{/* 非法 Origin 原样转发，交由服务端拒绝 */}})}},'/uploads':{target,changeOrigin:true},'/stickers':{target,changeOrigin:true}}},build:{sourcemap:false}});

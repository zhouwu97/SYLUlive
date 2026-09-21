import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
const target=process.env.SYLULIVE_API_ORIGIN||'https://sylulive.online';
export default defineConfig({base:'/web/',plugins:[react()],server:{host:'127.0.0.1',port:5173,strictPort:true,proxy:{'/api':{target,changeOrigin:true,configure(proxy){proxy.on('proxyReq',(proxyReq,req)=>{if(['http://127.0.0.1:5173','http://localhost:5173'].includes(req.headers.origin||''))proxyReq.setHeader('Origin',new URL(target).origin)})}},'/uploads':{target,changeOrigin:true}}},build:{sourcemap:false}});

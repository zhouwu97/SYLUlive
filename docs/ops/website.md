# 官网部署

官网静态文件目录与 Flutter Web 构建产物隔离。生产官网使用 sylulive_site_v5 的完整发布包，通过 update-sylulive-site-v5 发布。

~~~bash
sudo /usr/local/sbin/update-sylulive-site-v5 /tmp/sylulive_site_v5
~~~

发布前确认首页、静态资源、/.well-known/assetlinks.json 和团队深链存在；脚本会检查必要资源、Nginx 路由和 Flutter Web 特征。发布失败时保留上一版并恢复。

官网发布不应重启 Go 服务，也不应把 client/build/web 复制到官网目录。

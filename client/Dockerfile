# 沈理校园前端
FROM ghcr.io/cirrusci/flutter:3.16.0 AS builder

WORKDIR /app

# 复制依赖文件
COPY pubspec.yaml ./

# 获取依赖（如果 pubspec.lock 存在会使用缓存）
RUN flutter pub get || true

# 复制源码
COPY lib ./lib
COPY assets ./assets

# 确保 assets/images 目录存在
RUN mkdir -p assets/images

# 构建 Web
RUN flutter build web --release

# Nginx 运行阶段
FROM nginx:alpine

# 复制构建产物
COPY --from=builder /app/build/web /usr/share/nginx/html

# 复制 Nginx 配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
# 沈理校园后端

FROM golang:1.21-alpine AS builder

WORKDIR /app

# 安装构建依赖
RUN apk add --no-cache git ca-certificates

# 复制源码（go.mod 在根目录）
COPY . .

# 下载依赖
RUN go mod download

# 构建（禁用 CGO，静态编译）
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o server ./cmd

# 运行镜像
FROM alpine:latest

WORKDIR /app

# 安装运行时依赖
RUN apk add --no-cache ca-certificates sqlite-libs

# 复制二进制文件
COPY --from=builder /app/server .

# 上传文件目录
RUN mkdir -p /app/uploads

# 暴露端口
EXPOSE 8080

# 设置环境变量默认值
ENV JWT_SECRET=shenliyuan-default-secret-change-in-production
ENV DSN=/app/shenliyuan.db
ENV UPLOAD_DIR=/app/uploads
ENV SUPER_ADMIN_DEFAULT_PASSWORD=super123456

# 启动命令
CMD ["./server"]
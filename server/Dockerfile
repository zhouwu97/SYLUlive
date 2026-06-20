# 沈理校园后端
FROM golang:1.23-bookworm AS builder

WORKDIR /app

ENV CGO_ENABLED=0
ENV GOTOOLCHAIN=local

COPY . .

RUN go mod download

RUN go build -ldflags="-w -s" -o server ./cmd

FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y ca-certificates

COPY --from=builder /app/server .

RUN mkdir -p /app/uploads

EXPOSE 8080

ENV DSN=host=postgres port=5432 user=postgres password=change_me_in_env dbname=shenliyuan sslmode=disable
ENV UPLOAD_DIR=/app/uploads
ENV GIN_MODE=release
ENV JWT_SECRET=your-super-secret-jwt-key-change-this

CMD ["./server"]

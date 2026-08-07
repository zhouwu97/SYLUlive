# 沈理校园后端
FROM golang:1.25-bookworm AS builder

WORKDIR /app

ENV CGO_ENABLED=0
ENV GOTOOLCHAIN=local

COPY . .

RUN go mod download

RUN go build -ldflags="-w -s" -o server ./cmd

FROM debian:bookworm-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/server .

RUN mkdir -p /app/uploads /app/private/exam-papers && chmod 0700 /app/private /app/private/exam-papers

EXPOSE 8080

ENV DSN="host=postgres port=5432 user=postgres password=change_me_in_env dbname=shenliyuan sslmode=disable"
ENV UPLOAD_DIR=/app/uploads
ENV EXAM_PAPER_DIR=/app/private/exam-papers
ENV GIN_MODE=release

CMD ["./server"]

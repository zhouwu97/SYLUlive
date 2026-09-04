# 沈理校园后端
FROM golang:1.25.13-bookworm AS builder

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

RUN groupadd --system --gid 10001 sylulive \
	&& useradd --system --uid 10001 --gid sylulive --home-dir /app --no-create-home --shell /usr/sbin/nologin sylulive \
    && mkdir -p /app/uploads /app/private/exam-papers /app/private/competition-award-evidence /app/releases \
    && chmod 0700 /app/private /app/private/exam-papers /app/private/competition-award-evidence \
    && chown -R sylulive:sylulive /app

USER sylulive

EXPOSE 8080

ENV DSN="host=postgres port=5432 user=postgres password=change_me_in_env dbname=shenliyuan sslmode=disable"
ENV UPLOAD_DIR=/app/uploads
ENV EXAM_PAPER_DIR=/app/private/exam-papers
ENV COMPETITION_AWARD_EVIDENCE_DIR=/app/private/competition-award-evidence
ENV APP_RELEASE_DIR=/app/releases
ENV GIN_MODE=release

CMD ["./server"]

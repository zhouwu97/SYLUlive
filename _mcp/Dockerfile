FROM golang:1.25-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/sylulive-mcp ./cmd/sylulive-mcp

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/sylulive-mcp /sylulive-mcp
USER nonroot:nonroot
ENTRYPOINT ["/sylulive-mcp"]

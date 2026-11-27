package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	mcpserver "sylulive-mcp/internal/mcp"
)

func main() {
	addr := flag.String("http", "127.0.0.1:8091", "Streamable HTTP listen address")
	backendURL := flag.String("backend", os.Getenv("SYLULIVE_INTERNAL_URL"), "SYLUlive Go internal URL")
	stdio := flag.Bool("stdio", false, "use stdio; only for an explicitly scoped local process")
	flag.Parse()
	if *backendURL == "" {
		log.Fatal("SYLULIVE_INTERNAL_URL or -backend is required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client := &http.Client{Timeout: 30 * time.Second}
	err := mcpserver.Run(ctx, mcpserver.HTTPBackend{BaseURL: *backendURL, Client: client}, *addr, *stdio)
	if err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

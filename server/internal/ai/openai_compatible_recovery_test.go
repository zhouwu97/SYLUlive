package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestOpenAICompatibleProviderRecoversEmptyStream(t *testing.T) {
	for _, stallHeaders := range []bool{false, true} {
		t.Run(fmt.Sprint(stallHeaders), func(t *testing.T) {
			var attempts atomic.Int32
			firstClosed := make(chan struct{})
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
				if attempts.Add(1) == 1 {
					if !stallHeaders {
						w.Header().Set("Content-Type", "text/event-stream")
						fmt.Fprint(w, ": keepalive\n\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n")
						w.(http.Flusher).Flush()
					}
					<-r.Context().Done()
					close(firstClosed)
					return
				}
				fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n")
			}))
			defer server.Close()
			provider, _ := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-luna", "medium", server.Client())
			provider.firstProgressTimeout = 100 * time.Millisecond
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			stream, err := provider.Start(ctx, ProviderRequest{})
			if err != nil {
				t.Fatal(err)
			}
			defer stream.Close()
			event, err := stream.Next(ctx)
			if err != nil || event.Text != "你好" || attempts.Load() != 2 {
				t.Fatalf("event=%+v err=%v attempts=%d", event, err, attempts.Load())
			}
			if done, err := stream.Next(ctx); err != nil || done.Type != ProviderEventCompleted {
				t.Fatalf("done=%+v err=%v", done, err)
			}
			select {
			case <-firstClosed:
			case <-ctx.Done():
				t.Fatal("重试前必须取消旧连接")
			}
		})
	}
}

func TestOpenAICompatibleProviderRecoveryIsBoundedAndRespectsCancellation(t *testing.T) {
	for _, cancelled := range []bool{false, true} {
		t.Run(fmt.Sprint(cancelled), func(t *testing.T) {
			var attempts atomic.Int32
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
				attempts.Add(1)
				fmt.Fprint(w, ": keepalive\n\n")
				w.(http.Flusher).Flush()
				if cancelled {
					cancel()
				}
				<-r.Context().Done()
			}))
			defer server.Close()
			provider, _ := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-luna", "medium", server.Client())
			provider.firstProgressTimeout = 100 * time.Millisecond
			_, err := provider.Start(ctx, ProviderRequest{})
			wantClass, wantAttempts := ProviderErrorTimeout, int32(2)
			if cancelled {
				wantClass, wantAttempts = ProviderErrorCancelled, 1
			}
			if providerErrorClass(err) != wantClass || attempts.Load() != wantAttempts {
				t.Fatalf("err=%v attempts=%d", err, attempts.Load())
			}
		})
	}
}

func TestOpenAICompatibleProviderDoesNotRetryModelProgress(t *testing.T) {
	for _, delta := range []string{`"content":"部分回答"`, `"reasoning_content":"私有思考"`, `"tool_calls":[{"index":0,"id":"call1","function":{"name":"lookup","arguments":"{"}}]`} {
		t.Run(delta, func(t *testing.T) {
			var attempts atomic.Int32
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = io.Copy(io.Discard, r.Body)
				attempts.Add(1)
				fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{%s}}]}\n\n", delta)
				w.(http.Flusher).Flush()
				<-r.Context().Done()
			}))
			defer server.Close()
			provider, _ := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-luna", "medium", server.Client())
			provider.firstProgressTimeout = 100 * time.Millisecond
			ctx, cancel := context.WithTimeout(context.Background(), 350*time.Millisecond)
			defer cancel()
			started := time.Now()
			stream, err := provider.Start(ctx, ProviderRequest{})
			if err == nil {
				defer stream.Close()
				for err == nil {
					var event ProviderEvent
					event, err = stream.Next(ctx)
					if strings.Contains(event.Text, "私有思考") {
						t.Fatal("思考内容不得泄露")
					}
				}
			}
			if providerErrorClass(err) != ProviderErrorTimeout || attempts.Load() != 1 || time.Since(started) < 250*time.Millisecond {
				t.Fatalf("err=%v attempts=%d elapsed=%v", err, attempts.Load(), time.Since(started))
			}
		})
	}
}

func TestOpenAICompatibleProviderRejectsInStreamError(t *testing.T) {
	var attempts atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		attempts.Add(1)
		fmt.Fprint(w, "data: {\"error\":{\"type\":\"model_not_found\",\"message\":\"secret-details\"}}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	provider, _ := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-luna", "medium", server.Client())
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := provider.Start(ctx, ProviderRequest{})
	if providerErrorClass(err) != ProviderErrorModelUnavailable || strings.Contains(fmt.Sprint(err), "secret") || attempts.Load() != 1 || ctx.Err() != nil {
		t.Fatalf("err=%v attempts=%d ctx=%v", err, attempts.Load(), ctx.Err())
	}
}

func TestOpenAICompatibleProviderFallbackPreservesRequestAndSelectedModel(t *testing.T) {
	var attempts atomic.Int32
	requests := make(chan map[string]json.RawMessage, 4)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]json.RawMessage
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
			return
		}
		requests <- body
		if attempts.Add(1) == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"OK\"}}]}\n\ndata: [DONE]\n\n")
	}))
	defer server.Close()
	provider, _ := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-terra", "medium", server.Client(), WithOpenAICompatibleFallbackModel("gpt-5.6-luna"))
	request := ProviderRequest{Messages: []Message{{Role: "user", Content: "读取已授权数据"}}, RequiredTool: "lookup", Tools: []ToolDefinition{{Name: "lookup", Parameters: map[string]interface{}{"type": "object"}}}}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stream, err := provider.Start(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	first, second := <-requests, <-requests
	if string(first["model"]) != `"gpt-5.6-terra"` || string(second["model"]) != `"gpt-5.6-luna"` {
		t.Fatal("主备模型顺序错误")
	}
	delete(first, "model")
	delete(second, "model")
	firstJSON, _ := json.Marshal(first)
	secondJSON, _ := json.Marshal(second)
	if string(firstJSON) != string(secondJSON) {
		t.Fatal("切换模型不得改变思考深度、工具约束或消息")
	}
	if event, err := stream.Next(ctx); err != nil || event.Text != "OK" || event.Model != "gpt-5.6-luna" {
		t.Fatalf("event=%+v err=%v", event, err)
	}
	for _, model := range []string{"gpt-5.6-luna", "unconfigured-model"} {
		request.Model = model
		stream, err := provider.Start(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		_ = stream.Close()
		body := <-requests
		want := `"gpt-5.6-luna"`
		if model == "unconfigured-model" {
			want = `"gpt-5.6-terra"`
		}
		if string(body["model"]) != want {
			t.Fatalf("model=%s want=%s", body["model"], want)
		}
	}
}

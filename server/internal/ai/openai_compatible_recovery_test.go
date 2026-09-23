package ai

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

// manualProgressTimer 是测试用的首进度看门狗：Stop 与触发时机都由用例自己决定，
// 因此「看门狗与模型进度同时到达」可以被稳定复现，而不是指望一个很窄的真实时间窗口。
type manualProgressTimer struct {
	onStop func()
}

func (t manualProgressTimer) Stop() bool {
	if t.onStop != nil {
		t.onStop()
	}
	return true
}

// TestOpenAICompatibleProviderDoesNotRetryModelProgress 断言两条不变量：
//
//  1. 模型进度一出现就必须撤下首进度看门狗，之后不得再因「没进度」掐断这条流；
//  2. 就算看门狗回调已经排队、在进度之后才执行（定时器与进度并发时的真实时序），
//     进度守卫也必须拦住第二次请求，绝不把已经出字的回答重新生成一遍。
//
// 旧写法用 elapsed >= 250ms 这类真实时间窗口表达上面两条，CI 上和调度一赛跑就时红时绿。
// 这里改成手动看门狗 + 显式事件顺序，断言只依赖状态，不依赖时钟。
func TestOpenAICompatibleProviderDoesNotRetryModelProgress(t *testing.T) {
	for _, delta := range []string{
		`"content":"partial answer"`,
		`"reasoning_content":"private thinking"`,
		`"tool_calls":[{"index":0,"id":"call1","function":{"name":"lookup","arguments":"{"}}]`,
	} {
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
			provider, err := NewOpenAICompatibleProvider(server.URL, "key", "gpt-5.6-luna", "medium", server.Client())
			if err != nil {
				t.Fatal(err)
			}
			provider.firstProgressTimeout = 20 * time.Millisecond

			// 看门狗被撤下（onProgress -> Stop）就是「provider 已经观察到模型进度」的信号。
			disarmed := make(chan struct{})
			var disarmOnce sync.Once
			var fire func()
			provider.afterFunc = func(_ time.Duration, onFire func()) providerTimer {
				fire = onFire
				return manualProgressTimer{onStop: func() { disarmOnce.Do(func() { close(disarmed) }) }}
			}

			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			type startResult struct {
				stream ProviderStream
				err    error
			}
			done := make(chan startResult, 1)
			go func() {
				stream, err := provider.Start(ctx, ProviderRequest{})
				done <- startResult{stream: stream, err: err}
			}()

			select {
			case <-disarmed:
			case <-time.After(10 * time.Second):
				t.Fatal("模型进度未在预算内到达，看门狗没有被撤下")
			}

			// 进度之后再补一次看门狗触发，复现「定时器已经排队、Stop 没拦住」的迟到取消。
			if fire == nil {
				t.Fatal("看门狗未被装配")
			}
			fire()

			res := <-done
			if res.err == nil {
				defer res.stream.Close()
				for {
					event, err := res.stream.Next(ctx)
					if strings.Contains(event.Text, "private thinking") {
						t.Fatal("思考内容不得泄露")
					}
					if err != nil {
						if providerErrorClass(err) != ProviderErrorTimeout {
							t.Fatalf("迟到看门狗应按超时收口: err=%v class=%s", err, providerErrorClass(err))
						}
						break
					}
				}
			} else {
				if providerErrorClass(res.err) != ProviderErrorTimeout {
					t.Fatalf("err=%v class=%s", res.err, providerErrorClass(res.err))
				}
			}
			if got := attempts.Load(); got != 1 {
				t.Fatalf("已经出现模型进度却发起了 %d 次请求", got)
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
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
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

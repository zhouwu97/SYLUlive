package ai

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestPythonScheduleCacheReaderContract(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/edu/courses/local" || r.URL.Query().Get("year") != "2026" || r.URL.Query().Get("semester") != "3" {
			t.Fatalf("缓存查询参数错误: %s", r.URL.String())
		}
		if r.Header.Get("X-Internal-Service-Token") != "service-secret" || r.Header.Get("X-Internal-User-ID") != "18" {
			t.Fatal("缺少可信服务身份或用户身份")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"courses":[{"id":1,"course_code":"abc","original_name":"高等数学","teacher":"张老师","location":"A101","weekday":1,"start_section":1,"end_section":2,"weeks":[1,2],"year":"2026","semester":3,"class_duration":45,"break_duration":10}]}`))
	}))
	defer server.Close()

	reader, err := NewPythonScheduleCacheReader(server.URL, "service-secret", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	courses, err := reader.Read(context.Background(), 18, "2026-2027", 3)
	if err != nil {
		t.Fatal(err)
	}
	if len(courses) != 1 || courses[0].OriginalName != "高等数学" {
		t.Fatalf("课表缓存契约解析失败: %#v", courses)
	}
}

func TestPythonScheduleCacheReaderContextCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()
	reader, err := NewPythonScheduleCacheReader(server.URL, "service-secret", server.Client())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err = reader.Read(ctx, 18, "2026-2027", 12)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("应透传 Context 取消，实际为 %v", err)
	}
}

func TestPythonScheduleCacheReaderRejectsUnmappedSemester(t *testing.T) {
	reader, err := NewPythonScheduleCacheReader("http://python-edu-service:8000", "service-secret", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reader.Read(context.Background(), 18, "2026-2027", 1); err == nil {
		t.Fatal("课表缓存只允许教务协议中的 3 或 12")
	}
}

package clients

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"shenliyuan/internal/academic"
)

func TestEduClientFetchContextBundleUsesInternalIdentityOnly(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodPost || request.URL.Path != "/api/edu/context-bundle" {
			t.Fatalf("unexpected request: %s %s", request.Method, request.URL.Path)
		}
		if request.Header.Get("X-Internal-Service-Token") != "internal-token" {
			t.Fatal("missing internal service token")
		}
		if request.Header.Get("X-Internal-User-ID") != "42" {
			t.Fatal("missing internal user identity")
		}
		if request.Header.Get("X-Request-ID") == "" {
			t.Fatal("missing request ID")
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(body), "user_id") {
			t.Fatalf("request body must not contain user_id: %s", body)
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"results":{"grades:2025-2026:3":{"status":"success","data":{"grades":[]}}},"partial":false}`))
	}))
	defer server.Close()

	client := NewEduClient(EduClientOptions{
		BaseURL: func() string { return server.URL },
		Token:   func() string { return "internal-token" },
		HTTP:    server.Client(),
	})
	bundle, err := client.FetchContextBundle(context.Background(), 42, []EduContextDataset{{
		Type: academic.DatasetGrades, Year: "2025-2026", Semester: 3,
	}})
	if err != nil {
		t.Fatalf("FetchContextBundle() error = %v", err)
	}
	item, ok := bundle.Results["grades:2025-2026:3"]
	if !ok || item.Status != "success" || string(item.Data) != `{"grades":[]}` {
		t.Fatalf("unexpected bundle: %#v", bundle)
	}
}

func TestEduClientRejectsUnsupportedDatasetBeforeRequest(t *testing.T) {
	client := NewEduClient(EduClientOptions{
		BaseURL: func() string { return "http://example.invalid" },
		Token:   func() string { return "internal-token" },
	})
	_, err := client.FetchContextBundle(context.Background(), 1, []EduContextDataset{{Type: academic.DatasetErke}})
	if err == nil {
		t.Fatal("expected unsupported dataset error")
	}
}

package services

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"shenliyuan/internal/models"
)

func TestExamPaperRemoteClientSignedFileURLBindsPaperAndPurpose(t *testing.T) {
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	signer, err := NewExamPaperStorageSigner("remote-client-secret", func() time.Time { return now })
	require.NoError(t, err)
	client, err := NewExamPaperRemoteClient("https://sylulive.online", signer, nil, func() time.Time { return now })
	require.NoError(t, err)
	paper := models.ExamPaper{ID: 42, FileKey: "paper 42.pdf", StorageBackend: models.ExamPaperStorageRemote}

	signedURL, err := client.SignedFileURL(paper, ExamPaperStoragePurposeDownload, 2*time.Minute)
	require.NoError(t, err)
	parsed, err := url.Parse(signedURL)
	require.NoError(t, err)
	require.Equal(t, "sylulive.online", parsed.Host)
	require.Equal(t, "/v1/files/paper 42.pdf", parsed.Path)
	grant, err := signer.VerifyGrant(parsed.Query().Get("token"), ExamPaperStoragePurposeDownload, http.MethodGet, parsed.EscapedPath())
	require.NoError(t, err)
	require.Equal(t, paper.FileKey, grant.FileKey)
	require.Equal(t, paper.ID, grant.PaperID)
	require.Equal(t, now.Add(2*time.Minute).Unix(), grant.ExpiresAt)
}

func TestExamPaperRemoteClientRejectsUnsafeBaseURLAndFileKey(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("remote-client-secret", time.Now)
	require.NoError(t, err)
	for _, baseURL := range []string{"https://example.com/base", "https://example.com?next=x", "https://user@example.com", "file:///tmp"} {
		_, err := NewExamPaperRemoteClient(baseURL, signer, nil, time.Now)
		require.Error(t, err, baseURL)
	}
	client, err := NewExamPaperRemoteClient("https://sylulive.online", signer, nil, time.Now)
	require.NoError(t, err)
	for _, key := range []string{"../paper.pdf", `..\\paper.pdf`, "/paper.pdf", "", ".", ".."} {
		_, err := client.SignedFileURL(models.ExamPaper{ID: 1, FileKey: key}, ExamPaperStoragePurposePreview, time.Minute)
		require.Error(t, err, key)
	}
}

func TestExamPaperRemoteClientInternalOperationsUseScopedGrant(t *testing.T) {
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	signer, err := NewExamPaperStorageSigner("remote-client-secret", func() time.Time { return now })
	require.NoError(t, err)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		purpose := map[string]string{
			"/internal/v1/files/paper.pdf/claim": ExamPaperStoragePurposeClaim,
			"/internal/v1/files/paper.pdf/trash": ExamPaperStoragePurposeDelete,
			"/internal/v1/files/paper.pdf/meta":  ExamPaperStoragePurposeMetadata,
		}[r.URL.Path]
		require.NotEmpty(t, purpose)
		grant, verifyErr := signer.VerifyGrant(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "), purpose, r.Method, r.URL.EscapedPath())
		require.NoError(t, verifyErr)
		require.Equal(t, "paper.pdf", grant.FileKey)
		if purpose == ExamPaperStoragePurposeMetadata {
			_, _ = fmt.Fprint(w, `{"file_key":"paper.pdf","size":12,"sha256":"`+strings.Repeat("a", 64)+`"}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"status":"ok"}`)
	}))
	defer server.Close()
	client, err := NewExamPaperRemoteClient(server.URL, signer, server.Client(), func() time.Time { return now })
	require.NoError(t, err)

	require.NoError(t, client.Claim(context.Background(), "paper.pdf"))
	require.NoError(t, client.Trash(context.Background(), "paper.pdf"))
	metadata, err := client.Metadata(context.Background(), "paper.pdf")
	require.NoError(t, err)
	require.Equal(t, int64(12), metadata.Size)
}

func TestExamPaperRemoteClientRejectsBadStatusAndOversizedJSON(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("remote-client-secret", time.Now)
	require.NoError(t, err)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/meta") {
			_, _ = fmt.Fprint(w, strings.Repeat("x", examPaperRemoteResponseLimit+1))
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		_, _ = fmt.Fprint(w, `{"error":"upstream"}`)
	}))
	defer server.Close()
	client, err := NewExamPaperRemoteClient(server.URL, signer, server.Client(), time.Now)
	require.NoError(t, err)

	require.Error(t, client.Trash(context.Background(), "paper.pdf"))
	_, err = client.Metadata(context.Background(), "paper.pdf")
	require.Error(t, err)
}

func TestExamPaperRemoteClientDoesNotFollowInternalRedirects(t *testing.T) {
	signer, err := NewExamPaperStorageSigner("remote-client-secret", time.Now)
	require.NoError(t, err)
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.URL.Path == "/internal/v1/files/paper.pdf/trash" {
			http.Redirect(w, r, "/redirected", http.StatusFound)
			return
		}
		_, _ = fmt.Fprint(w, `{"status":"ok"}`)
	}))
	defer server.Close()
	client, err := NewExamPaperRemoteClient(server.URL, signer, server.Client(), time.Now)
	require.NoError(t, err)

	require.Error(t, client.Trash(context.Background(), "paper.pdf"))
	require.Equal(t, 1, requests)
}

package services

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/google/uuid"

	"shenliyuan/internal/models"
)

const (
	examPaperRemoteResponseLimit  = 64 * 1024
	examPaperRemoteRequestTimeout = 10 * time.Second
	examPaperRemoteGrantTTL       = time.Minute
)

var (
	ErrExamPaperRemoteInvalidURL      = errors.New("试卷远端存储地址无效")
	ErrExamPaperRemoteInvalidFileKey  = errors.New("试卷远端文件键无效")
	ErrExamPaperRemoteInvalidResponse = errors.New("试卷远端存储响应无效")
	ErrExamPaperRemoteNotFound        = errors.New("试卷远端文件不存在")
)

// ExamPaperRemoteMaintenanceResult 是文件服务维护接口返回的清理与磁盘统计。
type ExamPaperRemoteMaintenanceResult struct {
	UnclaimedFilesRemoved          int     `json:"unclaimed_files_removed"`
	PendingMarkersRemoved          int     `json:"pending_markers_removed"`
	TrashFilesRemoved              int     `json:"trash_files_removed"`
	TemporaryFilesRemoved          int     `json:"temporary_files_removed"`
	StaleUploadSessionsRemoved     int     `json:"stale_upload_sessions_removed"`
	CompletedUploadSessionsRemoved int     `json:"completed_upload_sessions_removed"`
	DiskUsagePercent               float64 `json:"disk_usage_percent"`
}

// ExamPaperRemoteClient 负责生成文件授权地址并调用文件服务内部接口。
type ExamPaperRemoteClient struct {
	baseURL *url.URL
	signer  *ExamPaperStorageSigner
	client  *http.Client
	now     func() time.Time
}

// NewExamPaperRemoteClient 创建限制在单一源站根路径的远端客户端。
func NewExamPaperRemoteClient(baseURL string, signer *ExamPaperStorageSigner, client *http.Client, now func() time.Time) (*ExamPaperRemoteClient, error) {
	parsed, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil || parsed.Scheme == "" || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") {
		return nil, ErrExamPaperRemoteInvalidURL
	}
	if parsed.Scheme != "https" && !(parsed.Scheme == "http" && (parsed.Hostname() == "127.0.0.1" || parsed.Hostname() == "localhost")) {
		return nil, ErrExamPaperRemoteInvalidURL
	}
	if signer == nil {
		return nil, ErrStorageSecretRequired
	}
	if client == nil {
		client = &http.Client{Timeout: examPaperRemoteRequestTimeout}
	} else {
		clientCopy := *client
		client = &clientCopy
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	if now == nil {
		now = time.Now
	}
	parsed.Path = ""
	return &ExamPaperRemoteClient{baseURL: parsed, signer: signer, client: client, now: now}, nil
}

// SignedFileURL 生成只允许指定试卷和用途使用的短时文件地址。
func (c *ExamPaperRemoteClient) SignedFileURL(paper models.ExamPaper, purpose string, ttl time.Duration) (string, error) {
	if c == nil || c.baseURL == nil || c.signer == nil || c.now == nil {
		return "", ErrExamPaperRemoteInvalidURL
	}
	if purpose != ExamPaperStoragePurposePreview && purpose != ExamPaperStoragePurposeDownload {
		return "", ErrStorageSignatureInvalid
	}
	if paper.ID == 0 || ttl <= 0 || !validExamPaperRemoteFileKey(paper.FileKey) {
		return "", ErrExamPaperRemoteInvalidFileKey
	}
	requestURL := c.endpoint("/v1/files/" + url.PathEscape(paper.FileKey))
	now := c.now()
	token, err := c.signer.SignGrant(ExamPaperStorageGrant{
		Purpose: purpose, FileKey: paper.FileKey, PaperID: paper.ID, Method: http.MethodGet,
		Path: requestURL.EscapedPath(), IssuedAt: now.Unix(), ExpiresAt: now.Add(ttl).Unix(), JTI: uuid.NewString(),
	})
	if err != nil {
		return "", fmt.Errorf("签发试卷文件授权失败: %w", err)
	}
	query := requestURL.Query()
	query.Set("token", token)
	requestURL.RawQuery = query.Encode()
	return requestURL.String(), nil
}

// Claim 幂等认领远端文件。
func (c *ExamPaperRemoteClient) Claim(ctx context.Context, fileKey string) error {
	return c.fileOperation(ctx, fileKey, ExamPaperStoragePurposeClaim, "claim")
}

// Trash 幂等将远端文件移入回收站。
func (c *ExamPaperRemoteClient) Trash(ctx context.Context, fileKey string) error {
	return c.fileOperation(ctx, fileKey, ExamPaperStoragePurposeDelete, "trash")
}

func (c *ExamPaperRemoteClient) fileOperation(ctx context.Context, fileKey, purpose, operation string) error {
	var response struct {
		Status string `json:"status"`
	}
	if err := c.doJSON(ctx, http.MethodPost, "/internal/v1/files/"+url.PathEscape(fileKey)+"/"+operation, purpose, fileKey, &response); err != nil {
		return err
	}
	if response.Status != "ok" {
		return ErrExamPaperRemoteInvalidResponse
	}
	return nil
}

// Metadata 读取远端文件元数据。
func (c *ExamPaperRemoteClient) Metadata(ctx context.Context, fileKey string) (StoredExamPaperFile, error) {
	var response struct {
		FileKey string `json:"file_key"`
		Size    int64  `json:"size"`
		SHA256  string `json:"sha256"`
	}
	if err := c.doJSON(ctx, http.MethodGet, "/internal/v1/files/"+url.PathEscape(fileKey)+"/meta", ExamPaperStoragePurposeMetadata, fileKey, &response); err != nil {
		return StoredExamPaperFile{}, err
	}
	if response.FileKey != fileKey || response.Size <= 0 || len(response.SHA256) != sha256.Size*2 {
		return StoredExamPaperFile{}, ErrExamPaperRemoteInvalidResponse
	}
	if _, err := hex.DecodeString(response.SHA256); err != nil {
		return StoredExamPaperFile{}, ErrExamPaperRemoteInvalidResponse
	}
	return StoredExamPaperFile{FileKey: response.FileKey, Size: response.Size, SHA256: response.SHA256}, nil
}

// Maintenance 触发文件服务清理并返回统计。
func (c *ExamPaperRemoteClient) Maintenance(ctx context.Context) (ExamPaperRemoteMaintenanceResult, error) {
	var result ExamPaperRemoteMaintenanceResult
	if err := c.doJSON(ctx, http.MethodPost, "/internal/v1/maintenance", ExamPaperStoragePurposeMaintenance, "", &result); err != nil {
		return ExamPaperRemoteMaintenanceResult{}, err
	}
	return result, nil
}

func (c *ExamPaperRemoteClient) doJSON(ctx context.Context, method, escapedPath, purpose, fileKey string, destination any) error {
	if fileKey != "" && !validExamPaperRemoteFileKey(fileKey) {
		return ErrExamPaperRemoteInvalidFileKey
	}
	requestURL := c.endpoint(escapedPath)
	now := c.now()
	token, err := c.signer.SignGrant(ExamPaperStorageGrant{
		Purpose: purpose, FileKey: fileKey, Method: method, Path: requestURL.EscapedPath(),
		IssuedAt: now.Unix(), ExpiresAt: now.Add(examPaperRemoteGrantTTL).Unix(), JTI: uuid.NewString(),
	})
	if err != nil {
		return fmt.Errorf("签发试卷内部授权失败: %w", err)
	}
	requestContext, cancel := context.WithTimeout(ctx, examPaperRemoteRequestTimeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestContext, method, requestURL.String(), nil)
	if err != nil {
		return fmt.Errorf("创建试卷远端请求失败: %w", err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("Accept", "application/json")
	response, err := c.client.Do(request)
	if err != nil {
		return fmt.Errorf("调用试卷远端存储失败: %w", err)
	}
	defer response.Body.Close()
	limited := io.LimitReader(response.Body, examPaperRemoteResponseLimit+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return fmt.Errorf("读取试卷远端响应失败: %w", err)
	}
	if len(body) > examPaperRemoteResponseLimit {
		return ErrExamPaperRemoteInvalidResponse
	}
	if response.StatusCode == http.StatusNotFound {
		return ErrExamPaperRemoteNotFound
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("%w: HTTP %d", ErrExamPaperRemoteInvalidResponse, response.StatusCode)
	}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrExamPaperRemoteInvalidResponse
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrExamPaperRemoteInvalidResponse
	}
	return nil
}

func (c *ExamPaperRemoteClient) endpoint(escapedPath string) *url.URL {
	result := *c.baseURL
	decodedPath, _ := url.PathUnescape(escapedPath)
	result.Path = decodedPath
	result.RawPath = escapedPath
	return &result
}

func validExamPaperRemoteFileKey(fileKey string) bool {
	return fileKey != "" && fileKey != "." && fileKey != ".." && path.Base(fileKey) == fileKey && !strings.ContainsAny(fileKey, `/\\`)
}

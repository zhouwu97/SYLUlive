// Package clients 提供 Go 服务访问内部教务服务的受控客户端。
package clients

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"shenliyuan/internal/academic"
	"shenliyuan/internal/middleware"
)

const maxEduResponseBytes = 1024 * 1024

// EduContextDataset 描述一次教务聚合请求中的一个数据集。
// 用户身份仅通过内部请求头传递，模型参数中不允许携带 user_id。
type EduContextDataset struct {
	Type     academic.DatasetType `json:"type"`
	Year     string               `json:"year,omitempty"`
	Semester int                  `json:"semester,omitempty"`
}

// Key 返回 Python 聚合接口和 Go 快照层共用的数据集键。
func (dataset EduContextDataset) Key() string {
	if dataset.Year == "" {
		return string(dataset.Type)
	}
	return fmt.Sprintf("%s:%s:%d", dataset.Type, dataset.Year, dataset.Semester)
}

// Validate 拒绝不属于教务远程抓取范围或缺少学期的请求。
func (dataset EduContextDataset) Validate() error {
	switch dataset.Type {
	case academic.DatasetGrades, academic.DatasetSchedule:
		if strings.TrimSpace(dataset.Year) == "" || (dataset.Semester != 3 && dataset.Semester != 12) {
			return fmt.Errorf("%s requires year and semester", dataset.Type)
		}
	case academic.DatasetAcademicSituation, academic.DatasetCreditRequirements:
		if dataset.Year != "" || dataset.Semester != 0 {
			return fmt.Errorf("%s does not accept term parameters", dataset.Type)
		}
	default:
		return fmt.Errorf("unsupported remote dataset: %s", dataset.Type)
	}
	return nil
}

// EduContextItem 是 Python 聚合接口返回的单个数据集结果。
type EduContextItem struct {
	Status    string          `json:"status"`
	Data      json.RawMessage `json:"data"`
	ErrorCode string          `json:"error_code,omitempty"`
	Message   string          `json:"message,omitempty"`
}

// EduContextBundle 是 Python 聚合接口的完整响应。
type EduContextBundle struct {
	Results map[string]EduContextItem `json:"results"`
	Partial bool                      `json:"partial"`
}

// EduServiceError 仅保留可公开的状态、错误码和请求 ID，绝不记录请求体或远端凭据。
type EduServiceError struct {
	StatusCode int
	Code       string
	Message    string
	RequestID  string
}

func (errorValue *EduServiceError) Error() string {
	if errorValue == nil {
		return "教务服务请求失败"
	}
	if errorValue.Code != "" {
		return fmt.Sprintf("教务服务请求失败: %s", errorValue.Code)
	}
	return "教务服务请求失败"
}

// EduClient 将 Go 到 Python 的调用集中在一个位置，统一超时、内部认证和请求 ID。
type EduClient struct {
	baseURL func() string
	token   func() string
	http    *http.Client
}

// EduClientOptions 支持测试和运行时配置更新；BaseURL 与 Token 在每次请求时读取。
type EduClientOptions struct {
	BaseURL func() string
	Token   func() string
	HTTP    *http.Client
}

// NewEduClient 创建内部教务客户端。调用方未传 HTTP 客户端时使用 45 秒硬超时。
func NewEduClient(options EduClientOptions) *EduClient {
	client := options.HTTP
	if client == nil {
		client = &http.Client{Timeout: 45 * time.Second}
	}
	return &EduClient{baseURL: options.BaseURL, token: options.Token, http: client}
}

// FetchContextBundle 调用 Python 聚合接口。请求中不序列化 user_id，身份只来自受控内部请求头。
func (client *EduClient) FetchContextBundle(ctx context.Context, userID uint, datasets []EduContextDataset) (EduContextBundle, error) {
	if client == nil || client.baseURL == nil || client.token == nil || client.http == nil {
		return EduContextBundle{}, errors.New("教务客户端未配置")
	}
	if userID == 0 || len(datasets) == 0 {
		return EduContextBundle{}, errors.New("教务聚合请求参数无效")
	}
	for _, dataset := range datasets {
		if err := dataset.Validate(); err != nil {
			return EduContextBundle{}, err
		}
	}
	baseURL := strings.TrimRight(strings.TrimSpace(client.baseURL()), "/")
	if baseURL == "" || strings.TrimSpace(client.token()) == "" {
		return EduContextBundle{}, errors.New("教务服务配置不完整")
	}
	payload, err := json.Marshal(struct {
		Datasets []EduContextDataset `json:"datasets"`
	}{Datasets: datasets})
	if err != nil {
		return EduContextBundle{}, fmt.Errorf("编码教务聚合请求失败: %w", err)
	}
	requestID := middleware.RequestIDFromContext(ctx)
	if requestID == "" {
		requestID = middleware.NewRequestID()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/api/edu/context-bundle", bytes.NewReader(payload))
	if err != nil {
		return EduContextBundle{}, fmt.Errorf("创建教务聚合请求失败: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Internal-Service-Token", client.token())
	request.Header.Set("X-Internal-User-ID", fmt.Sprintf("%d", userID))
	request.Header.Set("X-Request-ID", requestID)

	response, err := client.http.Do(request)
	if err != nil {
		return EduContextBundle{}, &EduServiceError{Code: "edu_unavailable", Message: "教务服务不可用", RequestID: requestID}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, maxEduResponseBytes+1))
	if err != nil {
		return EduContextBundle{}, &EduServiceError{StatusCode: response.StatusCode, Code: "edu_response_read_failed", Message: "读取教务服务响应失败", RequestID: requestID}
	}
	if len(body) > maxEduResponseBytes {
		return EduContextBundle{}, &EduServiceError{StatusCode: response.StatusCode, Code: "edu_response_too_large", Message: "教务服务响应过大", RequestID: requestID}
	}
	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		return EduContextBundle{}, newEduServiceError(response.StatusCode, body, requestID)
	}
	var bundle EduContextBundle
	if err := json.Unmarshal(body, &bundle); err != nil || bundle.Results == nil {
		return EduContextBundle{}, &EduServiceError{StatusCode: response.StatusCode, Code: "edu_invalid_response", Message: "教务服务返回了无效响应", RequestID: requestID}
	}
	return bundle, nil
}

func newEduServiceError(statusCode int, body []byte, requestID string) *EduServiceError {
	parsed := struct {
		Code    string          `json:"code"`
		Message string          `json:"message"`
		Error   string          `json:"error"`
		Detail  json.RawMessage `json:"detail"`
	}{}
	_ = json.Unmarshal(body, &parsed)
	if parsed.Message == "" {
		parsed.Message = parsed.Error
	}
	if len(parsed.Detail) > 0 {
		var detail struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		}
		if json.Unmarshal(parsed.Detail, &detail) == nil {
			if parsed.Code == "" {
				parsed.Code = detail.Code
			}
			if parsed.Message == "" {
				parsed.Message = detail.Message
			}
		}
	}
	if parsed.Code == "" {
		parsed.Code = fmt.Sprintf("edu_http_%d", statusCode)
	}
	if parsed.Message == "" {
		parsed.Message = "教务服务请求失败"
	}
	return &EduServiceError{StatusCode: statusCode, Code: parsed.Code, Message: parsed.Message, RequestID: requestID}
}

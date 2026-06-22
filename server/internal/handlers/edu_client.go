package handlers

import (
	"encoding/json"
	"fmt"
	"github.com/go-resty/resty/v2"
	"time"
)

// EduServiceClient 用于统一封装对 Python 教务服务的请求
type EduServiceClient struct {
	client      *resty.Client
	baseURL     string
	internalKey string
}

// NewEduServiceClient 创建新的客户端实例
func NewEduServiceClient() *EduServiceClient {
	client := resty.New()
	client.SetTimeout(30 * time.Second)
	// Inject internal key to all requests
	client.OnBeforeRequest(func(c *resty.Client, req *resty.Request) error {
		req.SetHeader("X-Internal-Service-Key", EduServiceConfig.InternalKey)
		return nil
	})
	return &EduServiceClient{
		client:      client,
		baseURL:     EduServiceConfig.BaseURL,
		internalKey: EduServiceConfig.InternalKey,
	}
}

// Post 发送 POST 请求到 Python 服务
func (c *EduServiceClient) Post(path string, body interface{}) (*resty.Response, error) {
	return c.client.R().
		SetHeader("Content-Type", "application/json").
		SetBody(body).
		Post(c.baseURL + path)
}

// Get 发送 GET 请求到 Python 服务
func (c *EduServiceClient) Get(path string) (*resty.Response, error) {
	return c.client.R().
		Get(c.baseURL + path)
}

// Delete 发送 DELETE 请求到 Python 服务
func (c *EduServiceClient) Delete(path string, queryParams map[string]string) (*resty.Response, error) {
	return c.client.R().
		SetQueryParams(queryParams).
		Delete(c.baseURL + path)
}

// ExtractError 统一解析 Python 服务返回的错误信息
func ExtractError(resp *resty.Response) string {
	var errResp struct {
		Detail  interface{} `json:"detail"`
		Error   string      `json:"error"`
		Message string      `json:"message"`
	}
	_ = json.Unmarshal(resp.Body(), &errResp)
	if errResp.Message != "" {
		return errResp.Message
	}
	if errResp.Error != "" {
		return errResp.Error
	}
	switch detail := errResp.Detail.(type) {
	case string:
		if detail != "" {
			return detail
		}
	case map[string]interface{}:
		if msg, ok := detail["message"].(string); ok && msg != "" {
			return msg
		}
		if code, ok := detail["code"].(string); ok && code != "" {
			return code
		}
	}
	return "教务服务异常"
}

func ExtractErrorCode(resp *resty.Response) string {
	var errResp struct {
		Code   string      `json:"code"`
		Detail interface{} `json:"detail"`
	}
	if err := json.Unmarshal(resp.Body(), &errResp); err != nil {
		return ""
	}
	if errResp.Code != "" {
		return errResp.Code
	}
	if detail, ok := errResp.Detail.(map[string]interface{}); ok {
		if code, ok := detail["code"].(string); ok {
			return code
		}
	}
	return ""
}

func ensureEduServiceSuccess(resp *resty.Response, err error, action string) error {
	if err != nil {
		return fmt.Errorf("%s失败: %w", action, err)
	}
	if resp == nil {
		return fmt.Errorf("%s失败: 教务服务无响应", action)
	}
	if !resp.IsSuccess() {
		return fmt.Errorf("%s失败: %s", action, ExtractError(resp))
	}

	var res struct {
		Success *bool  `json:"success"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(resp.Body(), &res); err != nil {
		return fmt.Errorf("%s失败: 解析教务服务响应失败", action)
	}
	if res.Success != nil && !*res.Success {
		if res.Message == "" {
			res.Message = "教务服务返回失败"
		}
		return fmt.Errorf("%s失败: %s", action, res.Message)
	}
	return nil
}

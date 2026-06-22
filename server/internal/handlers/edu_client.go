package handlers

import (
	"encoding/json"
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

// Delete 发送 DELETE 请求到 Python 服务
func (c *EduServiceClient) Delete(path string, queryParams map[string]string) (*resty.Response, error) {
	return c.client.R().
		SetQueryParams(queryParams).
		Delete(c.baseURL + path)
}

// ExtractError 统一解析 Python 服务返回的错误信息
func ExtractError(resp *resty.Response) string {
	var errResp struct {
		Detail string `json:"detail"`
		Error  string `json:"error"`
		Message string `json:"message"`
	}
	_ = json.Unmarshal(resp.Body(), &errResp)
	if errResp.Detail != "" {
		return errResp.Detail
	}
	if errResp.Error != "" {
		return errResp.Error
	}
	if errResp.Message != "" {
		return errResp.Message
	}
	return "教务服务异常"
}

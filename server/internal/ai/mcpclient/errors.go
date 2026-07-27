package mcpclient

import (
	"errors"
	"fmt"
)

const (
	ErrorDisabled      = "external_mcp_disabled"
	ErrorUnavailable   = "external_mcp_unavailable"
	ErrorTimeout       = "external_mcp_timeout"
	ErrorProtocol      = "external_mcp_protocol_error"
	ErrorToolMissing   = "external_mcp_tool_missing"
	ErrorInvalidResult = "external_mcp_invalid_result"
	ErrorConstraint    = "external_mcp_constraint_violation"
)

// Error 保留对调用方稳定的错误码，并通过 Unwrap 保留内部诊断原因。
// Error 文本不会包含请求载荷、个人数据或远端返回正文。
type Error struct {
	Code string
	Err  error
}

func (value *Error) Error() string {
	if value == nil || value.Code == "" {
		return ErrorUnavailable
	}
	return value.Code
}

func (value *Error) Unwrap() error {
	if value == nil {
		return nil
	}
	return value.Err
}

func newError(code string, err error) error {
	if err == nil {
		err = errors.New(code)
	}
	return &Error{Code: code, Err: err}
}

// ErrorCode 将任意内部错误映射为可安全返回模型的稳定错误码。
func ErrorCode(err error) string {
	var typed *Error
	if errors.As(err, &typed) && typed != nil && typed.Code != "" {
		return typed.Code
	}
	return ErrorUnavailable
}

func wrapError(code string, format string, arguments ...interface{}) error {
	return newError(code, fmt.Errorf(format, arguments...))
}

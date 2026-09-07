package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"

	"shenliyuan/internal/models"
)

// undergraduateAcademicIdentityProvider 复用本科服务的非持久化 pre_verify 路径。
// 旧 Python BindResponse 的 student_id 是请求回显，不能作为可信身份字段；
// 只有新增的 school_verified_student_id 与请求学号一致时才允许写入新绑定表。
type undergraduateAcademicIdentityProvider struct{}

type undergraduatePreVerifyResponse struct {
	Success                 bool   `json:"success"`
	Message                 string `json:"message"`
	Code                    string `json:"code"`
	StudentID               string `json:"student_id"`
	SchoolVerifiedStudentID string `json:"school_verified_student_id"`
	Name                    string `json:"name"`
}

func (undergraduateAcademicIdentityProvider) ProviderID() models.AcademicProviderID {
	return models.AcademicProviderUndergraduate
}

func (undergraduateAcademicIdentityProvider) PrepareChallenge(context.Context, uint, string) (AcademicProviderChallenge, error) {
	return AcademicProviderChallenge{Required: false, Type: "pre_verify"}, nil
}

func (undergraduateAcademicIdentityProvider) Verify(_ context.Context, request AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error) {
	if request.ProviderID != models.AcademicProviderUndergraduate || request.StudentID == "" || strings.TrimSpace(request.Password) == "" {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	response, err := pythonEduRequest(http.MethodPost, "/api/edu/pre_verify", nil, map[string]string{
		"student_id": request.StudentID,
		"password":   request.Password,
	})
	if err != nil {
		slog.Warn("本科教务 Provider 请求失败", "stage", "preverify_transport")
		return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
	}
	var result undergraduatePreVerifyResponse
	if err := json.Unmarshal(response.Body(), &result); err != nil {
		slog.Warn("本科教务 Provider 响应解析失败", "stage", "preverify_decode", "status", response.StatusCode())
		return AcademicVerifiedProfile{}, ErrAcademicProviderUnavailable
	}
	if response.StatusCode() != http.StatusOK || !result.Success {
		slog.Warn("本科教务 Provider 身份未通过", "stage", "preverify_reject", "status", response.StatusCode(), "code", undergraduateDiagnosticCode(result.Code), "success", result.Success)
		return AcademicVerifiedProfile{}, classifyAcademicIdentityFailure(response.StatusCode(), result.Code, result.Message)
	}
	verifiedStudentID := strings.TrimSpace(result.SchoolVerifiedStudentID)
	if verifiedStudentID == "" {
		slog.Warn("本科教务 Provider 未返回学校学号", "stage", "profile_unverified", "status", response.StatusCode())
		return AcademicVerifiedProfile{}, ErrAcademicIdentityUnverified
	}
	if verifiedStudentID != request.StudentID {
		slog.Warn("本科教务 Provider 学号不匹配", "stage", "profile_mismatch", "status", response.StatusCode())
		return AcademicVerifiedProfile{}, ErrAcademicIdentityMismatch
	}
	return AcademicVerifiedProfile{
		ProviderID: models.AcademicProviderUndergraduate,
		StudentID:  verifiedStudentID,
		Name:       strings.TrimSpace(result.Name),
	}, nil
}

func undergraduateDiagnosticCode(code string) string {
	switch strings.ToUpper(strings.TrimSpace(code)) {
	case "EDU_IDENTITY_UNVERIFIED", "EDU_IDENTITY_MISMATCH", "CAPTCHA_INVALID", "INVALID_CAPTCHA", "CAPTCHA_ERROR", "VERIFICATION_CODE_INVALID", "VERIFICATION_CODE_ERROR", "PASSWORD_INVALID", "INVALID_PASSWORD", "PASSWORD_INCORRECT", "PASSWORD_ERROR", "INVALID_CREDENTIALS", "ACCOUNT_NOT_FOUND", "ACCOUNT_UNKNOWN", "USER_NOT_FOUND", "ACCOUNT_LOCKED", "ACCOUNT_DISABLED", "ACCOUNT_RESTRICTED", "NOT_ENROLLED", "RATE_LIMITED", "TOO_MANY_REQUESTS", "CSRF_MISSING", "PUBLIC_KEY_PARSE_ERROR", "CAS_FLOW_CHANGED", "SESSION_COOKIE_MISSING", "UNKNOWN_LOGIN_STATE", "REMOTE_SYSTEM_UNAVAILABLE":
		return strings.ToUpper(strings.TrimSpace(code))
	default:
		return "OTHER"
	}
}

func parseUndergraduatePreVerifyResponse(body []byte) (undergraduatePreVerifyResponse, error) {
	var result undergraduatePreVerifyResponse
	if err := json.Unmarshal(body, &result); err != nil {
		return result, err
	}
	if !result.Success {
		return result, errors.New("本科教务验证未通过")
	}
	if strings.TrimSpace(result.SchoolVerifiedStudentID) == "" {
		return result, ErrAcademicIdentityUnverified
	}
	return result, nil
}

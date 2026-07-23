package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"shenliyuan/internal/services"
)

// PythonEduBindingRecoveryRemote 为后台恢复任务读取 Python 已落库的教务绑定状态。
type PythonEduBindingRecoveryRemote struct{}

func (PythonEduBindingRecoveryRemote) Status(ctx context.Context, userID uint) (services.EduBindingRecoveryStatus, error) {
	if err := ctx.Err(); err != nil {
		return services.EduBindingRecoveryStatus{}, err
	}
	resp, err := pythonEduRequest(http.MethodGet, "/api/edu/status", &userID, nil)
	if err != nil {
		return services.EduBindingRecoveryStatus{}, err
	}
	if resp.StatusCode() != http.StatusOK {
		return services.EduBindingRecoveryStatus{}, errors.New("读取教务绑定恢复状态失败")
	}
	var status eduStatusResult
	if err := json.Unmarshal(resp.Body(), &status); err != nil {
		return services.EduBindingRecoveryStatus{}, err
	}
	return services.EduBindingRecoveryStatus{
		Authorized: status.Authorized || status.Bound, CredentialGeneration: status.CredentialGeneration,
		StudentID: status.StudentID, Grade: status.Grade, College: status.College, Major: status.Major,
	}, ctx.Err()
}

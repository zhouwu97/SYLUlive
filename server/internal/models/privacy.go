package models

import (
	"time"

	"gorm.io/gorm"
)

const (
	// LegalDocumentVersion 在每次调整告知内容时递增，避免将不同版本的同意混在一起。
	LegalDocumentVersion = "2026-09-03-r1"

	LegalDocumentUserAgreement    = "user_agreement"
	LegalDocumentPrivacyPolicy    = "privacy_policy"
	LegalDocumentCommunityRules   = "community_rules"
	LegalDocumentMinorProtection  = "minor_protection"
	LegalDocumentEduDataConsent   = "edu_data_consent"
	LegalDocumentSDKDisclosure    = "sdk_disclosure"
	LegalDocumentContentComplaint = "content_complaint_rules"
)

// UserLegalConsent 保存用户对每一份法律文件版本的明确同意，不保存密码或设备标识。
type UserLegalConsent struct {
	ID                  uint       `gorm:"primaryKey" json:"id"`
	UserID              uint       `gorm:"not null;uniqueIndex:idx_user_legal_document_version_scene" json:"user_id"`
	Document            string     `gorm:"size:64;not null;uniqueIndex:idx_user_legal_document_version_scene" json:"document"`
	Version             string     `gorm:"size:32;not null;uniqueIndex:idx_user_legal_document_version_scene" json:"version"`
	AcceptedAt          time.Time  `gorm:"not null" json:"accepted_at"`
	RevokedAt           *time.Time `gorm:"index" json:"revoked_at,omitempty"`
	AcknowledgementType string     `gorm:"size:32;default:'separate_consent'" json:"acknowledgement_type"`
	Scope               string     `gorm:"size:64" json:"scope,omitempty"`
	Scene               string     `gorm:"size:64;not null;default:'registration';uniqueIndex:idx_user_legal_document_version_scene" json:"scene,omitempty"`
}

// LegalConsentState 区分正常授权、需确认新版协议和主动撤销，避免客户端猜测状态。
type LegalConsentState string

const (
	LegalConsentStateActive   LegalConsentState = "active"
	LegalConsentStateRequired LegalConsentState = "required"
	LegalConsentStateRevoked  LegalConsentState = "revoked"
)

// RequiredLegalDocuments 返回当前账号类型必须确认的法律文件。
func RequiredLegalDocuments(includeEduConsent bool) []string {
	documents := []string{
		LegalDocumentUserAgreement,
		LegalDocumentPrivacyPolicy,
	}
	if includeEduConsent {
		documents = append(documents, LegalDocumentEduDataConsent)
	}
	return documents
}

// FunctionalLegalDocuments 描述需要在具体写操作前单独确认的文件，不参与基础登录门禁。
func FunctionalLegalDocuments() []string {
	return []string{LegalDocumentCommunityRules, LegalDocumentContentComplaint, LegalDocumentSDKDisclosure}
}

// LegalConsentStateForUser 以当前版本的有效授权记录作为服务端唯一真值。
func LegalConsentStateForUser(db *gorm.DB, user User) (LegalConsentState, error) {
	if user.LegalConsentRevokedAt != nil {
		return LegalConsentStateRevoked, nil
	}

	documents := RequiredLegalDocuments(user.IsEduAuthorized())
	var acceptedCount int64
	if err := db.Model(&UserLegalConsent{}).
		Where("user_id = ? AND version = ? AND revoked_at IS NULL AND document IN ?", user.ID, LegalDocumentVersion, documents).
		Distinct("document").
		Count(&acceptedCount).Error; err != nil {
		return "", err
	}
	if acceptedCount != int64(len(documents)) {
		return LegalConsentStateRequired, nil
	}
	return LegalConsentStateActive, nil
}

type PersonalDataRequestType string

const (
	PersonalDataRequestAccess           PersonalDataRequestType = "access"
	PersonalDataRequestCorrection       PersonalDataRequestType = "correction"
	PersonalDataRequestExport           PersonalDataRequestType = "export"
	PersonalDataRequestDeletion         PersonalDataRequestType = "deletion"
	PersonalDataRequestWithdrawConsent  PersonalDataRequestType = "withdraw_consent"
	PersonalDataRequestAccountCancelled PersonalDataRequestType = "account_cancellation"
)

type PersonalDataRequestStatus string

const (
	PersonalDataRequestPending    PersonalDataRequestStatus = "pending"
	PersonalDataRequestProcessing PersonalDataRequestStatus = "processing"
	PersonalDataRequestCompleted  PersonalDataRequestStatus = "completed"
	PersonalDataRequestRejected   PersonalDataRequestStatus = "rejected"
)

// PersonalDataRequest 记录个人信息权利请求及处理结论，构成用户可查询的处理闭环。
type PersonalDataRequest struct {
	ID          uint                      `gorm:"primaryKey" json:"id"`
	UserID      uint                      `gorm:"not null;index" json:"user_id"`
	RequestType PersonalDataRequestType   `gorm:"size:32;not null;index" json:"request_type"`
	Detail      string                    `gorm:"type:text" json:"detail"`
	Status      PersonalDataRequestStatus `gorm:"size:16;not null;default:'pending';index" json:"status"`
	Result      string                    `gorm:"type:text" json:"result"`
	HandlerID   *uint                     `gorm:"index" json:"handler_id,omitempty"`
	CreatedAt   time.Time                 `json:"created_at"`
	HandledAt   *time.Time                `json:"handled_at,omitempty"`
	User        User                      `gorm:"foreignKey:UserID" json:"user,omitempty"`
	Handler     *User                     `gorm:"foreignKey:HandlerID" json:"handler,omitempty"`
}

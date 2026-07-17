package models

import "time"

const (
	// LegalDocumentVersion 在每次调整告知内容时递增，避免将不同版本的同意混在一起。
	LegalDocumentVersion = "2026-07-18"

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
	ID         uint      `gorm:"primaryKey" json:"id"`
	UserID     uint      `gorm:"not null;uniqueIndex:idx_user_legal_document_version" json:"user_id"`
	Document   string    `gorm:"size:64;not null;uniqueIndex:idx_user_legal_document_version" json:"document"`
	Version    string    `gorm:"size:32;not null;uniqueIndex:idx_user_legal_document_version" json:"version"`
	AcceptedAt time.Time `gorm:"not null" json:"accepted_at"`
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

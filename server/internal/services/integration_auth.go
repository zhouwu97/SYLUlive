package services

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"gorm.io/gorm/logger"
	"shenliyuan/internal/models"
)

const IntegrationClientID = "sylulive-astrbot"
const IntegrationDeviceGrant = "urn:ietf:params:oauth:grant-type:device_code"
const IntegrationReadScope = "community:read"
const IntegrationProposeScope = "community:propose"
const IntegrationActionScope = "actions:read_own"
const IntegrationCheckInScope = "checkin:write"

type IntegrationError struct {
	Code   string
	Status int
}

func (e *IntegrationError) Error() string            { return e.Code }
func integrationError(code string, status int) error { return &IntegrationError{code, status} }

type IntegrationAuthService struct {
	DB  *gorm.DB
	Now func() time.Time
}

func NewIntegrationAuthService(db *gorm.DB) *IntegrationAuthService {
	// 数据库错误 SQL 可能包含完整草稿，集成流程只对外记录稳定错误码。
	return &IntegrationAuthService{DB: db.Session(&gorm.Session{Logger: logger.Discard}), Now: time.Now}
}

type IntegrationDeviceResponse struct {
	DeviceCode string `json:"device_code"`
	UserCode   string `json:"user_code"`
	ExpiresIn  int    `json:"expires_in"`
	Interval   int    `json:"interval"`
}
type IntegrationTokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	Scope        string `json:"scope"`
}
type IntegrationConsent struct {
	ID               string                     `json:"consent_id"`
	InstallationName string                     `json:"installation_name"`
	InstallationID   string                     `json:"installation_id"`
	UserCode         string                     `json:"user_code"`
	RequestedScopes  []string                   `json:"requested_scopes"`
	Nonce            string                     `json:"confirmation_nonce"`
	ExpiresAt        time.Time                  `json:"expires_at"`
	ExistingBinding  *models.IntegrationBinding `json:"existing_binding,omitempty"`
}

func integrationSecret(prefix string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(b), nil
}
func IntegrationSecretHash(raw string) string {
	v := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(v[:])
}
func integrationScopes(raw string) (string, error) {
	allowed := map[string]bool{"profile:read_minimal": true, IntegrationReadScope: true, "content:read_own_public": true, IntegrationProposeScope: true, IntegrationActionScope: true, IntegrationCheckInScope: true}
	set := map[string]bool{}
	for _, scope := range strings.Fields(raw) {
		if !allowed[scope] {
			return "", integrationError("invalid_scope", 400)
		}
		set[scope] = true
	}
	if len(set) == 0 {
		return "", integrationError("invalid_scope", 400)
	}
	if set[IntegrationProposeScope] && (!set[IntegrationReadScope] || !set[IntegrationActionScope]) {
		return "", integrationError("invalid_scope", 400)
	}
	items := make([]string, 0, len(set))
	for scope := range set {
		items = append(items, scope)
	}
	sort.Strings(items)
	return strings.Join(items, " "), nil
}
func IntegrationHasScope(binding models.IntegrationBinding, scope string) bool {
	for _, v := range strings.Fields(binding.Scopes) {
		if v == scope {
			return true
		}
	}
	return false
}

func (s *IntegrationAuthService) ownerTx(ctx context.Context, owner uint, fn func(*gorm.DB, models.User) error) error {
	if owner == 0 {
		return integrationError("authentication_required", 401)
	}
	release := AcquireContentWriteSerialLock(s.DB)
	defer release()
	return s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var user models.User
		if err := tx.Clauses(clause.Locking{Strength: "NO KEY UPDATE"}).First(&user, owner).Error; err != nil {
			return err
		}
		return fn(tx, user)
	})
}

// 只接受服务端当前可核验的身份；自报配置、旧投影与历史迁移不在集成准入中。
func (s *IntegrationAuthService) eligible(tx *gorm.DB, user models.User, expected *models.IntegrationBinding) (models.AcademicIdentityBinding, error) {
	var academic models.AcademicIdentityBinding
	if user.AccountStatus != "active" || user.LegalConsentRevokedAt != nil {
		return academic, integrationError("account_unavailable", 403)
	}
	state, err := models.LegalConsentStateForUser(tx, user)
	if err != nil {
		return academic, err
	}
	if state != models.LegalConsentStateActive {
		return academic, integrationError("legal_consent_required", 403)
	}
	query := tx.Where("user_id = ? AND verification_method = ? AND verification_version IN ? AND verified_at > ?", user.ID, models.AcademicVerificationMethodSchoolProfile, []string{"v1", "undergraduate-preverify-v1"}, time.Time{})
	if expected != nil {
		query = query.Where("id = ? AND binding_version = ?", expected.AcademicBindingID, expected.AcademicVersion)
	}
	if err := query.Order("id DESC").Take(&academic).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return academic, integrationError("academic_verification_required", 403)
		}
		return academic, err
	}
	return academic, nil
}
func (s *IntegrationAuthService) Eligible(ctx context.Context, owner uint) error {
	var user models.User
	if err := s.DB.WithContext(ctx).First(&user, owner).Error; err != nil {
		return err
	}
	_, err := s.eligible(s.DB.WithContext(ctx), user, nil)
	return err
}

func (s *IntegrationAuthService) CheckBinding(ctx context.Context, b models.IntegrationBinding) error {
	var current models.IntegrationBinding
	if err := s.DB.WithContext(ctx).Where("id = ? AND owner_id = ? AND epoch = ?", b.ID, b.OwnerID, b.Epoch).Take(&current).Error; err != nil {
		return integrationError("authorization_changed", 403)
	}
	var user models.User
	if err := s.DB.WithContext(ctx).First(&user, b.OwnerID).Error; err != nil {
		return err
	}
	return s.bindingValid(s.DB.WithContext(ctx), current, user)
}

// 标准客户端会在 device token 请求重发原始 scope；只能与设备请求相同，
// 最终凭证始终使用本人实际批准的 scope，不由此字段扩权。
func (s *IntegrationAuthService) ValidateDeviceScope(ctx context.Context, device, scope string) error {
	if scope == "" {
		return nil
	}
	canonical, err := integrationScopes(scope)
	if err != nil {
		return err
	}
	var request models.IntegrationDeviceRequest
	if err = s.DB.WithContext(ctx).Where("device_hash = ?", IntegrationSecretHash(device)).Take(&request).Error; err != nil {
		return integrationError("invalid_grant", 400)
	}
	if canonical != request.RequestedScopes {
		return integrationError("invalid_scope", 400)
	}
	return nil
}

func (s *IntegrationAuthService) RequestDevice(ctx context.Context, installationID, name, scopes string) (IntegrationDeviceResponse, error) {
	var result IntegrationDeviceResponse
	parsedID, err := uuid.Parse(installationID)
	if err != nil {
		return result, integrationError("invalid_request", 400)
	}
	installationID = parsedID.String()
	name = strings.TrimSpace(name)
	if name == "" || len([]rune(name)) > 80 || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return result, integrationError("invalid_request", 400)
	}
	canonical, err := integrationScopes(scopes)
	if err != nil {
		return result, err
	}
	secret, err := integrationSecret("sd_")
	if err != nil {
		return result, err
	}
	random := make([]byte, 8)
	if _, err = rand.Read(random); err != nil {
		return result, err
	}
	const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	for i := range random {
		random[i] = alphabet[int(random[i])%len(alphabet)]
	}
	code := string(random[:4]) + "-" + string(random[4:])
	now := s.Now()
	row := models.IntegrationDeviceRequest{ID: uuid.NewString(), DeviceHash: IntegrationSecretHash(secret), UserCodeHash: IntegrationSecretHash(code), InstallationID: installationID, InstallationName: name, RequestedScopes: canonical, State: "pending", ExpiresAt: now.Add(10 * time.Minute), NextPollAt: now.Add(5 * time.Second), PollInterval: 5, CreatedAt: now}
	if err = s.DB.WithContext(ctx).Create(&row).Error; err != nil {
		return result, err
	}
	return IntegrationDeviceResponse{secret, code, 600, 5}, nil
}

func normalizeIntegrationCode(code string) string {
	code = strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(code), "-", ""))
	if len(code) != 8 {
		return ""
	}
	return code[:4] + "-" + code[4:]
}
func (s *IntegrationAuthService) LookupConsent(ctx context.Context, owner uint, code string) (IntegrationConsent, error) {
	var result IntegrationConsent
	code = normalizeIntegrationCode(code)
	if code == "" {
		return result, integrationError("invalid_user_code", 422)
	}
	err := s.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		if _, err := s.eligible(tx, user, nil); err != nil {
			return err
		}
		var row models.IntegrationDeviceRequest
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("user_code_hash = ?", IntegrationSecretHash(code)).Take(&row).Error; err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return integrationError("invalid_user_code", 422)
			}
			return err
		}
		if row.State != "pending" || !row.ExpiresAt.After(s.Now()) {
			return integrationError("device_request_expired", 410)
		}
		if row.OwnerID != 0 && row.OwnerID != owner {
			return integrationError("device_request_conflict", 409)
		}
		nonce, err := integrationSecret("sc_")
		if err != nil {
			return err
		}
		if err = tx.Model(&row).Updates(map[string]interface{}{"owner_id": owner, "nonce_hash": IntegrationSecretHash(nonce)}).Error; err != nil {
			return err
		}
		result = IntegrationConsent{ID: row.ID, InstallationName: row.InstallationName, InstallationID: row.InstallationID, UserCode: code, RequestedScopes: strings.Fields(row.RequestedScopes), Nonce: nonce, ExpiresAt: row.ExpiresAt}
		var existing models.IntegrationBinding
		if err = tx.Where("owner_id = ? AND state = ?", owner, "active").Take(&existing).Error; err == nil {
			result.ExistingBinding = &existing
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		return nil
	})
	return result, err
}

type IntegrationConsentDecision struct {
	Allow            bool     `json:"allow"`
	Scopes           []string `json:"scopes"`
	Nonce            string   `json:"confirmation_nonce"`
	ReplaceBindingID string   `json:"replace_binding_id,omitempty"`
	ExpectedEpoch    uint     `json:"expected_epoch,omitempty"`
}

func (s *IntegrationAuthService) DecideConsent(ctx context.Context, owner uint, id string, input IntegrationConsentDecision) (models.IntegrationBinding, error) {
	var result models.IntegrationBinding
	err := s.ownerTx(ctx, owner, func(tx *gorm.DB, user models.User) error {
		var row models.IntegrationDeviceRequest
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("id = ? AND owner_id = ?", id, owner).Take(&row).Error; err != nil {
			return integrationError("consent_unavailable", 404)
		}
		if row.State != "pending" || !row.ExpiresAt.After(s.Now()) {
			return integrationError("device_request_expired", 410)
		}
		if row.NonceHash == "" || row.NonceHash != IntegrationSecretHash(input.Nonce) {
			return integrationError("confirmation_required", 403)
		}
		if !input.Allow {
			return tx.Model(&row).Updates(map[string]interface{}{"state": "denied", "nonce_hash": ""}).Error
		}
		academic, err := s.eligible(tx, user, nil)
		if err != nil {
			return err
		}
		scopes, err := integrationScopes(strings.Join(input.Scopes, " "))
		if err != nil {
			return err
		}
		requested := map[string]bool{}
		for _, scope := range strings.Fields(row.RequestedScopes) {
			requested[scope] = true
		}
		for _, scope := range strings.Fields(scopes) {
			if !requested[scope] {
				return integrationError("invalid_scope", 400)
			}
		}
		var existing models.IntegrationBinding
		err = tx.Clauses(clause.Locking{Strength: "UPDATE"}).Where("owner_id = ? AND state = ?", owner, "active").Take(&existing).Error
		if err == nil {
			if input.ReplaceBindingID != existing.ID || input.ExpectedEpoch != existing.Epoch {
				return integrationError("binding_conflict", 409)
			}
			if err = s.revokeTx(tx, existing); err != nil {
				return err
			}
		} else if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		} else if input.ReplaceBindingID != "" {
			return integrationError("binding_conflict", 409)
		}
		var other int64
		if err = tx.Model(&models.IntegrationBinding{}).Where("installation_id = ? AND state = ?", row.InstallationID, "active").Count(&other).Error; err != nil {
			return err
		}
		if other > 0 {
			return integrationError("installation_conflict", 409)
		}
		result = models.IntegrationBinding{ID: uuid.NewString(), OwnerID: owner, InstallationID: row.InstallationID, InstallationName: row.InstallationName, State: "active", Scopes: scopes, Epoch: 1, AcademicBindingID: academic.ID, AcademicVersion: academic.BindingVersion, TokenVersion: user.TokenVersion, CreatedAt: s.Now()}
		if err = tx.Create(&result).Error; err != nil {
			return err
		}
		if err = tx.Model(&row).Updates(map[string]interface{}{"state": "approved", "binding_id": result.ID, "nonce_hash": ""}).Error; err != nil {
			return err
		}
		return tx.Create(&models.IntegrationAudit{OwnerID: owner, BindingID: result.ID, Event: "authorized", CreatedAt: s.Now()}).Error
	})
	return result, err
}

func (s *IntegrationAuthService) revokeTx(tx *gorm.DB, b models.IntegrationBinding) error {
	now := s.Now()
	if err := tx.Model(&b).Updates(map[string]interface{}{"state": "revoked", "epoch": b.Epoch + 1, "revoked_at": now}).Error; err != nil {
		return err
	}
	if err := tx.Model(&models.IntegrationAction{}).Where("binding_id = ? AND state = ?", b.ID, "pending").Updates(map[string]interface{}{"state": "invalidated", "confirm_nonce_hash": "", "confirm_expires_at": nil, "payload": "{}"}).Error; err != nil {
		return err
	}
	return tx.Create(&models.IntegrationAudit{OwnerID: b.OwnerID, BindingID: b.ID, Event: "revoked", CreatedAt: now}).Error
}
func (s *IntegrationAuthService) Revoke(ctx context.Context, owner uint, id string) error {
	return s.ownerTx(ctx, owner, func(tx *gorm.DB, _ models.User) error {
		var b models.IntegrationBinding
		if err := tx.Where("id = ? AND owner_id = ?", id, owner).Take(&b).Error; err != nil {
			return integrationError("binding_unavailable", 404)
		}
		if b.State != "active" {
			return nil
		}
		return s.revokeTx(tx, b)
	})
}

func (s *IntegrationAuthService) bindingValid(tx *gorm.DB, b models.IntegrationBinding, user models.User) error {
	if b.State != "active" || b.TokenVersion != user.TokenVersion {
		return integrationError("invalid_token", 401)
	}
	_, err := s.eligible(tx, user, &b)
	return err
}
func (s *IntegrationAuthService) Authenticate(ctx context.Context, raw string) (models.IntegrationBinding, error) {
	var b models.IntegrationBinding
	if !strings.HasPrefix(raw, "sa_") || len(raw) > 128 {
		return b, integrationError("invalid_token", 401)
	}
	tx := s.DB.WithContext(ctx)
	var cred models.IntegrationCredential
	if err := tx.Where("token_hash = ? AND kind = ? AND expires_at > ?", IntegrationSecretHash(raw), "access", s.Now()).Take(&cred).Error; err != nil {
		return b, integrationError("invalid_token", 401)
	}
	if err := tx.First(&b, "id = ?", cred.BindingID).Error; err != nil || b.Epoch != cred.Epoch {
		return b, integrationError("invalid_token", 401)
	}
	var user models.User
	if err := tx.First(&user, b.OwnerID).Error; err != nil {
		return b, integrationError("invalid_token", 401)
	}
	return b, s.bindingValid(tx, b, user)
}

func (s *IntegrationAuthService) issueTokens(tx *gorm.DB, b models.IntegrationBinding, absolute time.Time) (IntegrationTokenResponse, error) {
	var result IntegrationTokenResponse
	access, err := integrationSecret("sa_")
	if err != nil {
		return result, err
	}
	refresh, err := integrationSecret("sr_")
	if err != nil {
		return result, err
	}
	now := s.Now()
	accessExpiry := now.Add(10 * time.Minute)
	refreshExpiry := now.Add(7 * 24 * time.Hour)
	if refreshExpiry.After(absolute) {
		refreshExpiry = absolute
	}
	if accessExpiry.After(absolute) {
		accessExpiry = absolute
	}
	rows := []models.IntegrationCredential{
		{ID: uuid.NewString(), BindingID: b.ID, TokenHash: IntegrationSecretHash(access), Kind: "access", Epoch: b.Epoch, ExpiresAt: accessExpiry, AbsoluteExpiresAt: absolute, CreatedAt: now},
		{ID: uuid.NewString(), BindingID: b.ID, TokenHash: IntegrationSecretHash(refresh), Kind: "refresh", Epoch: b.Epoch, ExpiresAt: refreshExpiry, AbsoluteExpiresAt: absolute, CreatedAt: now},
	}
	if err = tx.Create(&rows).Error; err != nil {
		return result, err
	}
	return IntegrationTokenResponse{access, "Bearer", int(accessExpiry.Sub(now).Seconds()), refresh, b.Scopes}, nil
}

func (s *IntegrationAuthService) ExchangeDevice(ctx context.Context, raw string) (IntegrationTokenResponse, error) {
	var result IntegrationTokenResponse
	var snapshot models.IntegrationDeviceRequest
	if !strings.HasPrefix(raw, "sd_") || s.DB.WithContext(ctx).Where("device_hash = ?", IntegrationSecretHash(raw)).Take(&snapshot).Error != nil {
		return result, integrationError("invalid_grant", 400)
	}
	// 尚无owner的请求也必须原子限速；错误状态提交后再返回，不能随业务错误回滚计数。
	var outcome error
	mutate := func(tx *gorm.DB, user *models.User) error {
		var row models.IntegrationDeviceRequest
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&row, "id = ?", snapshot.ID).Error; err != nil {
			return err
		}
		now := s.Now()
		if !row.ExpiresAt.After(now) {
			outcome = integrationError("expired_token", 400)
			return nil
		}
		if row.State == "denied" {
			outcome = integrationError("access_denied", 400)
			return nil
		}
		if row.State == "consumed" {
			outcome = integrationError("invalid_grant", 400)
			return nil
		}
		if row.NextPollAt.After(now) {
			outcome = integrationError("slow_down", 400)
			return tx.Model(&row).Updates(map[string]interface{}{"poll_interval": row.PollInterval + 5, "next_poll_at": now.Add(time.Duration(row.PollInterval+5) * time.Second)}).Error
		}
		if row.State != "approved" {
			outcome = integrationError("authorization_pending", 400)
			return tx.Model(&row).Update("next_poll_at", now.Add(time.Duration(row.PollInterval)*time.Second)).Error
		}
		if user == nil || row.OwnerID != user.ID {
			outcome = integrationError("authorization_pending", 400)
			return nil
		}
		var b models.IntegrationBinding
		if err := tx.First(&b, "id = ?", row.BindingID).Error; err != nil {
			return err
		}
		if err := s.bindingValid(tx, b, *user); err != nil {
			outcome = err
			return nil
		}
		var err error
		result, err = s.issueTokens(tx, b, now.Add(30*24*time.Hour))
		if err != nil {
			return err
		}
		return tx.Model(&row).Update("state", "consumed").Error
	}
	var err error
	if snapshot.OwnerID != 0 {
		err = s.ownerTx(ctx, snapshot.OwnerID, func(tx *gorm.DB, user models.User) error { return mutate(tx, &user) })
	} else {
		release := AcquireContentWriteSerialLock(s.DB)
		defer release()
		err = s.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error { return mutate(tx, nil) })
	}
	if err != nil {
		return result, err
	}
	return result, outcome
}

func (s *IntegrationAuthService) Refresh(ctx context.Context, raw string) (IntegrationTokenResponse, error) {
	var result IntegrationTokenResponse
	var snapshot models.IntegrationCredential
	var b models.IntegrationBinding
	if !strings.HasPrefix(raw, "sr_") || s.DB.WithContext(ctx).Where("token_hash = ? AND kind = ?", IntegrationSecretHash(raw), "refresh").Take(&snapshot).Error != nil || s.DB.WithContext(ctx).First(&b, "id = ?", snapshot.BindingID).Error != nil {
		return result, integrationError("invalid_grant", 400)
	}
	var outcome error
	err := s.ownerTx(ctx, b.OwnerID, func(tx *gorm.DB, user models.User) error {
		if err := tx.First(&b, "id = ?", snapshot.BindingID).Error; err != nil {
			return err
		}
		var cred models.IntegrationCredential
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&cred, "id = ?", snapshot.ID).Error; err != nil {
			return err
		}
		if b.Epoch != cred.Epoch || s.bindingValid(tx, b, user) != nil {
			outcome = integrationError("invalid_grant", 400)
			return nil
		}
		if cred.UsedAt != nil {
			outcome = integrationError("invalid_grant", 400)
			return s.revokeTx(tx, b)
		}
		// 旧摘要留到绝对期限，用于检测轮换后重放；不能因旧闲置期限到期而跳过检测。
		if !cred.ExpiresAt.After(s.Now()) || !cred.AbsoluteExpiresAt.After(s.Now()) {
			outcome = integrationError("invalid_grant", 400)
			return nil
		}
		now := s.Now()
		if err := tx.Model(&cred).Update("used_at", now).Error; err != nil {
			return err
		}
		var err error
		result, err = s.issueTokens(tx, b, cred.AbsoluteExpiresAt)
		return err
	})
	if err != nil {
		return result, err
	}
	return result, outcome
}

func (s *IntegrationAuthService) ListBindings(ctx context.Context, owner uint) ([]models.IntegrationBinding, error) {
	rows := []models.IntegrationBinding{}
	err := s.DB.WithContext(ctx).Where("owner_id = ?", owner).Order("created_at DESC").Limit(30).Find(&rows).Error
	return rows, err
}

// OAuth 撤销不向调用者区分未知令牌；只吊销令牌自身关联的授权。
func (s *IntegrationAuthService) RevokeToken(ctx context.Context, raw string) error {
	if len(raw) > 128 || (!strings.HasPrefix(raw, "sa_") && !strings.HasPrefix(raw, "sr_")) {
		return nil
	}
	var cred models.IntegrationCredential
	err := s.DB.WithContext(ctx).Where("token_hash = ?", IntegrationSecretHash(raw)).Take(&cred).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	var b models.IntegrationBinding
	if err = s.DB.WithContext(ctx).First(&b, "id = ?", cred.BindingID).Error; err != nil {
		return err
	}
	return s.Revoke(ctx, b.OwnerID, b.ID)
}

// 数据库原子计数跨实例生效，不能用单个 Python 进程内的计数代替服务端限流。
func (s *IntegrationAuthService) AllowRequest(ctx context.Context, category, subject string, limit int, window time.Duration) error {
	start := s.Now().Unix() / int64(window.Seconds())
	key := IntegrationSecretHash(fmt.Sprintf("%s:%s:%d", category, subject, start))
	row := models.IntegrationRateBucket{Key: key, Count: 1, ExpiresAt: s.Now().Add(2 * window)}
	result := s.DB.WithContext(ctx).Clauses(clause.OnConflict{Columns: []clause.Column{{Name: "key"}}, DoUpdates: clause.Assignments(map[string]interface{}{"count": gorm.Expr("integration_rate_buckets.count + 1")}), Where: clause.Where{Exprs: []clause.Expression{clause.Expr{SQL: "integration_rate_buckets.count < ?", Vars: []interface{}{limit}}}}}).Create(&row)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return integrationError("rate_limited", 429)
	}
	return nil
}

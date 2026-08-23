package ai

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"
)

type scopedGrantContextKey struct{}

// ScopedGrant 只存在于 Go 服务和 MCP Gateway 的受控 Context 中。
// JSON 序列化时隐藏 UserID、RunID 和 token，防止它们进入模型消息或客户端事件。
type ScopedGrant struct {
	ID                  string    `json:"-"`
	RunID               string    `json:"-"`
	UserID              uint      `json:"-"`
	AllowedCapabilities []string  `json:"allowed_capabilities"`
	Scopes              []string  `json:"scopes"`
	ExpiresAt           time.Time `json:"expires_at"`
	MaxCalls            int       `json:"max_calls"`
	Calls               int       `json:"-"`
	PermissionScope     models.AIUserPermissionScope `json:"-"`
	PermissionVersion   int64     `json:"-"`
}

// ScopedGrantPermissionVersionReader 由控制面提供实时权限版本。
type ScopedGrantPermissionVersionReader interface {
	PermissionVersion(context.Context, uint, models.AIUserPermissionScope) (int64, error)
}

type ScopedGrantManagerOption func(*ScopedGrantManager)

func WithScopedGrantPermissionVersionReader(reader ScopedGrantPermissionVersionReader) ScopedGrantManagerOption {
	return func(manager *ScopedGrantManager) { manager.permissionVersions = reader }
}

type ScopedGrantManager struct {
	mu                sync.Mutex
	clock             func() time.Time
	grants            map[string]ScopedGrant
	permissionVersions ScopedGrantPermissionVersionReader
}

func NewScopedGrantManager(clock func() time.Time, options ...ScopedGrantManagerOption) *ScopedGrantManager {
	if clock == nil {
		clock = time.Now
	}
	manager := &ScopedGrantManager{clock: clock, grants: make(map[string]ScopedGrant)}
	for _, option := range options {
		if option != nil {
			option(manager)
		}
	}
	return manager
}

func (m *ScopedGrantManager) IssueRunGrant(runID string, userID uint, capabilities, scopes []string, ttl time.Duration, maxCalls int) (string, ScopedGrant, error) {
	return m.IssueRunGrantWithContext(context.Background(), runID, userID, capabilities, scopes, "", ttl, maxCalls)
}

// IssueRunGrantWithContext 为个人数据 Grant 固定签入当前权限版本。
func (m *ScopedGrantManager) IssueRunGrantWithContext(ctx context.Context, runID string, userID uint, capabilities, scopes []string, permissionScope models.AIUserPermissionScope, ttl time.Duration, maxCalls int) (string, ScopedGrant, error) {
	if m == nil || strings.TrimSpace(runID) == "" || userID == 0 || ttl <= 0 || ttl > 10*time.Minute || maxCalls <= 0 || maxCalls > 64 {
		return "", ScopedGrant{}, errors.New("invalid_scoped_grant_request")
	}
	if permissionScope != "" && !permissionScope.Valid() {
		return "", ScopedGrant{}, errors.New("invalid_scoped_grant_permission_scope")
	}
	capabilities = uniqueNonEmpty(capabilities)
	scopes = uniqueNonEmpty(scopes)
	if len(capabilities) == 0 {
		return "", ScopedGrant{}, errors.New("scoped_grant_capabilities_required")
	}
	randomBytes := make([]byte, 32)
	if _, err := rand.Read(randomBytes); err != nil {
		return "", ScopedGrant{}, err
	}
	token := "g_" + base64.RawURLEncoding.EncodeToString(randomBytes)
	grant := ScopedGrant{ID: token, RunID: runID, UserID: userID, AllowedCapabilities: capabilities, Scopes: scopes, ExpiresAt: m.clock().Add(ttl), MaxCalls: maxCalls, PermissionScope: permissionScope}
	if permissionScope != "" && m.permissionVersions != nil {
		version, err := m.permissionVersions.PermissionVersion(ctx, userID, permissionScope)
		if err != nil {
			return "", ScopedGrant{}, err
		}
		grant.PermissionVersion = version
	}
	m.mu.Lock()
	m.grants[token] = grant
	m.mu.Unlock()
	return token, grant, nil
}

// Verify 消费一次调用额度，并返回只供服务端使用的 subject。
func (m *ScopedGrantManager) Verify(token, capability string) (ScopedGrant, error) {
	return m.VerifyContext(context.Background(), token, capability)
}

// VerifyContext 在真正进入内部 MCP 前重新检查权限版本。
func (m *ScopedGrantManager) VerifyContext(ctx context.Context, token, capability string) (ScopedGrant, error) {
	if m == nil || strings.TrimSpace(token) == "" || strings.TrimSpace(capability) == "" {
		return ScopedGrant{}, errors.New("mcp_grant_invalid")
	}
	m.mu.Lock()
	grant, ok := m.grants[token]
	if !ok || !grant.ExpiresAt.After(m.clock()) {
		if ok {
			delete(m.grants, token)
		}
		m.mu.Unlock()
		return ScopedGrant{}, errors.New("mcp_grant_expired")
	}
	if grant.Calls >= grant.MaxCalls || !containsScopedGrantString(grant.AllowedCapabilities, capability) {
		m.mu.Unlock()
		return ScopedGrant{}, errors.New("mcp_grant_scope_denied")
	}
	m.mu.Unlock()
	if grant.PermissionScope != "" && m.permissionVersions != nil {
		version, err := m.permissionVersions.PermissionVersion(ctx, grant.UserID, grant.PermissionScope)
		if err != nil || version != grant.PermissionVersion {
			m.Revoke(token)
			return ScopedGrant{}, errors.New("mcp_grant_revoked")
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	current, ok := m.grants[token]
	if !ok || current.Calls != grant.Calls || !current.ExpiresAt.After(m.clock()) {
		return ScopedGrant{}, errors.New("mcp_grant_revoked")
	}
	grant = current
	grant.Calls++
	m.grants[token] = grant
	return grant, nil
}

func (m *ScopedGrantManager) Revoke(token string) {
	if m == nil || token == "" {
		return
	}
	m.mu.Lock()
	delete(m.grants, token)
	m.mu.Unlock()
}

// RevokeRun 终止 Run 时撤销该 Run 的所有短期 Grant，避免取消后的迟到请求继续
// 通过已签发 token 访问纯能力层。
func (m *ScopedGrantManager) RevokeRun(runID string) {
	if m == nil || strings.TrimSpace(runID) == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for token, grant := range m.grants {
		if grant.RunID == runID {
			delete(m.grants, token)
		}
	}
}

func WithScopedGrant(ctx context.Context, grant ScopedGrant) context.Context {
	return context.WithValue(ctx, scopedGrantContextKey{}, grant)
}

func ScopedGrantFromContext(ctx context.Context) (ScopedGrant, bool) {
	grant, ok := ctx.Value(scopedGrantContextKey{}).(ScopedGrant)
	return grant, ok && grant.UserID != 0 && grant.ID != ""
}

func uniqueNonEmpty(values []string) []string {
	result := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if _, exists := seen[value]; exists {
			continue
		}
		seen[value] = struct{}{}
		result = append(result, value)
	}
	return result
}

func containsScopedGrantString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

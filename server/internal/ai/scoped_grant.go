package ai

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"time"
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
}

type ScopedGrantManager struct {
	mu     sync.Mutex
	clock  func() time.Time
	grants map[string]ScopedGrant
}

func NewScopedGrantManager(clock func() time.Time) *ScopedGrantManager {
	if clock == nil {
		clock = time.Now
	}
	return &ScopedGrantManager{clock: clock, grants: make(map[string]ScopedGrant)}
}

func (m *ScopedGrantManager) IssueRunGrant(runID string, userID uint, capabilities, scopes []string, ttl time.Duration, maxCalls int) (string, ScopedGrant, error) {
	if m == nil || strings.TrimSpace(runID) == "" || userID == 0 || ttl <= 0 || ttl > 10*time.Minute || maxCalls <= 0 || maxCalls > 64 {
		return "", ScopedGrant{}, errors.New("invalid_scoped_grant_request")
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
	grant := ScopedGrant{ID: token, RunID: runID, UserID: userID, AllowedCapabilities: capabilities, Scopes: scopes, ExpiresAt: m.clock().Add(ttl), MaxCalls: maxCalls}
	m.mu.Lock()
	m.grants[token] = grant
	m.mu.Unlock()
	return token, grant, nil
}

// Verify 消费一次调用额度，并返回只供服务端使用的 subject。
func (m *ScopedGrantManager) Verify(token, capability string) (ScopedGrant, error) {
	if m == nil || strings.TrimSpace(token) == "" || strings.TrimSpace(capability) == "" {
		return ScopedGrant{}, errors.New("mcp_grant_invalid")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	grant, ok := m.grants[token]
	if !ok || !grant.ExpiresAt.After(m.clock()) {
		if ok {
			delete(m.grants, token)
		}
		return ScopedGrant{}, errors.New("mcp_grant_expired")
	}
	if grant.Calls >= grant.MaxCalls || !containsScopedGrantString(grant.AllowedCapabilities, capability) {
		return ScopedGrant{}, errors.New("mcp_grant_scope_denied")
	}
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

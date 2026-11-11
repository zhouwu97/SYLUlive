package handlers

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

type academicTransferTestEnv struct {
	router  *gin.Engine
	handler *AcademicTransferHandler
	user    uint
	now     time.Time
}

func newAcademicTransferTestEnv() *academicTransferTestEnv {
	env := &academicTransferTestEnv{handler: NewAcademicTransferHandler(), user: 1, now: time.Unix(1_800_000_000, 0)}
	env.handler.now = func() time.Time { return env.now }
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", env.user) })
	r.POST("/sessions", env.handler.Create)
	r.GET("/sessions/:id", env.handler.Get)
	r.POST("/sessions/:id/claim", env.handler.Claim)
	r.PUT("/sessions/:id/payload", env.handler.Upload)
	r.DELETE("/sessions/:id", env.handler.Delete)
	env.router = r
	return env
}

func (env *academicTransferTestEnv) do(t *testing.T, method, path, body string) (int, map[string]any) {
	t.Helper()
	w := httptest.NewRecorder()
	env.router.ServeHTTP(w, httptest.NewRequest(method, path, bytes.NewBufferString(body)))
	result := map[string]any{}
	if w.Body.Len() > 0 {
		require.NoError(t, json.Unmarshal(w.Body.Bytes(), &result), w.Body.String())
	}
	return w.Code, result
}

func academicTransferEnvelope(t *testing.T, plaintextSize int) string {
	t.Helper()
	key, err := ecdh.P256().GenerateKey(rand.Reader)
	require.NoError(t, err)
	encode := base64.RawURLEncoding.EncodeToString
	body, err := json.Marshal(map[string]string{
		"app_public_key": encode(key.PublicKey().Bytes()),
		"nonce":          encode(make([]byte, 12)),
		"ciphertext":     encode(make([]byte, plaintextSize+16)),
	})
	require.NoError(t, err)
	return string(body)
}

func TestAcademicTransferHappyPathKeepsCiphertextUntilAcknowledged(t *testing.T) {
	env := newAcademicTransferTestEnv()
	code, created := env.do(t, "POST", "/sessions", "")
	require.Equal(t, 201, code)
	id := created["session_id"].(string)
	require.Len(t, id, 22)
	require.Equal(t, "pending", created["status"])

	// 未扫码确认前不能直接上传。
	code, body := env.do(t, "PUT", "/sessions/"+id+"/payload", academicTransferEnvelope(t, 64))
	require.Equal(t, 409, code)
	require.Equal(t, "TRANSFER_NOT_CLAIMED", body["code"])

	code, body = env.do(t, "POST", "/sessions/"+id+"/claim", "")
	require.Equal(t, 200, code)
	require.Equal(t, "claimed", body["status"])

	envelope := academicTransferEnvelope(t, 64)
	code, body = env.do(t, "PUT", "/sessions/"+id+"/payload", envelope)
	require.Equal(t, 200, code, body)
	require.Equal(t, "ready", body["status"])

	// 一张码只接受一次上传，后续扫码也被拒绝。
	code, body = env.do(t, "PUT", "/sessions/"+id+"/payload", envelope)
	require.Equal(t, 409, code)
	require.Equal(t, "TRANSFER_ALREADY_UPLOADED", body["code"])
	code, _ = env.do(t, "POST", "/sessions/"+id+"/claim", "")
	require.Equal(t, 409, code)

	// 网页确认前可重复读取，确认后密文立即清除且删除保持幂等。
	for range 2 {
		code, body = env.do(t, "GET", "/sessions/"+id, "")
		require.Equal(t, 200, code)
		require.NotEmpty(t, body["payload"].(map[string]any)["ciphertext"])
	}
	require.Positive(t, env.handler.totalBytes)
	code, _ = env.do(t, "DELETE", "/sessions/"+id, "")
	require.Equal(t, 204, code)
	require.Zero(t, env.handler.totalBytes)
	code, _ = env.do(t, "DELETE", "/sessions/"+id, "")
	require.Equal(t, 204, code)
	code, body = env.do(t, "GET", "/sessions/"+id, "")
	require.Equal(t, 404, code)
	require.Equal(t, "TRANSFER_SESSION_NOT_FOUND", body["code"])
}

func TestAcademicTransferRejectsOtherAccountAndExpiry(t *testing.T) {
	env := newAcademicTransferTestEnv()
	_, created := env.do(t, "POST", "/sessions", "")
	id := created["session_id"].(string)

	env.user = 2
	for _, call := range [][2]string{{"GET", ""}, {"POST", "/claim"}, {"PUT", "/payload"}} {
		body := ""
		if call[0] == "PUT" {
			body = academicTransferEnvelope(t, 8)
		}
		code, result := env.do(t, call[0], "/sessions/"+id+call[1], body)
		require.Equal(t, 403, code, call)
		require.Equal(t, "TRANSFER_ACCOUNT_MISMATCH", result["code"])
	}
	// 其他账号的删除不生效。
	code, _ := env.do(t, "DELETE", "/sessions/"+id, "")
	require.Equal(t, 204, code)
	env.user = 1
	code, _ = env.do(t, "GET", "/sessions/"+id, "")
	require.Equal(t, 200, code)

	env.now = env.now.Add(academicTransferTTL)
	code, result := env.do(t, "POST", "/sessions/"+id+"/claim", "")
	require.Equal(t, 404, code)
	require.Equal(t, "TRANSFER_SESSION_NOT_FOUND", result["code"])
	require.Empty(t, env.handler.sessions)
}

func TestAcademicTransferValidatesEnvelopeAndLimits(t *testing.T) {
	env := newAcademicTransferTestEnv()
	_, created := env.do(t, "POST", "/sessions", "")
	id := created["session_id"].(string)
	env.do(t, "POST", "/sessions/"+id+"/claim", "")

	valid := academicTransferEnvelope(t, 8)
	invalid := []string{
		`{}`,
		`not json`,
		strings.Replace(valid, `"nonce":"`, `"nonce":"AAAA`, 1),
		strings.Replace(valid, `"app_public_key":"`, `"app_public_key":"AAAA`, 1),
		// 明文字段或凭据误传必须被拒绝，而不是被静默丢弃。
		strings.Replace(valid, `{`, `{"password":"x",`, 1),
		valid + valid,
	}
	for _, body := range invalid {
		code, result := env.do(t, "PUT", "/sessions/"+id+"/payload", body)
		require.Equal(t, 400, code, body)
		require.Equal(t, "INVALID_TRANSFER_PAYLOAD", result["code"])
	}
	code, result := env.do(t, "PUT", "/sessions/"+id+"/payload", academicTransferEnvelope(t, academicTransferMaxCiphertext))
	require.Equal(t, 413, code)
	require.Equal(t, "TRANSFER_PAYLOAD_TOO_LARGE", result["code"])
	require.Zero(t, env.handler.totalBytes)

	// 同一用户只保留最近的会话，最早的一张码被淘汰。
	for range academicTransferMaxSessionsPerUser {
		code, _ = env.do(t, "POST", "/sessions", "")
		require.Equal(t, 201, code)
	}
	require.Len(t, env.handler.sessions, academicTransferMaxSessionsPerUser)
	code, _ = env.do(t, "GET", "/sessions/"+id, "")
	require.Equal(t, 404, code)

	for i := academicTransferMaxSessionsPerUser + 1; i < academicTransferCreatePerWindow; i++ {
		code, _ = env.do(t, "POST", "/sessions", "")
		require.Equal(t, 201, code)
	}
	code, result = env.do(t, "POST", "/sessions", "")
	require.Equal(t, 429, code)
	require.Equal(t, "TRANSFER_RATE_LIMITED", result["code"])
	env.now = env.now.Add(academicTransferCreateWindow)
	code, _ = env.do(t, "POST", "/sessions", "")
	require.Equal(t, 201, code)
}

func TestAcademicTransferKeepsNewestSessionsWhenCreationTimesMatch(t *testing.T) {
	env := newAcademicTransferTestEnv()
	var ids []string
	// 夹具固定时钟；连续出码仍必须保留最后三张，不能随机淘汰。
	for range academicTransferMaxSessionsPerUser + 5 {
		code, created := env.do(t, "POST", "/sessions", "")
		require.Equal(t, 201, code)
		ids = append(ids, created["session_id"].(string))
		for i, id := range ids {
			want := 200
			if i < len(ids)-academicTransferMaxSessionsPerUser {
				want = 404
			}
			code, _ = env.do(t, "GET", "/sessions/"+id, "")
			require.Equal(t, want, code)
		}
	}
}

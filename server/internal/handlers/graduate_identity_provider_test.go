package handlers

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"shenliyuan/internal/models"

	"github.com/stretchr/testify/require"
)

func TestGraduatePublicKeyFingerprintAcceptsSPKIAndPKCS1(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	require.NoError(t, err)
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	require.NoError(t, err)
	spkiPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: spki})
	rsaPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PUBLIC KEY", Bytes: x509.MarshalPKCS1PublicKey(&key.PublicKey)})
	spkiFingerprint, err := graduatePublicKeyFingerprint(string(spkiPEM))
	require.NoError(t, err)
	rsaFingerprint, err := graduatePublicKeyFingerprint(string(rsaPEM))
	require.NoError(t, err)
	require.Equal(t, spkiFingerprint, rsaFingerprint, "SPKI 与 RSA PUBLIC KEY 只应因 PEM 封装不同而保持同一公钥指纹")
}

func TestExtractGraduatePublicKeyAcceptsAttributeOrder(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	require.NoError(t, err)
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	require.NoError(t, err)
	pemKey := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}))
	require.Equal(t, strings.TrimSpace(pemKey), extractGraduatePublicKey([]byte(`<input value="`+pemKey+`" id="pubkey">`)))
}

func TestGraduateSessionPrefixKeepsLeadingSlash(t *testing.T) {
	require.Equal(t, "/(S(test-session))", graduateSessionPrefix("/(S(test-session))/home/stulogin"))
	baseURL, err := url.Parse("https://yjsgl.sylu.edu.cn")
	require.NoError(t, err)
	provider := &GraduateAcademicIdentityProvider{baseURL: baseURL}
	require.Equal(t, "https://yjsgl.sylu.edu.cn/(S(test-session))/home/stulogin_do", provider.endpointWithPrefix("(S(test-session))", "/home/stulogin_do"))
}

func TestGraduateCookieStateKeepsScopeAndDropsExpiredCookies(t *testing.T) {
	loginURL, err := url.Parse("https://example.test/home/stulogin")
	require.NoError(t, err)
	jar, err := newGraduateCookieJar()
	require.NoError(t, err)
	jar.SetCookies(loginURL, []*http.Cookie{
		{Name: "host-only", Value: "host", Path: "/"},
		{Name: "domain", Value: "domain", Domain: "example.test", Path: "/"},
		{Name: "expiring", Value: "live", Path: "/"},
	})
	jar.SetCookies(loginURL, []*http.Cookie{
		{Name: "expiring", Value: "expired", Path: "/", Expires: time.Now().Add(-time.Minute)},
		{Name: "host-only", Value: "deleted", Path: "/", MaxAge: -1},
	})

	states := jar.States()
	stateByName := make(map[string]graduateCookieState, len(states))
	for _, state := range states {
		stateByName[state.Name] = state
	}
	require.NotContains(t, stateByName, "expiring")
	require.NotContains(t, stateByName, "host-only")
	require.Equal(t, "example.test", stateByName["domain"].Domain)

	restored, err := newGraduateCookieJar()
	require.NoError(t, err)
	restored.SetCookies(loginURL, graduateCookiesToHTTP(states))
	otherOrigin, err := url.Parse("https://sub.example.test/student/default/getxscardinfo")
	require.NoError(t, err)
	cookies := restored.Cookies(otherOrigin)
	require.Len(t, cookies, 1)
	require.Equal(t, "domain", cookies[0].Name)
}

func TestNewGraduateProviderRequiresHTTPSOrigin(t *testing.T) {
	for _, rawURL := range []string{
		"http://yjsgl.sylu.edu.cn",
		"https://yjsgl.sylu.edu.cn/path",
		"https://user:pass@yjsgl.sylu.edu.cn",
	} {
		_, err := NewGraduateAcademicIdentityProvider(rawURL)
		require.Error(t, err, rawURL)
	}
}

func TestGraduateProfileRequiresSingleSchoolRecordAndXH(t *testing.T) {
	profile, err := parseGraduateProfile([]byte(`[{"xh":"G20260001","xm":"测试学生","xsmc":"信息学院"}]`))
	require.NoError(t, err)
	require.Equal(t, "G20260001", profile.StudentID)
	require.Equal(t, "测试学生", profile.Name)
	_, err = parseGraduateProfile([]byte(`[]`))
	require.Error(t, err)
	_, err = parseGraduateProfile([]byte(`[{"xm":"缺少学号"}]`))
	require.Error(t, err)
	_, err = parseGraduateProfile([]byte(`[{"xh":"A"},{"xh":"B"}]`))
	require.Error(t, err)
}

func TestGraduateEncryptedJSONResponseDecode(t *testing.T) {
	var direct map[string]interface{}
	encoded, err := json.Marshal(map[string]interface{}{"jg": "1"})
	require.NoError(t, err)
	direct, err = decodeGraduateJSON(encoded)
	require.NoError(t, err)
	require.Equal(t, "1", direct["jg"])
}

func TestGraduateProfileResponseDecodesAESArray(t *testing.T) {
	block, err := aes.NewCipher([]byte(graduateAESKey))
	require.NoError(t, err)
	plain := []byte(`[{"xh":"G20260001","xm":"加密学生"}]`)
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	plain = append(plain, bytes.Repeat([]byte{byte(padding)}, padding)...)
	ciphertext := make([]byte, len(plain))
	for offset := 0; offset < len(plain); offset += aes.BlockSize {
		block.Encrypt(ciphertext[offset:offset+aes.BlockSize], plain[offset:offset+aes.BlockSize])
	}
	quoted, err := json.Marshal(base64.StdEncoding.EncodeToString(ciphertext))
	require.NoError(t, err)
	profile, err := parseGraduateProfileResponse(quoted)
	require.NoError(t, err)
	require.Equal(t, "G20260001", profile.StudentID)
	require.Equal(t, "加密学生", profile.Name)
}

func TestGraduateProviderVerifiesSchoolProfileBeforeReturningIdentity(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 1024)
	require.NoError(t, err)
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	require.NoError(t, err)
	pubkey := string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: spki}))
	captchaBytes := []byte("fixture-captcha-image-payload-0123456789")
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/home/stulogin":
			writer.Header().Set("Set-Cookie", "ASP.NET_SessionId=session-fixture; Path=/")
			writer.Header().Set("Content-Type", "text/html; charset=utf-8")
			_, _ = writer.Write([]byte(`<html><input id="pubkey" value="` + pubkey + `"></html>`))
		case "/home/verificationcode":
			writer.Header().Set("Content-Type", "image/gif")
			_, _ = writer.Write(captchaBytes)
		case "/home/stulogin_do":
			if err := request.ParseForm(); err != nil || request.Form.Get("json") == "" {
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			writer.Header().Set("Content-Type", "application/json")
			_, _ = writer.Write([]byte(`{"jg":"1"}`))
		case "/student/default/getxscardinfo":
			cookie, cookieErr := request.Cookie("ASP.NET_SessionId")
			if cookieErr != nil || cookie.Value != "session-fixture" {
				writer.Header().Set("Content-Type", "text/html")
				_, _ = writer.Write([]byte(`<html><title>登录</title></html>`))
				return
			}
			writer.Header().Set("Content-Type", "application/json")
			_, _ = writer.Write([]byte(`[{"xh":"G20260001","xm":"探针学生"}]`))
		default:
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()
	parsed, err := url.Parse(server.URL)
	require.NoError(t, err)
	provider := &GraduateAcademicIdentityProvider{baseURL: parsed, transport: server.Client().Transport}
	challenge, err := provider.PrepareChallenge(context.Background(), 7, "G20260001")
	require.NoError(t, err)
	require.True(t, challenge.Required)
	require.NotEmpty(t, challenge.ChallengeState)
	fingerprint, err := graduatePublicKeyFingerprint(pubkey)
	require.NoError(t, err)
	profile, err := provider.Verify(context.Background(), AcademicProviderVerifyRequest{
		UserID: 7, ProviderID: models.AcademicProviderGraduate, StudentID: "G20260001",
		Captcha: "1234", EncryptedPassword: "rsa-ciphertext", SchoolPublicKeyFingerprint: fingerprint,
		ChallengeState: challenge.ChallengeState,
	})
	require.NoError(t, err)
	require.Equal(t, "G20260001", profile.StudentID)
}

func TestGraduateProviderProfileFallsBackToPost(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method == http.MethodGet {
			writer.Header().Set("Content-Type", "text/html")
			_, _ = writer.Write([]byte(`<html><title>登录</title></html>`))
			return
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`[{"xh":"G20260001","xm":"回退学生"}]`))
	}))
	defer server.Close()
	baseURL, err := url.Parse(server.URL)
	require.NoError(t, err)
	provider := &GraduateAcademicIdentityProvider{baseURL: baseURL, transport: server.Client().Transport}
	jar, err := cookiejar.New(nil)
	require.NoError(t, err)
	profile, err := provider.fetchGraduateProfile(context.Background(), provider.newClient(jar), server.URL+"/profile", server.URL+"/login")
	require.NoError(t, err)
	require.Equal(t, "G20260001", profile.StudentID)
}

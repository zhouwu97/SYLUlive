package handlers

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"shenliyuan/internal/models"
)

const (
	defaultGraduateProviderURL = "https://yjsgl.sylu.edu.cn"
	graduateProviderTimeout    = 15 * time.Second
	graduateMaxResponseBytes   = 4 * 1024 * 1024
	graduateAESKey             = "southsoft12345!#"
	graduateUserAgent          = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/152.0.0.0 Safari/537.36"
)

var graduateSessionPrefixPattern = regexp.MustCompile(`(?i)^(/+\(S\([^)]+\)\))`)
var graduatePubKeyTagPattern = regexp.MustCompile(`(?is)<[^>]*\bid=["']pubkey["'][^>]*>`)
var graduatePubKeyValuePattern = regexp.MustCompile(`(?is)\bvalue=["']([^"']+)["']`)
var graduatePubKeyValueFirstPattern = regexp.MustCompile(`(?is)<[^>]*\bvalue=["']([^"']+)["'][^>]*\bid=["']pubkey["'][^>]*>`)

// GraduateAcademicIdentityProvider 是研究生 SouthSoft/GMIS 协议的最小身份验证实现。
// 密码只作为设备生成的 RSA 密文透传，临时 Cookie 与公钥放在服务端密封 challenge 状态中。
type GraduateAcademicIdentityProvider struct {
	baseURL   *url.URL
	transport http.RoundTripper
}

// graduateProviderStageError 只携带固定阶段和 HTTP 状态，便于定位学校协议失败，
// 不把 URL、响应体、Cookie 或任何凭据带入日志。
type graduateProviderStageError struct {
	Stage  string
	Status int
}

func (e *graduateProviderStageError) Error() string {
	return "研究生教务 Provider 请求阶段失败"
}

func (e *graduateProviderStageError) Unwrap() error { return ErrAcademicProviderUnavailable }

func graduateProviderUnavailable(stage string, status int) error {
	return &graduateProviderStageError{Stage: stage, Status: status}
}

type graduateChallengeState struct {
	BaseURL         string                `json:"base_url"`
	LoginPageURL    string                `json:"login_page_url"`
	SessionPrefix   string                `json:"session_prefix,omitempty"`
	SchoolPublicKey string                `json:"school_public_key"`
	Cookies         []graduateCookieState `json:"cookies"`
}

type graduateCookieState struct {
	Name     string    `json:"name"`
	Value    string    `json:"value"`
	Path     string    `json:"path,omitempty"`
	Domain   string    `json:"domain,omitempty"`
	MaxAge   int       `json:"max_age,omitempty"`
	Expires  time.Time `json:"expires,omitempty"`
	Secure   bool      `json:"secure,omitempty"`
	HTTPOnly bool      `json:"http_only,omitempty"`
}

// graduateCookieJar 在标准 CookieJar 之外记录 Set-Cookie 的作用域元数据。
// cookiejar.Cookies 只返回下次请求所需的 Name/Value，直接导出再恢复会
// 丢失 Path，导致 Path=/ 的教务会话恢复为 /home 下的 Cookie。
type graduateCookieJar struct {
	inner  *cookiejar.Jar
	mu     sync.Mutex
	states map[string]graduateCookieState
}

func newGraduateCookieJar() (*graduateCookieJar, error) {
	inner, err := cookiejar.New(nil)
	if err != nil {
		return nil, err
	}
	return &graduateCookieJar{inner: inner, states: make(map[string]graduateCookieState)}, nil
}

func (j *graduateCookieJar) Cookies(target *url.URL) []*http.Cookie {
	return j.inner.Cookies(target)
}

func (j *graduateCookieJar) SetCookies(target *url.URL, cookies []*http.Cookie) {
	j.inner.SetCookies(target, cookies)
	j.mu.Lock()
	defer j.mu.Unlock()
	for _, cookie := range cookies {
		if cookie == nil || cookie.Name == "" {
			continue
		}
		state := graduateCookieState{
			Name: cookie.Name, Value: cookie.Value, Path: cookie.Path,
			Domain: cookie.Domain, MaxAge: cookie.MaxAge, Expires: cookie.Expires,
			Secure: cookie.Secure, HTTPOnly: cookie.HttpOnly,
		}
		if state.Path == "" {
			state.Path = graduateDefaultCookiePath(target.Path)
		}
		key := state.Name + "\x00" + state.Domain + "\x00" + state.Path
		if cookie.MaxAge < 0 || (!cookie.Expires.IsZero() && !cookie.Expires.After(time.Now())) {
			delete(j.states, key)
			continue
		}
		j.states[key] = state
	}
}

func (j *graduateCookieJar) States() []graduateCookieState {
	j.mu.Lock()
	defer j.mu.Unlock()
	result := make([]graduateCookieState, 0, len(j.states))
	for _, state := range j.states {
		result = append(result, state)
	}
	sort.Slice(result, func(i, k int) bool {
		if result[i].Name != result[k].Name {
			return result[i].Name < result[k].Name
		}
		if result[i].Domain != result[k].Domain {
			return result[i].Domain < result[k].Domain
		}
		return result[i].Path < result[k].Path
	})
	return result
}

func graduateDefaultCookiePath(requestPath string) string {
	if requestPath == "" || requestPath[0] != '/' {
		return "/"
	}
	lastSlash := strings.LastIndex(requestPath, "/")
	if lastSlash <= 0 {
		return "/"
	}
	return requestPath[:lastSlash]
}

// NewGraduateAcademicIdentityProvider 创建真实研究生学校协议 Provider。
// URL 为空时使用实测的学校域名；不把账号、密码或 Cookie 放入配置和数据库。
func NewGraduateAcademicIdentityProvider(rawBaseURL string) (*GraduateAcademicIdentityProvider, error) {
	if strings.TrimSpace(rawBaseURL) == "" {
		rawBaseURL = defaultGraduateProviderURL
	}
	parsed, err := url.Parse(strings.TrimRight(strings.TrimSpace(rawBaseURL), "/"))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Path != "" {
		return nil, errors.New("研究生教务 Provider URL 必须是无路径 HTTPS 地址")
	}
	return &GraduateAcademicIdentityProvider{baseURL: parsed}, nil
}

func (p *GraduateAcademicIdentityProvider) ProviderID() models.AcademicProviderID {
	return models.AcademicProviderGraduate
}

func (p *GraduateAcademicIdentityProvider) PrepareChallenge(ctx context.Context, _ uint, _ string) (AcademicProviderChallenge, error) {
	jar, err := newGraduateCookieJar()
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	client := p.newClient(jar)
	loginURL := p.endpoint("/home/stulogin")
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, loginURL, nil)
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	setGraduateRequestHeaders(request)
	response, err := client.Do(request)
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	body, readErr := readGraduateResponseBody(response)
	response.Body.Close()
	if readErr != nil || response.StatusCode < 200 || response.StatusCode >= 300 {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	loginPageURL := response.Request.URL.String()
	pubKey := extractGraduatePublicKey(body)
	if pubKey == "" {
		return AcademicProviderChallenge{}, fmt.Errorf("研究生登录页缺少 #pubkey")
	}
	fingerprint, err := graduatePublicKeyFingerprint(pubKey)
	if err != nil {
		return AcademicProviderChallenge{}, fmt.Errorf("研究生登录公钥无效: %w", err)
	}
	prefix := graduateSessionPrefix(response.Request.URL.Path)
	captchaURL := p.endpointWithPrefix(prefix, "/home/verificationcode")
	query := "?codetype=stucode&t=" + fmt.Sprintf("%d", time.Now().UnixMilli())
	captchaRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, captchaURL+query, nil)
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	setGraduateRequestHeaders(captchaRequest)
	captchaRequest.Header.Set("Referer", loginPageURL)
	captchaResponse, err := client.Do(captchaRequest)
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	captchaBytes, captchaErr := readGraduateResponseBody(captchaResponse)
	captchaContentType := captchaResponse.Header.Get("Content-Type")
	captchaResponse.Body.Close()
	if captchaErr != nil || captchaResponse.StatusCode < 200 || captchaResponse.StatusCode >= 300 || len(captchaBytes) < 32 || len(captchaBytes) > 2*1024*1024 || (!strings.Contains(strings.ToLower(captchaContentType), "image") && len(captchaBytes) < 100) {
		return AcademicProviderChallenge{}, fmt.Errorf("研究生验证码响应无效")
	}
	state := graduateChallengeState{
		BaseURL: p.baseURL.String(), LoginPageURL: loginPageURL, SessionPrefix: prefix,
		SchoolPublicKey: pubKey, Cookies: jar.States(),
	}
	stateBytes, err := json.Marshal(state)
	if err != nil {
		return AcademicProviderChallenge{}, ErrAcademicProviderUnavailable
	}
	return AcademicProviderChallenge{
		Required: true, Type: "image_captcha", Captcha: base64.StdEncoding.EncodeToString(captchaBytes),
		SchoolPublicKey: pubKey, SchoolPublicKeyFingerprint: fingerprint, ChallengeState: stateBytes,
	}, nil
}

func (p *GraduateAcademicIdentityProvider) Verify(ctx context.Context, request AcademicProviderVerifyRequest) (AcademicVerifiedProfile, error) {
	if request.ProviderID != models.AcademicProviderGraduate || request.StudentID == "" || request.EncryptedPassword == "" || request.Captcha == "" {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	var state graduateChallengeState
	if err := json.Unmarshal(request.ChallengeState, &state); err != nil || state.BaseURL != p.baseURL.String() || state.SchoolPublicKey == "" || state.LoginPageURL == "" {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	if fingerprint, err := graduatePublicKeyFingerprint(state.SchoolPublicKey); err != nil || fingerprint != request.SchoolPublicKeyFingerprint {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	jar, err := newGraduateCookieJar()
	if err != nil {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("verify_cookiejar", 0)
	}
	loginURL, err := url.Parse(state.LoginPageURL)
	if err != nil || !sameGraduateOrigin(p.baseURL, loginURL) {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	jar.SetCookies(loginURL, graduateCookiesToHTTP(state.Cookies))
	client := p.newClient(jar)
	payload := map[string]interface{}{
		"UserId": request.StudentID, "Password": request.EncryptedPassword,
		"VeriCode": graduateCaptchaValue(request.Captcha), "url": "", "city": "",
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	loginEndpoint := p.endpointWithPrefix(state.SessionPrefix, "/home/stulogin_do")
	loginRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, loginEndpoint, bytes.NewReader([]byte("json="+url.QueryEscape(string(encoded)))))
	if err != nil {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("login_request", 0)
	}
	setGraduateRequestHeaders(loginRequest)
	loginRequest.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	loginRequest.Header.Set("X-Requested-With", "XMLHttpRequest")
	loginRequest.Header.Set("Referer", state.LoginPageURL)
	// 登录探针明确禁止自动跟随 POST 重定向；学校成功响应中的 url 字段
	// 是业务跳转信息，不能让 HTTP 客户端把登录表单重放到未知页面。
	loginClient := *client
	loginClient.CheckRedirect = func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }
	loginResponse, err := loginClient.Do(loginRequest)
	if err != nil {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("login_transport", 0)
	}
	loginBody, readErr := readGraduateResponseBody(loginResponse)
	loginResponse.Body.Close()
	if readErr != nil {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("login_read", loginResponse.StatusCode)
	}
	if graduateHTMLResponse(loginBody) {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	loginResult, err := decodeGraduateJSON(loginBody)
	if err != nil {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("login_decode", loginResponse.StatusCode)
	}
	if fmt.Sprint(loginResult["jg"]) != "1" {
		if graduateCaptchaError(loginResult) {
			return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
		}
		return AcademicVerifiedProfile{}, ErrAcademicIdentityRejected
	}
	profilePrefix := graduateSessionPrefix(loginResponse.Request.URL.Path)
	if profilePrefix == "" {
		// Cookie 模式的登录响应通常没有 URL 前缀；无 Cookie 的
		// SouthSoft 版本则必须继续使用 challenge 时捕获的 /(S(...)) 前缀。
		profilePrefix = state.SessionPrefix
	}
	profileURL := p.endpointWithPrefix(profilePrefix, "/student/default/getxscardinfo")
	profile, err := p.fetchGraduateProfile(ctx, client, profileURL, state.LoginPageURL)
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	if profile.StudentID != request.StudentID {
		return AcademicVerifiedProfile{}, ErrAcademicIdentityMismatch
	}
	return profile, nil
}

// fetchGraduateProfile 先走探针确认成功的 GET；学校不同版本若只接受 POST，
// 则用同一 Cookie 和同源地址回退空表单 POST。HTML 登录页代表会话过期，
// 需要客户端重新 challenge，不能把它当成可信 profile。
func (p *GraduateAcademicIdentityProvider) fetchGraduateProfile(ctx context.Context, client *http.Client, endpoint, referer string) (AcademicVerifiedProfile, error) {
	var firstErr error
	getRequest, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?_="+fmt.Sprintf("%d", time.Now().UnixMilli()), nil)
	if err == nil {
		setGraduateRequestHeaders(getRequest)
		getRequest.Header.Set("Referer", referer)
		response, requestErr := client.Do(getRequest)
		if requestErr == nil {
			body, readErr := readGraduateResponseBody(response)
			statusOK := response.StatusCode >= 200 && response.StatusCode < 300
			response.Body.Close()
			if readErr == nil && statusOK {
				profile, parseErr := parseGraduateProfileResponse(body)
				if parseErr == nil {
					return profile, nil
				}
				if graduateHTMLResponse(body) {
					firstErr = ErrAcademicChallengeRejected
				} else {
					firstErr = graduateProviderUnavailable("profile_get_decode", response.StatusCode)
				}
			} else {
				stage := "profile_get_status"
				if readErr != nil {
					stage = "profile_get_read"
				}
				firstErr = graduateProviderUnavailable(stage, response.StatusCode)
			}
		} else {
			firstErr = graduateProviderUnavailable("profile_get_transport", 0)
		}
	} else {
		firstErr = graduateProviderUnavailable("profile_get_request", 0)
	}

	postRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(nil))
	if err != nil {
		return AcademicVerifiedProfile{}, firstErr
	}
	setGraduateRequestHeaders(postRequest)
	postRequest.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	postRequest.Header.Set("X-Requested-With", "XMLHttpRequest")
	postRequest.Header.Set("Referer", referer)
	response, err := client.Do(postRequest)
	if err != nil {
		if firstErr == nil || errors.Is(firstErr, ErrAcademicProviderUnavailable) {
			return AcademicVerifiedProfile{}, graduateProviderUnavailable("profile_post_transport", 0)
		}
		return AcademicVerifiedProfile{}, firstErr
	}
	body, readErr := readGraduateResponseBody(response)
	statusOK := response.StatusCode >= 200 && response.StatusCode < 300
	response.Body.Close()
	if readErr != nil || !statusOK {
		if firstErr == nil || errors.Is(firstErr, ErrAcademicProviderUnavailable) {
			stage := "profile_post_status"
			if readErr != nil {
				stage = "profile_post_read"
			}
			return AcademicVerifiedProfile{}, graduateProviderUnavailable(stage, response.StatusCode)
		}
		return AcademicVerifiedProfile{}, firstErr
	}
	profile, parseErr := parseGraduateProfileResponse(body)
	if parseErr == nil {
		return profile, nil
	}
	if graduateHTMLResponse(body) {
		return AcademicVerifiedProfile{}, ErrAcademicChallengeRejected
	}
	if firstErr == nil || errors.Is(firstErr, ErrAcademicProviderUnavailable) {
		return AcademicVerifiedProfile{}, graduateProviderUnavailable("profile_post_decode", response.StatusCode)
	}
	return AcademicVerifiedProfile{}, firstErr
}

func graduateHTMLResponse(body []byte) bool {
	trimmed := strings.TrimSpace(strings.ToLower(string(body)))
	return strings.HasPrefix(trimmed, "<!doctype html") || strings.HasPrefix(trimmed, "<html") || strings.Contains(trimmed, "<title>登录")
}

func setGraduateRequestHeaders(request *http.Request) {
	request.Header.Set("User-Agent", graduateUserAgent)
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
}

func (p *GraduateAcademicIdentityProvider) newClient(jar http.CookieJar) *http.Client {
	baseOrigin := p.baseURL
	transport := http.DefaultTransport
	if p.transport != nil {
		transport = p.transport
	}
	return &http.Client{Jar: jar, Timeout: graduateProviderTimeout, Transport: transport, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if !sameGraduateOrigin(baseOrigin, request.URL) {
			return errors.New("研究生教务重定向跨源")
		}
		if len(via) >= 5 {
			return errors.New("研究生教务重定向过多")
		}
		return nil
	}}
}

func (p *GraduateAcademicIdentityProvider) endpoint(path string) string {
	return p.endpointWithPrefix("", path)
}

func (p *GraduateAcademicIdentityProvider) endpointWithPrefix(prefix, path string) string {
	prefix = strings.TrimRight(strings.TrimSpace(prefix), "/")
	if prefix != "" && !strings.HasPrefix(prefix, "/") {
		prefix = "/" + prefix
	}
	return strings.TrimRight(p.baseURL.String(), "/") + prefix + "/" + strings.TrimLeft(path, "/")
}

func readGraduateResponseBody(response *http.Response) ([]byte, error) {
	if response == nil || response.Body == nil {
		return nil, errors.New("空学校响应")
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, graduateMaxResponseBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > graduateMaxResponseBytes {
		return nil, errors.New("学校响应过大")
	}
	return body, nil
}

func extractGraduatePublicKey(body []byte) string {
	// 实测页面是 id 在前，但兼容同一 input 的属性顺序变化，避免把
	// 公钥提取实现绑定到模板排版。只接受明确标记为 #pubkey 的元素。
	if tag := graduatePubKeyTagPattern.Find(body); len(tag) > 0 {
		if matches := graduatePubKeyValuePattern.FindSubmatch(tag); len(matches) >= 2 {
			return strings.TrimSpace(html.UnescapeString(string(matches[1])))
		}
	}
	if matches := graduatePubKeyValueFirstPattern.FindSubmatch(body); len(matches) >= 2 {
		return strings.TrimSpace(html.UnescapeString(string(matches[1])))
	}
	return ""
}

func graduateSessionPrefix(path string) string {
	matches := graduateSessionPrefixPattern.FindStringSubmatch(path)
	if len(matches) == 2 {
		return matches[1]
	}
	return ""
}

func sameGraduateOrigin(expected, actual *url.URL) bool {
	return expected != nil && actual != nil && expected.Scheme == actual.Scheme && strings.EqualFold(expected.Host, actual.Host)
}

func graduateCookiesToHTTP(states []graduateCookieState) []*http.Cookie {
	result := make([]*http.Cookie, 0, len(states))
	for _, state := range states {
		if state.Name != "" {
			result = append(result, &http.Cookie{Name: state.Name, Value: state.Value, Path: state.Path, Domain: state.Domain, MaxAge: state.MaxAge, Expires: state.Expires, Secure: state.Secure, HttpOnly: state.HTTPOnly})
		}
	}
	return result
}

func graduatePublicKeyFingerprint(raw string) (string, error) {
	block, _ := pem.Decode([]byte(strings.TrimSpace(raw)))
	if block == nil {
		return "", errors.New("公钥不是 PEM")
	}
	var key interface{}
	var err error
	switch block.Type {
	case "PUBLIC KEY":
		key, err = x509.ParsePKIXPublicKey(block.Bytes)
	case "RSA PUBLIC KEY":
		key, err = x509.ParsePKCS1PublicKey(block.Bytes)
	default:
		return "", errors.New("不支持的公钥类型")
	}
	if err != nil {
		return "", err
	}
	if _, ok := key.(*rsa.PublicKey); !ok {
		return "", errors.New("学校公钥不是 RSA")
	}
	canonical, err := x509.MarshalPKIXPublicKey(key)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(canonical)
	return "sha256:" + base64.RawURLEncoding.EncodeToString(digest[:]), nil
}

func graduateCaptchaValue(raw string) interface{} {
	if len(raw) > 0 {
		allDigits := true
		for _, r := range raw {
			if r < '0' || r > '9' {
				allDigits = false
				break
			}
		}
		if allDigits {
			var value int
			_, _ = fmt.Sscanf(raw, "%d", &value)
			return value
		}
	}
	return raw
}

func decodeGraduateValue(body []byte) (interface{}, error) {
	text := strings.TrimSpace(string(body))
	var direct interface{}
	if json.Unmarshal([]byte(text), &direct) == nil {
		if encoded, ok := direct.(string); ok {
			text = encoded
		} else {
			return direct, nil
		}
	}
	decoded, err := base64.StdEncoding.DecodeString(text)
	if err != nil || len(decoded) == 0 || len(decoded)%aes.BlockSize != 0 {
		return nil, errors.New("学校响应不是 JSON 或 AES 密文")
	}
	block, err := aes.NewCipher([]byte(graduateAESKey))
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(decoded))
	for offset := 0; offset < len(decoded); offset += aes.BlockSize {
		block.Decrypt(plain[offset:offset+aes.BlockSize], decoded[offset:offset+aes.BlockSize])
	}
	if len(plain) == 0 {
		return nil, errors.New("学校响应为空")
	}
	padding := int(plain[len(plain)-1])
	if padding < 1 || padding > aes.BlockSize || padding > len(plain) {
		return nil, errors.New("学校响应填充无效")
	}
	for _, value := range plain[len(plain)-padding:] {
		if int(value) != padding {
			return nil, errors.New("学校响应填充无效")
		}
	}
	var result interface{}
	if err := json.Unmarshal(plain[:len(plain)-padding], &result); err != nil {
		return nil, err
	}
	return result, nil
}

func decodeGraduateJSON(body []byte) (map[string]interface{}, error) {
	value, err := decodeGraduateValue(body)
	if err != nil {
		return nil, err
	}
	result, ok := value.(map[string]interface{})
	if !ok {
		return nil, errors.New("学校响应不是 JSON 对象")
	}
	return result, nil
}

func graduateCaptchaError(result map[string]interface{}) bool {
	text := strings.ToLower(fmt.Sprint(result["msg"]))
	return strings.Contains(text, "验证码") || strings.Contains(text, "captcha") || strings.Contains(text, "vericode")
}

func parseGraduateProfile(body []byte) (AcademicVerifiedProfile, error) {
	var rows []map[string]interface{}
	if err := json.Unmarshal(body, &rows); err != nil {
		return AcademicVerifiedProfile{}, err
	}
	if len(rows) != 1 {
		return AcademicVerifiedProfile{}, errors.New("研究生 profile 数量不是唯一一条")
	}
	row := rows[0]
	studentID := strings.TrimSpace(fmt.Sprint(row["xh"]))
	if studentID == "" || studentID == "<nil>" {
		return AcademicVerifiedProfile{}, errors.New("研究生 profile 缺少 xh")
	}
	name := strings.TrimSpace(fmt.Sprint(row["xm"]))
	if name == "<nil>" {
		name = ""
	}
	return AcademicVerifiedProfile{ProviderID: models.AcademicProviderGraduate, StudentID: studentID, Name: name}, nil
}

func parseGraduateProfileResponse(body []byte) (AcademicVerifiedProfile, error) {
	value, err := decodeGraduateValue(body)
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	rows, ok := value.([]interface{})
	if !ok {
		return AcademicVerifiedProfile{}, errors.New("研究生 profile 不是 JSON 数组")
	}
	encoded, err := json.Marshal(rows)
	if err != nil {
		return AcademicVerifiedProfile{}, err
	}
	return parseGraduateProfile(encoded)
}

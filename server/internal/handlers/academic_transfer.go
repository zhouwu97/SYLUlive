package handlers

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

// 扫码同步是「网页出码、手机 App 扫码」的一次性中转：
// 网页把临时公钥放进二维码，App 用它加密本机教务资料后交给这里暂存，网页取走并解密。
// 服务端只见密文，且只放在进程内存里，不进数据库、日志和备份；
// 这延续了个人教务数据留在设备侧的边界（见 docs/privacy-data-inventory.md）。
//
// 进程内存意味着重启或多实例部署会让在途会话失效，用户重新出码即可；
// 若以后改成多实例，需要换成共享的短期存储，而不是把密文落库。
const (
	academicTransferTTL = 5 * time.Minute
	// 单个用户同时保留的会话数；多开标签页各自出码时淘汰最早的一个。
	academicTransferMaxSessionsPerUser = 3
	// 单用户 10 分钟内可创建的会话数，防止脚本刷码占用内存。
	academicTransferCreateWindow    = 10 * time.Minute
	academicTransferCreatePerWindow = 30
	// 密文上限按「多学期课表 + 存档 + 成绩 + 二课 + 体测」留出余量，
	// 同时低于全局 1 MiB 请求体上限（base64 后约 800 KiB）。
	academicTransferMaxCiphertext = 600 << 10
	// 全进程在途密文总量上限，超过后拒绝新上传而不是无限占用内存。
	academicTransferMaxTotalBytes = 96 << 20
	academicTransferRequestLimit  = 1 << 20
)

const (
	academicTransferPending = "pending"
	academicTransferClaimed = "claimed"
	academicTransferReady   = "ready"
)

type academicTransferPayload struct {
	AppPublicKey string `json:"app_public_key"`
	Nonce        string `json:"nonce"`
	Ciphertext   string `json:"ciphertext"`
}

type academicTransferSession struct {
	id        string
	userID    uint
	status    string
	createdAt time.Time
	sequence  uint64
	expiresAt time.Time
	payload   *academicTransferPayload
	size      int
}

// AcademicTransferHandler 保存在途的扫码同步会话。
type AcademicTransferHandler struct {
	mu         sync.Mutex
	sessions   map[string]*academicTransferSession
	created    map[uint][]time.Time
	totalBytes int
	sequence   uint64
	now        func() time.Time
}

func NewAcademicTransferHandler() *AcademicTransferHandler {
	return &AcademicTransferHandler{
		sessions: map[string]*academicTransferSession{},
		created:  map[uint][]time.Time{},
		now:      time.Now,
	}
}

func academicTransferError(c *gin.Context, status int, code, message string) {
	c.JSON(status, gin.H{"code": code, "message": message})
}

// 调用方必须持有 h.mu。
func (h *AcademicTransferHandler) removeLocked(id string) {
	session, ok := h.sessions[id]
	if !ok {
		return
	}
	h.totalBytes -= session.size
	delete(h.sessions, id)
}

// 调用方必须持有 h.mu。过期会话在每次访问时顺带清掉，不另起后台协程。
func (h *AcademicTransferHandler) purgeLocked(now time.Time) {
	for id, session := range h.sessions {
		if !now.Before(session.expiresAt) {
			h.removeLocked(id)
		}
	}
	for userID, stamps := range h.created {
		kept := stamps[:0]
		for _, stamp := range stamps {
			if now.Sub(stamp) < academicTransferCreateWindow {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == 0 {
			delete(h.created, userID)
		} else {
			h.created[userID] = kept
		}
	}
}

// 会话不存在与已过期对外是同一种结果；账号不一致单独提示，
// 因为会话 ID 不可猜测，能拿到 ID 的只有扫了这张码的人，他需要知道该换账号。
// 调用方必须持有 h.mu。
func (h *AcademicTransferHandler) ownedLocked(c *gin.Context, now time.Time) *academicTransferSession {
	h.purgeLocked(now)
	session, ok := h.sessions[c.Param("id")]
	if !ok {
		academicTransferError(c, http.StatusNotFound, "TRANSFER_SESSION_NOT_FOUND", "二维码已失效，请在网页重新生成")
		return nil
	}
	if session.userID != c.GetUint("user_id") {
		academicTransferError(c, http.StatusForbidden, "TRANSFER_ACCOUNT_MISMATCH", "App 与网页登录的不是同一个账号，请切换到相同账号后再扫码")
		return nil
	}
	return session
}

func academicTransferView(session *academicTransferSession, now time.Time) gin.H {
	remaining := int(session.expiresAt.Sub(now) / time.Second)
	if remaining < 0 {
		remaining = 0
	}
	return gin.H{
		"session_id":  session.id,
		"status":      session.status,
		"expires_at":  session.expiresAt.UTC().Format(time.RFC3339),
		"ttl_seconds": remaining,
	}
}

// Create 由网页调用：登记一个等待手机扫码的会话。
func (h *AcademicTransferHandler) Create(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	userID := c.GetUint("user_id")
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		academicTransferError(c, http.StatusServiceUnavailable, "TRANSFER_UNAVAILABLE", "暂时无法生成二维码，请稍后重试")
		return
	}
	now := h.now()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.purgeLocked(now)
	if len(h.created[userID]) >= academicTransferCreatePerWindow {
		c.Header("Retry-After", strconv.Itoa(int(academicTransferCreateWindow/time.Second)))
		academicTransferError(c, http.StatusTooManyRequests, "TRANSFER_RATE_LIMITED", "生成二维码过于频繁，请稍后再试")
		return
	}
	own := make([]*academicTransferSession, 0, academicTransferMaxSessionsPerUser)
	for _, session := range h.sessions {
		if session.userID == userID {
			own = append(own, session)
		}
	}
	// 同一时间创建的会话也按实际创建顺序淘汰，不依赖 map 遍历顺序。
	sort.Slice(own, func(i, j int) bool { return own[i].sequence < own[j].sequence })
	for len(own) >= academicTransferMaxSessionsPerUser {
		h.removeLocked(own[0].id)
		own = own[1:]
	}
	h.sequence++
	session := &academicTransferSession{
		id:        base64.RawURLEncoding.EncodeToString(raw),
		userID:    userID,
		status:    academicTransferPending,
		createdAt: now,
		sequence:  h.sequence,
		expiresAt: now.Add(academicTransferTTL),
	}
	h.sessions[session.id] = session
	h.created[userID] = append(h.created[userID], now)
	c.JSON(http.StatusCreated, academicTransferView(session, now))
}

// Get 由网页轮询：手机上传后随状态一并返回密文。
// 密文在网页确认收到（Delete）或会话过期前可重复读取，避免一次响应丢失就要求用户重扫。
func (h *AcademicTransferHandler) Get(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	now := h.now()
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.ownedLocked(c, now)
	if session == nil {
		return
	}
	view := academicTransferView(session, now)
	if session.payload != nil {
		view["payload"] = session.payload
	}
	c.Header("Cache-Control", "no-store")
	c.JSON(http.StatusOK, view)
}

// Claim 由 App 扫码后调用：只表示「同一账号的手机已扫到这张码」，尚未上传任何资料。
func (h *AcademicTransferHandler) Claim(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	now := h.now()
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.ownedLocked(c, now)
	if session == nil {
		return
	}
	if session.status == academicTransferReady {
		academicTransferError(c, http.StatusConflict, "TRANSFER_ALREADY_UPLOADED", "这张二维码已经完成过一次同步，请在网页重新生成")
		return
	}
	session.status = academicTransferClaimed
	c.JSON(http.StatusOK, academicTransferView(session, now))
}

func decodeAcademicTransferField(value string, maxEncoded int) ([]byte, bool) {
	if value == "" || len(value) > maxEncoded {
		return nil, false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	return decoded, err == nil
}

// Upload 由 App 在用户确认后调用：只接受一次，且必须先 Claim。
func (h *AcademicTransferHandler) Upload(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	var input academicTransferPayload
	decoder := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, academicTransferRequestLimit))
	// 只接受密文信封的三个字段，明文资料或凭据误传会被直接拒绝。
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			academicTransferError(c, http.StatusRequestEntityTooLarge, "TRANSFER_PAYLOAD_TOO_LARGE", "资料超过单次同步上限，请减少同步内容后重试")
			return
		}
		academicTransferError(c, http.StatusBadRequest, "INVALID_TRANSFER_PAYLOAD", "同步内容格式不正确")
		return
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		academicTransferError(c, http.StatusBadRequest, "INVALID_TRANSFER_PAYLOAD", "同步内容格式不正确")
		return
	}
	// P-256 未压缩点 65 字节、GCM 随机数 12 字节；密文至少包含 16 字节认证标签。
	publicKey, okKey := decodeAcademicTransferField(input.AppPublicKey, 96)
	nonce, okNonce := decodeAcademicTransferField(input.Nonce, 24)
	if !okKey || !okNonce || len(nonce) != 12 {
		academicTransferError(c, http.StatusBadRequest, "INVALID_TRANSFER_PAYLOAD", "同步内容格式不正确")
		return
	}
	if _, err := ecdh.P256().NewPublicKey(publicKey); len(publicKey) != 65 || err != nil {
		academicTransferError(c, http.StatusBadRequest, "INVALID_TRANSFER_PAYLOAD", "同步内容格式不正确")
		return
	}
	if base64.RawURLEncoding.DecodedLen(len(input.Ciphertext)) > academicTransferMaxCiphertext {
		academicTransferError(c, http.StatusRequestEntityTooLarge, "TRANSFER_PAYLOAD_TOO_LARGE", "资料超过单次同步上限，请减少同步内容后重试")
		return
	}
	ciphertext, okCipher := decodeAcademicTransferField(input.Ciphertext, len(input.Ciphertext))
	if !okCipher || len(ciphertext) <= 16 {
		academicTransferError(c, http.StatusBadRequest, "INVALID_TRANSFER_PAYLOAD", "同步内容格式不正确")
		return
	}
	size := len(input.AppPublicKey) + len(input.Nonce) + len(input.Ciphertext)

	now := h.now()
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.ownedLocked(c, now)
	if session == nil {
		return
	}
	switch session.status {
	case academicTransferReady:
		academicTransferError(c, http.StatusConflict, "TRANSFER_ALREADY_UPLOADED", "这张二维码已经完成过一次同步，请在网页重新生成")
		return
	case academicTransferPending:
		academicTransferError(c, http.StatusConflict, "TRANSFER_NOT_CLAIMED", "请先在 App 中确认本次同步")
		return
	}
	if h.totalBytes+size > academicTransferMaxTotalBytes {
		academicTransferError(c, http.StatusServiceUnavailable, "TRANSFER_BUSY", "同步服务繁忙，请稍后重试")
		return
	}
	session.payload = &input
	session.size = size
	session.status = academicTransferReady
	h.totalBytes += size
	c.JSON(http.StatusOK, academicTransferView(session, now))
}

// Delete 由任一端调用：网页收到并解密后确认清除，或任一端取消本次同步。
func (h *AcademicTransferHandler) Delete(c *gin.Context) {
	if !configUserMatches(c) {
		return
	}
	now := h.now()
	h.mu.Lock()
	defer h.mu.Unlock()
	h.purgeLocked(now)
	session, ok := h.sessions[c.Param("id")]
	// 重复清除保持幂等；别人的会话与不存在同样回 204，不泄露存在性也不执行删除。
	if ok && session.userID == c.GetUint("user_id") {
		h.removeLocked(session.id)
	}
	c.Status(http.StatusNoContent)
}

package handlers

import (
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/gin-gonic/gin"
)

const messageEventBufferSize = 32

type privateMessageEvent struct {
	Type           string             `json:"type"`
	ConversationID uint               `json:"conversation_id"`
	Message        *PrivateMessageDTO `json:"message,omitempty"`
	ReadByUserID   uint               `json:"read_by_user_id,omitempty"`
	ReadThroughID  uint               `json:"read_through_message_id,omitempty"`
	ReadAt         *time.Time         `json:"read_at,omitempty"`
}

// messageEventBroker 负责单进程内的前台实时事件分发。
// 后台和跨实例丢失事件仍由极光推送与客户端兜底同步补齐。
type messageEventBroker struct {
	mu          sync.RWMutex
	nextID      uint64
	subscribers map[uint]map[uint64]chan privateMessageEvent
}

func newMessageEventBroker() *messageEventBroker {
	return &messageEventBroker{
		subscribers: make(map[uint]map[uint64]chan privateMessageEvent),
	}
}

func (b *messageEventBroker) subscribe(userID uint) (<-chan privateMessageEvent, func()) {
	b.mu.Lock()
	b.nextID++
	subscriberID := b.nextID
	channel := make(chan privateMessageEvent, messageEventBufferSize)
	if b.subscribers[userID] == nil {
		b.subscribers[userID] = make(map[uint64]chan privateMessageEvent)
	}
	b.subscribers[userID][subscriberID] = channel
	b.mu.Unlock()

	return channel, func() {
		b.mu.Lock()
		delete(b.subscribers[userID], subscriberID)
		if len(b.subscribers[userID]) == 0 {
			delete(b.subscribers, userID)
		}
		b.mu.Unlock()
	}
}

func (b *messageEventBroker) publish(userIDs []uint, event privateMessageEvent) {
	seen := make(map[uint]struct{}, len(userIDs))
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, userID := range userIDs {
		if userID == 0 {
			continue
		}
		if _, exists := seen[userID]; exists {
			continue
		}
		seen[userID] = struct{}{}
		for _, channel := range b.subscribers[userID] {
			select {
			case channel <- event:
			default:
				// 慢客户端会通过下一次兜底同步恢复，不阻塞消息发送事务。
			}
		}
	}
}

// Events 通过 SSE 向前台客户端推送私信增量事件。
func (h *MessageHandler) Events(c *gin.Context) {
	userID := c.GetUint("user_id")
	events, unsubscribe := h.events.subscribe(userID)
	defer unsubscribe()

	c.Header("Content-Type", "text/event-stream")
	c.Header("Cache-Control", "no-cache, no-transform")
	c.Header("Connection", "keep-alive")
	c.Header("X-Accel-Buffering", "no")
	c.Status(http.StatusOK)

	heartbeat := time.NewTicker(20 * time.Second)
	defer heartbeat.Stop()
	c.Stream(func(writer io.Writer) bool {
		select {
		case <-c.Request.Context().Done():
			return false
		case event := <-events:
			c.SSEvent(event.Type, event)
			return true
		case now := <-heartbeat.C:
			c.SSEvent("ping", gin.H{"time": now.UTC()})
			return true
		}
	})
}

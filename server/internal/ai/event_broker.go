package ai

import (
	"sync"
	"time"
)

type RunEvent struct {
	RunID     string      `json:"run_id"`
	Seq       int64       `json:"seq"`
	Type      string      `json:"type"`
	Timestamp time.Time   `json:"timestamp"`
	Payload   interface{} `json:"payload"`
	Persisted bool        `json:"-"`
}

// EventBroker 只承载在线增量。断线恢复始终以 PostgreSQL 检查点为准。
type EventBroker struct {
	mu          sync.RWMutex
	subscribers map[string]map[uint64]chan RunEvent
	nextID      uint64
}

func NewEventBroker() *EventBroker {
	return &EventBroker{subscribers: make(map[string]map[uint64]chan RunEvent)}
}

func (b *EventBroker) Subscribe(runID string) (<-chan RunEvent, func()) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.nextID++
	id := b.nextID
	channel := make(chan RunEvent, 64)
	if b.subscribers[runID] == nil {
		b.subscribers[runID] = make(map[uint64]chan RunEvent)
	}
	b.subscribers[runID][id] = channel
	return channel, func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if subscribers := b.subscribers[runID]; subscribers != nil {
			if current, ok := subscribers[id]; ok {
				delete(subscribers, id)
				close(current)
			}
			if len(subscribers) == 0 {
				delete(b.subscribers, runID)
			}
		}
	}
}

func (b *EventBroker) Publish(event RunEvent) {
	b.mu.Lock()
	defer b.mu.Unlock()
	subscribers := b.subscribers[event.RunID]
	for id, channel := range subscribers {
		select {
		case channel <- event:
		default:
			// 增量可丢弃；持久化事件必须触发断线恢复，避免客户端遗漏终态。
			if event.Persisted {
				delete(subscribers, id)
				close(channel)
			}
		}
	}
	if len(subscribers) == 0 {
		delete(b.subscribers, event.RunID)
	}
}

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
	b.mu.RLock()
	defer b.mu.RUnlock()
	for _, channel := range b.subscribers[event.RunID] {
		select {
		case channel <- event:
		default:
			// 慢客户端会通过持久化检查点恢复，不能反向阻塞模型流。
		}
	}
}

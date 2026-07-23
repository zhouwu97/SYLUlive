package ai

import (
	"sync"
	"testing"
	"time"
)

func TestEventBrokerDisconnectsSlowSubscriberBeforeDroppingPersistentEvent(t *testing.T) {
	broker := NewEventBroker()
	events, unsubscribe := broker.Subscribe("run-1")
	defer unsubscribe()

	for seq := int64(1); seq <= 64; seq++ {
		broker.Publish(RunEvent{RunID: "run-1", Seq: seq, Type: "answer.delta", Timestamp: time.Now()})
	}
	broker.Publish(RunEvent{RunID: "run-1", Seq: 65, Type: "run.completed", Timestamp: time.Now(), Persisted: true})

	for index := 0; index < 64; index++ {
		<-events
	}
	select {
	case _, open := <-events:
		if open {
			t.Fatal("持久化事件溢出后慢订阅者仍保持连接")
		}
	case <-time.After(time.Second):
		t.Fatal("慢订阅者未及时断开")
	}
}

func TestEventBrokerConcurrentPublishSubscribeAndUnsubscribe(t *testing.T) {
	broker := NewEventBroker()
	var wait sync.WaitGroup
	for worker := 0; worker < 16; worker++ {
		wait.Add(1)
		go func(worker int) {
			defer wait.Done()
			for iteration := 0; iteration < 200; iteration++ {
				events, unsubscribe := broker.Subscribe("run-concurrent")
				broker.Publish(RunEvent{RunID: "run-concurrent", Type: "answer.delta", Timestamp: time.Now()})
				if iteration%10 == 0 {
					broker.Publish(RunEvent{RunID: "run-concurrent", Type: "answer.checkpoint", Timestamp: time.Now(), Persisted: true})
				}
				select {
				case <-events:
				default:
				}
				unsubscribe()
			}
		}(worker)
	}
	wait.Wait()
}

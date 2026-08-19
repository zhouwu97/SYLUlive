package services

import (
	"sync"
	"time"
)

// discoveryCacheEntry 一条缓存记录。
type discoveryCacheEntry struct {
	data      interface{}
	expiresAt time.Time
}

// CanteenDiscoveryCache 发现页/排行页的内存缓存（读多写少，TTL 到期 + 主动失效）。
// 与 middleware.tokenVersionCache 同模式，不引入外部缓存依赖。
type CanteenDiscoveryCache struct {
	mu     sync.Mutex
	values map[string]discoveryCacheEntry
	ttl    time.Duration
}

// NewCanteenDiscoveryCache 创建缓存，ttl<=0 时视为永久（由调用方决定失效策略）。
func NewCanteenDiscoveryCache(ttl time.Duration) *CanteenDiscoveryCache {
	return &CanteenDiscoveryCache{
		values: map[string]discoveryCacheEntry{},
		ttl:    ttl,
	}
}

// Get 返回命中且未过期的数据；未命中返回 ok=false。
func (c *CanteenDiscoveryCache) Get(key string) (interface{}, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.values[key]
	if !ok {
		return nil, false
	}
	if c.ttl > 0 && time.Now().After(e.expiresAt) {
		delete(c.values, key)
		return nil, false
	}
	return e.data, true
}

// Set 写入缓存（覆盖同 key）。
func (c *CanteenDiscoveryCache) Set(key string, data interface{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values[key] = discoveryCacheEntry{
		data:      data,
		expiresAt: time.Now().Add(c.ttl),
	}
}

// Invalidate 清空全部缓存（本模块变更不区分 key，整体失效更简单安全）。
func (c *CanteenDiscoveryCache) Invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.values = map[string]discoveryCacheEntry{}
}

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
// 引入 generation 机制防止并发失效期间的陈旧数据覆盖回写。
type CanteenDiscoveryCache struct {
	mu         sync.Mutex
	values     map[string]discoveryCacheEntry
	ttl        time.Duration
	generation uint64
}

// NewCanteenDiscoveryCache 创建缓存，ttl<=0 时视为永久（由调用方决定失效策略）。
func NewCanteenDiscoveryCache(ttl time.Duration) *CanteenDiscoveryCache {
	return &CanteenDiscoveryCache{
		values: map[string]discoveryCacheEntry{},
		ttl:    ttl,
	}
}

// Generation 获取当前缓存版本代数。
func (c *CanteenDiscoveryCache) Generation() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.generation
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

// SetIfGeneration 仅在 generation 未发生变更时写入缓存；若期间发生过 Invalidate 则拒绝写入，防止陈旧数据回写。
func (c *CanteenDiscoveryCache) SetIfGeneration(key string, data interface{}, generation uint64) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if generation != c.generation {
		return false
	}
	c.values[key] = discoveryCacheEntry{
		data:      data,
		expiresAt: time.Now().Add(c.ttl),
	}
	return true
}

// Invalidate 清空全部缓存并递增 generation（防止并发中的旧请求在 Invalidate 后将陈旧数据写回缓存）。
func (c *CanteenDiscoveryCache) Invalidate() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.generation++
	c.values = map[string]discoveryCacheEntry{}
}

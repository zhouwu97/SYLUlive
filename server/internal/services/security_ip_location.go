package services

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/lionsoul2014/ip2region/binding/golang/xdb"
)

// SecurityIPLocation 仅包含国家、省、市；不返回经纬度或精确住址。
type SecurityIPLocation struct {
	Region string `json:"region"`
	Status string `json:"status"`
}

type SecurityIPLocator interface {
	Lookup(string) SecurityIPLocation
	State() (string, string)
}

type offlineIPSearcher struct {
	mu       sync.Mutex // xdb.Searcher 的计数器会写入内部状态，必须串行调用。
	searcher *xdb.Searcher
	failed   atomic.Bool
}

type OfflineSecurityIPLocator struct {
	v4, v6 *offlineIPSearcher
}

// NewOfflineSecurityIPLocator 仅在启动时读本地库；请求链路不下载、不联网。
// 单个库不可用时保留另一个库的能力，并在安全中心如实显示降级。
func NewOfflineSecurityIPLocator(v4Path, v6Path string) (*OfflineSecurityIPLocator, error) {
	if v4Path == "" {
		v4Path = "data/geoip/ip2region_v4.xdb"
	}
	if v6Path == "" {
		v6Path = "data/geoip/ip2region_v6.xdb"
	}
	l := &OfflineSecurityIPLocator{}
	var errs []error
	for _, item := range []struct {
		path    string
		version *xdb.Version
		dst     **offlineIPSearcher
	}{
		{v4Path, xdb.IPv4, &l.v4}, {v6Path, xdb.IPv6, &l.v6},
	} {
		searcher, err := loadOfflineIPSearcher(item.path, item.version)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s 离线库不可用: %w", item.version.Name, err))
			continue
		}
		*item.dst = searcher
	}
	return l, errors.Join(errs...)
}

func loadOfflineIPSearcher(path string, version *xdb.Version) (*offlineIPSearcher, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() < 524544 || info.Size() > 64<<20 {
		return nil, errors.New("离线库文件大小无效")
	}
	if err := xdb.VerifyFromFile(path); err != nil {
		return nil, err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	header, err := xdb.LoadHeaderFromBuff(content)
	if err != nil {
		return nil, err
	}
	actual, err := xdb.VersionFromHeader(header)
	if err != nil || actual.Id != version.Id {
		return nil, errors.New("离线库 IP 版本不匹配")
	}
	searcher, err := xdb.NewWithBuffer(version, content)
	if err != nil {
		return nil, err
	}
	return &offlineIPSearcher{searcher: searcher}, nil
}

func (l *OfflineSecurityIPLocator) State() (string, string) {
	if l == nil {
		return "unavailable", "IPv4/IPv6 离线库未加载"
	}
	v4Ready := l.v4 != nil && !l.v4.failed.Load()
	v6Ready := l.v6 != nil && !l.v6.failed.Load()
	if !v4Ready && !v6Ready {
		return "unavailable", "IPv4/IPv6 离线库未加载或查询失败"
	}
	if !v4Ready || !v6Ready {
		return "degraded", "仅一个 IP 版本的离线库已加载"
	}
	return "ready", "IPv4/IPv6 离线查询，不向第三方发送 IP"
}

func (l *OfflineSecurityIPLocator) Lookup(raw string) (result SecurityIPLocation) {
	address, err := netip.ParseAddr(raw)
	if err != nil || address.Zone() != "" {
		return SecurityIPLocation{Status: "unknown"}
	}
	address = address.Unmap()
	if address.IsLoopback() {
		return SecurityIPLocation{Region: "本机回环地址", Status: "local"}
	}
	if address.IsPrivate() || address.IsLinkLocalUnicast() || netip.MustParsePrefix("100.64.0.0/10").Contains(address) {
		return SecurityIPLocation{Region: "内网／共享地址", Status: "private"}
	}
	if !address.IsGlobalUnicast() || isDocumentationIP(address) {
		return SecurityIPLocation{Region: "保留／测试地址", Status: "reserved"}
	}
	if l == nil {
		return SecurityIPLocation{Status: "database_unavailable"}
	}
	db := l.v6
	if address.Is4() {
		db = l.v4
	}
	if db == nil {
		return SecurityIPLocation{Status: "database_unavailable"}
	}
	db.mu.Lock()
	defer db.mu.Unlock()
	// 被替换或损坏的本地库不能让管理接口因第三方读取器越界而崩溃。
	defer func() {
		if recover() != nil {
			db.failed.Store(true)
			result = SecurityIPLocation{Status: "database_error"}
		}
	}()
	region, err := db.searcher.Search(address.String())
	if err != nil {
		db.failed.Store(true)
		return SecurityIPLocation{Status: "database_error"}
	}
	db.failed.Store(false)
	region = coarseIPRegion(region)
	if region == "" {
		return SecurityIPLocation{Status: "unknown"}
	}
	return SecurityIPLocation{Region: region, Status: "resolved"}
}

func isDocumentationIP(address netip.Addr) bool {
	for _, raw := range []string{"192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32", "198.18.0.0/15"} {
		if netip.MustParsePrefix(raw).Contains(address) {
			return true
		}
	}
	return false
}

func coarseIPRegion(raw string) string {
	parts := strings.Split(raw, "|")
	if len(parts) < 3 {
		return ""
	}
	result := make([]string, 0, 3)
	for _, part := range parts[:3] {
		part = strings.TrimSpace(part)
		if part == "" || part == "0" || len(part) > 160 {
			continue
		}
		duplicate := false
		for _, existing := range result {
			if existing == part {
				duplicate = true
			}
		}
		if !duplicate {
			result = append(result, part)
		}
	}
	return strings.Join(result, " · ")
}

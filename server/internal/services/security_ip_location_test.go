package services

import (
	"encoding/binary"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/lionsoul2014/ip2region/binding/golang/xdb"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// 最小合法 xdb 夹具：只含一个地址段，不依赖网络或仓库外的大型数据文件。
func writeTestIPDatabase(t *testing.T, ip, region string, version *xdb.Version) string {
	t.Helper()
	address := netip.MustParseAddr(ip).AsSlice()
	index := 524544
	data := make([]byte, index+version.SegmentIndexSize+len(region))
	binary.LittleEndian.PutUint16(data, 3)
	binary.LittleEndian.PutUint16(data[2:], 1)
	binary.LittleEndian.PutUint32(data[8:], uint32(index))
	binary.LittleEndian.PutUint32(data[12:], uint32(index))
	binary.LittleEndian.PutUint16(data[16:], uint16(version.Id))
	binary.LittleEndian.PutUint16(data[18:], 4)
	vector := 256 + (int(address[0])*256+int(address[1]))*8
	binary.LittleEndian.PutUint32(data[vector:], uint32(index))
	binary.LittleEndian.PutUint32(data[vector+4:], uint32(index))
	encoded := append([]byte(nil), address...)
	if version.Id == 4 {
		for i, j := 0, len(encoded)-1; i < j; i, j = i+1, j-1 {
			encoded[i], encoded[j] = encoded[j], encoded[i]
		}
	}
	copy(data[index:], encoded)
	copy(data[index+version.Bytes:], encoded)
	binary.LittleEndian.PutUint16(data[index+version.Bytes*2:], uint16(len(region)))
	binary.LittleEndian.PutUint32(data[index+version.Bytes*2+2:], uint32(index+version.SegmentIndexSize))
	copy(data[index+version.SegmentIndexSize:], region)
	path := filepath.Join(t.TempDir(), "test.xdb")
	require.NoError(t, os.WriteFile(path, data, 0600))
	return path
}

func TestOfflineSecurityIPLocatorDualStackAndConcurrentQueries(t *testing.T) {
	v4 := writeTestIPDatabase(t, "1.2.3.4", "中国|辽宁省|沈阳市|测试运营商|CN", xdb.IPv4)
	v6 := writeTestIPDatabase(t, "240e:abcd::1", "中国|北京市|北京市|测试运营商|CN", xdb.IPv6)
	locator, err := NewOfflineSecurityIPLocator(v4, v6)
	require.NoError(t, err)
	state, _ := locator.State()
	require.Equal(t, "ready", state)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			assert.Equal(t, SecurityIPLocation{Region: "中国 · 辽宁省 · 沈阳市", Status: "resolved"}, locator.Lookup("::ffff:1.2.3.4"))
			assert.Equal(t, "中国 · 北京市", locator.Lookup("240e:abcd::1").Region)
		}()
	}
	wg.Wait()
	require.Equal(t, "unknown", locator.Lookup("8.8.8.8").Status)
}

func TestOfflineSecurityIPLocatorUnavailableSpecialAndCorruptDatabases(t *testing.T) {
	locator, err := NewOfflineSecurityIPLocator(filepath.Join(t.TempDir(), "missing4"), filepath.Join(t.TempDir(), "missing6"))
	require.Error(t, err)
	state, _ := locator.State()
	require.Equal(t, "unavailable", state)
	for ip, status := range map[string]string{"192.168.1.2": "private", "100.64.1.2": "private", "::1": "local", "203.0.113.1": "reserved", "2001:db8::1": "reserved", "garbage": "unknown", "8.8.8.8": "database_unavailable"} {
		require.Equal(t, status, locator.Lookup(ip).Status)
	}
	v4 := writeTestIPDatabase(t, "1.2.3.4", "中国|辽宁省|沈阳市|ISP|CN", xdb.IPv4)
	locator, err = NewOfflineSecurityIPLocator(v4, v4)
	require.Error(t, err)
	state, _ = locator.State()
	require.Equal(t, "degraded", state)
	file := filepath.Join(t.TempDir(), "bad.xdb")
	require.NoError(t, os.WriteFile(file, []byte("corrupt"), 0600))
	_, err = loadOfflineIPSearcher(file, xdb.IPv4)
	require.Error(t, err)
	// 合法头部配损坏的索引也必须降级，不能 panic。
	content, err := os.ReadFile(v4)
	require.NoError(t, err)
	vector := 256 + (1*256+2)*8
	binary.LittleEndian.PutUint32(content[vector:], 0x7fffffff)
	binary.LittleEndian.PutUint32(content[vector+4:], 0x7fffffff)
	searcher, err := xdb.NewWithBuffer(xdb.IPv4, content)
	require.NoError(t, err)
	locator.v4 = &offlineIPSearcher{searcher: searcher}
	require.Equal(t, "database_error", locator.Lookup("1.2.3.4").Status)
	state, _ = locator.State()
	require.Equal(t, "unavailable", state)
}

func TestOfflineSecurityIPRealDatabase(t *testing.T) {
	v4, v6 := os.Getenv("SECURITY_TEST_IP_V4_DB"), os.Getenv("SECURITY_TEST_IP_V6_DB")
	if v4 == "" || v6 == "" {
		t.Skip("实际离线库由构建阶段安装，设置 SECURITY_TEST_IP_V4_DB / V6_DB 执行数据冒烟")
	}
	locator, err := NewOfflineSecurityIPLocator(v4, v6)
	require.NoError(t, err)
	for _, ip := range []string{"223.5.5.5", "2400:3200::1", "8.8.8.8", "2001:4860:4860::8888"} {
		result := locator.Lookup(ip)
		require.Equal(t, "resolved", result.Status)
		require.NotEmpty(t, result.Region)
		t.Log(ip, result.Region)
	}
}

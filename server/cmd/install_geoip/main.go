// install_geoip 只在开发／构建阶段下载固定版本的公开离线库；不处理任何用户 IP。
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

const revision = "70d862dbc7ee26c7de6e1adf4c25e63250de2606"

var databases = []struct{ name, sha256 string }{
	{"ip2region_v4.xdb", "27ecba8c9a6d5e3b280aedbe7ee15c65372b179fbd0dad3845d8c608f2fcace1"},
	{"ip2region_v6.xdb", "939f6b46bd2b8bec3cf7c5ceb8ba782266ae9b1f35b5ba7916700dec0b7506ed"},
}

func main() {
	dir := flag.String("dir", "data/geoip", "离线库安装目录")
	flag.Parse()
	if err := os.MkdirAll(*dir, 0755); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	client := &http.Client{Timeout: 2 * time.Minute}
	for _, db := range databases {
		if err := install(client, *dir, db.name, db.sha256); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println("verified", db.name, db.sha256)
	}
}

func install(client *http.Client, dir, name, expected string) error {
	destination := filepath.Join(dir, name)
	if file, err := os.Open(destination); err == nil {
		hash := sha256.New()
		_, copyErr := io.Copy(hash, file)
		file.Close()
		if copyErr == nil && hex.EncodeToString(hash.Sum(nil)) == expected {
			return nil
		}
	}
	response, err := client.Get("https://raw.githubusercontent.com/lionsoul2014/ip2region/" + revision + "/data/" + name)
	if err != nil {
		return fmt.Errorf("下载 %s 失败: %w", name, err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("下载 %s: HTTP %d", name, response.StatusCode)
	}
	file, err := os.CreateTemp(dir, ".ip2region-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	hash := sha256.New()
	count, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(response.Body, (64<<20)+1))
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	if count > 64<<20 || hex.EncodeToString(hash.Sum(nil)) != expected {
		return fmt.Errorf("%s 离线库校验失败", name)
	}
	return os.Rename(file.Name(), destination)
}

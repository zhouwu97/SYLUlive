package utils

import (
	"crypto/md5"
	"encoding/hex"
	"sort"
	"strings"
)

// GenerateEpaySign 生成易支付 V1 接口的 MD5 签名。
//
// 签名规则：
//  1. 过滤掉键名为 sign、sign_type 的参数，以及值为空的参数。
//  2. 将剩余参数按键名 (A→Z) 字典序升序排列。
//  3. 拼接为 key1=value1&key2=value2 格式。
//  4. 在末尾直接追加商户密钥 key。
//  5. 对整串做 MD5，返回 32 位小写十六进制字符串。
func GenerateEpaySign(params map[string]string, key string) string {
	var keys []string
	for k, v := range params {
		if k == "sign" || k == "sign_type" || v == "" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var sb strings.Builder
	for i, k := range keys {
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(params[k])
		if i < len(keys)-1 {
			sb.WriteString("&")
		}
	}
	sb.WriteString(key)

	hash := md5.Sum([]byte(sb.String()))
	return hex.EncodeToString(hash[:])
}

// GenerateVmqSign 生成 V免签 MD5 签名：MD5(payId + param + type + price + key)
func GenerateVmqSign(payId, param, ttype, price, key string) string {
	signPayload := payId + param + ttype + price + key
	hash := md5.Sum([]byte(signPayload))
	return hex.EncodeToString(hash[:])
}

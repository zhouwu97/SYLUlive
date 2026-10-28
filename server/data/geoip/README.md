# 安全预警离线 IP 库

查询使用 ip2region 的 IPv4／IPv6 xdb，不调用在线定位接口；只显示国家、省、市，不推断用户实际住址。

- 上游：[lionsoul2014/ip2region](https://github.com/lionsoul2014/ip2region/tree/70d862dbc7ee26c7de6e1adf4c25e63250de2606)
- 固定提交：`70d862dbc7ee26c7de6e1adf4c25e63250de2606`
- 代码与数据许可遵循上游 [LICENSE](https://github.com/lionsoul2014/ip2region/blob/70d862dbc7ee26c7de6e1adf4c25e63250de2606/LICENSE)（Apache-2.0）；更新前需复核许可和数据格式。
- 新增 Go 依赖只用于本地 xdb 读取；版本与数据提交一致，不升级其他已有依赖。

| 文件 | SHA-256 |
| --- | --- |
| ip2region_v4.xdb | `27ecba8c9a6d5e3b280aedbe7ee15c65372b179fbd0dad3845d8c608f2fcace1` |
| ip2region_v6.xdb | `939f6b46bd2b8bec3cf7c5ceb8ba782266ae9b1f35b5ba7916700dec0b7506ed` |

在 `server/` 执行 `go run ./cmd/install_geoip` 安装；构建阶段只请求这些公开数据文件，不包含任何用户 IP。下载使用 HTTPS，固定提交与 SHA-256 双重校验，通过后才替换文件。`.xdb` 是可重新获取的大型数据文件，忽略提交；Docker 在构建阶段下载并复制到运行镜像。

更新时同时修改安装器内固定提交、校验值和 Go 依赖版本，再运行双栈、并发、损坏库测试及一次实际离线查询。服务启动时加载到内存；替换数据后需重启服务才能生效。未加载某一地址族时只降级该地址族。内网、回环、保留／测试地址显示地址类型，不伪造地理位置。数据只代表网络出口的大致归属地，可能与使用者所在地不同。

回退到上一个服务版本和对应离线库即可；IP 密文列是向后兼容新增字段，不需要回退删除数据。安全 HMAC 密钥派生独立用途的 AES-GCM 密钥，轮换后旧 IP 密文显示「暂不可读取」，不会尝试从摘要还原 IP。

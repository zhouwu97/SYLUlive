# paper-storage 同机部署

此目录只安装独立用户、数据目录、二进制、systemd unit 和一个 Nginx site；不会覆盖全局 `nginx.conf`，也不会修改 UFW、SSH、PostgreSQL、Swap 或 `shenliyuan`。

先构建 Linux 二进制并为 `paper.sylulive.online` 准备证书，再执行：

```sh
PAPER_STORAGE_BINARY=/path/to/paper-storage sh ./install.sh
```

首次安装会保留含占位符的 `/etc/sylg-paper-storage.env`，此时不会启动服务。写入两把不同且不少于 32 字节的随机密钥后重新执行安装脚本，最后运行 `sh ./verify.sh`。

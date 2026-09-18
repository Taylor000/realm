# Realm

## 安装

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

仅跳过安装脚本中的 nft 清理步骤：

```bash
KEEP_NFT=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

## 配置

配置文件：`/etc/nat.conf`

```text
本地端口:远程IP或域名:远程端口
33351:node.example.com:33344
33352:[2001:db8::1]:443
```

## 管理

```bash
systemctl status realm
systemctl restart realm
journalctl -fu realm
forward-status
```

## 与 nftables-nat-rust 的关系

- 两个项目在三段式模式下共用 `/etc/nat.conf`，切换时会先备份并保留该文件。
- `realm.service` 与 `nat.service` 互斥，只应启用其中一个。
- Realm 使用用户态进程转发；nftables-nat-rust 使用 nftables DNAT 规则。
- Realm 只读取 `本地端口:远程地址:远程端口` 格式。
- `SINGLE`、`RANGE`、`REDIRECT`、`DROP` 和 TOML 配置只能由 nftables-nat-rust 使用。切到 Realm 前应先改成三段式规则。
- `KEEP_NFT=1` 只跳过安装脚本的 nft 清理步骤，不代表两个服务可以同时运行。

切换到 Realm：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/switch-to-realm.sh)
```

切回 nftables-nat-rust：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/nftables-nat-rust/master/switch-to-nft.sh)
```

切换后检查：

```bash
forward-status
systemctl status realm
systemctl status nat
```

## 清理与卸载

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/clear-rules.sh)
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

同时删除配置：

```bash
REMOVE_REALM_RULES=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

# Realm

## 安装

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

保留当前 nft 服务：

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

## 切换与卸载

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/switch-to-realm.sh)
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/clear-rules.sh)
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

同时删除配置：

```bash
REMOVE_REALM_RULES=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

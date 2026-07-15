# Realm 私用转发脚本

用于把服务器从 nft 转发切到 Realm 转发。默认和 nft 项目共用同一份规则文件：

```text
/etc/nat.conf
```

规则格式：

```text
本地端口:远程IP或域名:远程端口
```

示例：

```text
33351:node.example.com:33344
33352:1.2.3.4:443
33353:[2001:db8::1]:443
```

## 一键安装 / 切到 Realm

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

会自动完成：

- 安装 Realm
- 读取并保留 `/etc/nat.conf`
- 生成 `/root/.realm/config.toml`
- 创建并启动 `realm.service`
- 设置开机自启
- 如果检测到 nft 的 `nat.service`，自动停用并清理 nft 表

只想安装 Realm，不动 nft 服务：

```bash
KEEP_NFT=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

## 单独切到 Realm

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/switch-to-realm.sh)
```

## 清规则 / 卸载

只清除当前 Realm 生效规则并停止 `realm.service`，保留 `/etc/nat.conf`：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/clear-rules.sh)
```

卸载 Realm 服务和程序，默认保留 `/etc/nat.conf`：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

连规则文件也删除：

```bash
REMOVE_REALM_RULES=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/uninstall.sh)
```

## 编辑规则

```bash
vim /etc/nat.conf
```

保存后 `realm.service` 会自动检测变更并重启 Realm。

注意：Realm 只读取三段式简单规则。`SINGLE,...`、`RANGE,...`、`REDIRECT,...` 这类 nft 旧格式会被忽略。

## 服务命令

```bash
systemctl status realm
systemctl restart realm
systemctl stop realm
systemctl enable realm
journalctl -fu realm
```

## 快速查看当前使用哪个服务

```bash
forward-status
```

## 菜单脚本

原交互式脚本仍保留：

```bash
curl -L https://raw.githubusercontent.com/Taylor000/realm/main/realm.sh -o realm.sh
chmod +x realm.sh
./realm.sh
```

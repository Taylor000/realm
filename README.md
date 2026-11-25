# Realm

## 安装

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

兼容旧参数 `KEEP_NFT=1`（检测到正在运行的 nat 或遗留转发表时拒绝切换）：

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
- 不要使用 `KEEP_NFT=1` 保留正在运行的 nft 转发；两个后端必须互斥。

切换到 Realm：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/switch-to-realm.sh)
```

切回 nftables-nat-rust：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/nftables-nat-rust/master/switch-to-nft.sh)
```

安装脚本会先验证共享规则和可执行文件，再停止旧后端；新服务持续运行且规则对应的 TCP/UDP 端口均由 Realm 监听后才报告成功。失败或收到中断信号时，会尝试恢复原文件、服务运行状态和开机启动状态，备份保存在 `/var/backups/forward-switch.*`。系统强制断电或 `kill -9` 无法触发自动回滚。

- GNU 构建无法运行时自动尝试同版本 musl 构建，兼容 Debian 11 等 glibc 较旧的系统。验证成功前不会替换现有二进制。
- 默认复用已安装且可运行的 Realm 二进制。如需指定版本安装或更新：`REALM_VERSION=v2.9.6 bash setup.sh`。
- 依赖齐全时跳过包管理器；缺少依赖且软件源失效时明确报错，原后端保持运行。脚本不会自动改写系统软件源。
- 两边共用切换锁，切换时保留 `/etc/nat.conf`。空规则时 runner 保持待命，添加规则后自动启动 Realm。
- 不支持、重复或无效的规则会阻止切换；运行期间语法校验失败时继续使用原配置和进程；新配置启动检查失败时恢复上一份有效配置并重新启动，同时写入日志。
- 切换有短暂中断，现有连接不会迁移。服务被 mask、使用非标准 linked 单元或无法恢复时，脚本会在切换前拒绝执行。如自行配置了 systemd 覆盖文件或端口被其他服务占用，请检查 `systemctl cat nat realm` 和服务日志。

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

## 脚本回归测试

```bash
python3 -m unittest discover -s tests -v
```

测试使用临时文件和服务、包管理器替身，不会切换当前机器的实际服务。

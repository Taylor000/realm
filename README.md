# Realm 一键转发脚本

自用的 Realm 端口转发工具，默认面向 Debian / Ubuntu 服务器。

默认读取 nft 项目同一个本地规则文件 `/etc/nat.conf`，配置写法保持一致：

```text
本地端口:远程IP或域名:远程端口
```

保存规则文件后，`realm.service` 会自动检测变更并重启 Realm。

## 功能

- 默认规则文件：`/etc/nat.conf`
- 简化转发格式：`本地端口:远程IP或域名:远程端口`
- 自动转换为 Realm TOML 配置：`/root/.realm/config.toml`
- 支持 IPv4 / 域名 / IPv6 目标地址
- 支持 systemd 开机自启
- 保留原交互式脚本 `realm.sh`
- 可选安装 Web 管理面板

## 一键安装

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

安装脚本会自动完成这些步骤：

- 安装基础依赖：`curl`、`wget`、`tar`
- 下载官方 Realm 二进制
- 安装 `/usr/local/bin/realm-runner`
- 创建 `/etc/nat.conf`，如果已存在则保留
- 创建并启动 `realm.service`
- 设置 `realm.service` 开机自启
- 如果检测到 nft 项目的 `nat.service`，自动停用它并清理 nft 表，但保留 `/etc/nat.conf`

从 nft 项目切换时，直接执行一键安装即可。脚本会复用原来的 `/etc/nat.conf`：

```bash
bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

切换时会自动：

- 备份 `/etc/nat.conf`
- 停止并禁用 nft 的 `nat.service`
- 清理 nft 生成的表
- 启动并启用 `realm.service`

如果只是想安装 Realm 但暂时不动 nft 服务：

```bash
KEEP_NFT=1 bash <(curl -sSLf https://raw.githubusercontent.com/Taylor000/realm/main/setup.sh)
```

## 配置

编辑 `/etc/nat.conf`：

```bash
vim /etc/nat.conf
```

示例：

```text
# 本机 33351 端口转发到 node.example.com:33344
33351:node.example.com:33344

# 本机 33352 端口转发到 1.2.3.4:443
33352:1.2.3.4:443

# IPv6 目标地址使用中括号
33353:[2001:db8::1]:443
```

有效规则不要带 `#`。保存文件后，服务会自动重新加载，不需要手动重启。

Realm 只读取这种三段式简单规则。`SINGLE,...`、`RANGE,...`、`REDIRECT,...` 等 nft 兼容旧格式会被忽略。

## 服务管理

```bash
# 查看状态
systemctl status realm

# 启动
systemctl start realm

# 停止
systemctl stop realm

# 重启
systemctl restart realm

# 开机自启
systemctl enable realm

# 实时日志
journalctl -fu realm
```

## 交互式脚本

如果需要使用原菜单式管理：

```bash
curl -L https://raw.githubusercontent.com/Taylor000/realm/main/realm.sh -o realm.sh
chmod +x realm.sh
./realm.sh
```

## Web 面板

`realm.sh` 里仍保留 Web 面板安装入口。面板 release 资产由 GitHub Actions 在推送 `v*` tag 后自动构建：

- `realm-panel-linux-amd64.zip`
- `realm-panel-linux-arm64.zip`

## 官方 Realm 项目

Realm 核心二进制来自官方项目：

https://github.com/zhboner/realm

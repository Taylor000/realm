# 更新日志

## v3.2.5

### 新增

- 支持 Alpine Linux。
- Alpine Linux 使用 OpenRC 管理 `realm` 和 `realm-panel` 服务。
- Alpine Linux 自动选择官方 `unknown-linux-musl` 版 Realm 二进制。
- Web 面板后端新增 systemd / OpenRC 服务管理抽象。
- 新增 Shell 轻量测试，覆盖 Alpine/OpenRC 关键选择逻辑。
- 新增 Go 单元测试，覆盖 systemd / OpenRC 服务命令选择。

### 变更

- Release 构建改为 GitHub Actions 自动生成，不再提交本地构建产物。
- GitHub Actions 从构建单个 `main.go` 改为构建整个 Go package。
- `.gitignore` 忽略 `dist/`、`*.zip`、`*.tar.gz` 和 `web/realm_web`。
- README 补充 Alpine 安装流程、系统支持矩阵和 Release 自动构建说明。

### 修复

- 修复端口段转发中 `[::]` 监听地址重复检测被当作正则解析的问题。
- 修复面板压缩包存在顶层目录时 `config.toml` 可能未复制的问题。
- 移除脚本自更新里的 `--no-check-certificate`。
- 服务文件写入后显式设置权限。

### 安全

- 面板 Session Cookie 设置 `HttpOnly` 和 `SameSite=Strict`。
- HTTPS 启用时，面板 Session Cookie 自动设置 `Secure`。
- 面板服务控制命令增加执行超时，并优先使用常见绝对路径。

## v3.2.4

- 修复规则列表刷新时缓存导致不更新的问题。
- `/get_rules` 每次请求重新从磁盘加载配置，手动修改 `config.toml` 后可立即反映。

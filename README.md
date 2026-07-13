# Claude Mac Env Audit

一个面向 macOS 的 Claude Code 环境检测与修复脚本，用于排查常见的代理、时区、DNS、hosts、包管理器代理、Claude/Router 配置残留等问题，并给出中文建议。

脚本默认会自动修复可安全处理的本地配置项。涉及第三方 API 痕迹时会先询问确认，避免误删你仍在使用的自定义服务配置。

涉及系统设置修改的项目会按需申请 `sudo` 权限，例如修改系统时区、关闭系统代理、编辑 `/etc/hosts`。只检测模式不会申请 `sudo`。

## 功能

- 检测 macOS 系统版本、架构、`claude` 和 `node` 环境。
- 检查系统时区；默认只有明确传入目标时区时才自动修改，`--aggressive` 可为中国大陆时区选择迁移目标；不会把新加坡等境外时区单独判为风险。
- 检查并可关闭 macOS 系统 HTTP/HTTPS/SOCKS/PAC 代理。
- 检查当前 shell、`launchctl`、常见 shell 启动文件中的代理和基础 URL 环境变量。
- 清理 npm/yarn/pnpm/git 中的代理残留。
- 检查 Claude / Claude Code Router 配置中的代理、自定义端点、第三方 API 痕迹。
- 检查 `/etc/hosts` 中的 Claude/Anthropic 覆盖项。
- 检查当前出口 IP、IPv4/IPv6 出口国家、DNS 和 `api.anthropic.com` 连通性；默认接受中国大陆以外的国家，也可指定目标国家。
- 每次运行会生成报告；修改文件前会生成备份。

出口国家检测是一次运行时快照，只能说明当前请求的出口位置，不能单凭一次结果证明线路长期固定。需要固定国家时，请使用 `--target-country` 并在不同时间重复运行。

## 使用

预览将要执行的修复，不修改系统或用户配置：

```bash
./claude_mac_env_audit.sh --dry-run
```

`--dry-run` 仍会在 `~/.claude-mac-env-audit/` 生成权限受限的本地报告。

只检测，不显示拟执行的修复动作：

```bash
./claude_mac_env_audit.sh --check-only
```

执行检测并自动修复可安全处理的项目：

```bash
./claude_mac_env_audit.sh
```

运行过程中如果需要修改系统级配置，脚本会提示输入 macOS 管理员密码。

中国大陆时区未指定目标时，使用 `Asia/Taipei` 作为迁移目标：

```bash
./claude_mac_env_audit.sh --aggressive
```

明确指定要检查并修复到的目标时区。目标应与你选择的长期出口环境一致：

```bash
./claude_mac_env_audit.sh --target-tz Asia/Tokyo
./claude_mac_env_audit.sh --target-tz Asia/Singapore
```

指定期望的出口国家，例如日本、新加坡、美国：

```bash
./claude_mac_env_audit.sh --target-country JP
./claude_mac_env_audit.sh --target-country SG
./claude_mac_env_audit.sh --target-country US
```

不向公网 IP 查询服务和 Anthropic 端点发起请求：

```bash
./claude_mac_env_audit.sh --dry-run --offline
```

如果系统提示没有执行权限：

```bash
chmod +x ./claude_mac_env_audit.sh
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--dry-run` | 显示拟执行的修复，不修改系统或用户配置；仍会生成本地报告。 |
| `--check-only` | 只检测，不显示拟执行的修复动作。 |
| `--aggressive` | 中国大陆时区未指定目标时，使用 `Asia/Taipei` 作为迁移目标；不会修改其他境外时区。 |
| `--target-tz TZ` | 明确指定要检查并修复到的目标时区，例如 `Asia/Tokyo`。 |
| `--target-country CC` | 检查当前出口是否匹配两位国家代码，例如 `US`、`JP`、`SG`。不指定时默认接受中国大陆以外的国家。 |
| `--no-fix` | 只检测，不执行修复。 |
| `--offline` | 跳过公网 IP 和 Anthropic 端点联网检测。 |
| `--version` | 显示版本号。 |
| `-h`, `--help` | 显示帮助。 |

## 安全策略

- 修改用户文件或 `/etc/hosts` 前会先备份。
- 备份失败时会取消对应修改，不会继续写原文件。
- 修改系统设置或 `/etc/hosts` 时会按需申请 `sudo` 权限。
- 不会删除账号、应用、钥匙串、支付数据或浏览器配置。
- 清理第三方 API 痕迹前会询问确认，输入 `y` 才会执行。
- `launchctl`、shell 启动文件、Claude/Router JSON 配置中的第三方 API 修改都受确认门保护。
- JSON 清理只删除明确匹配的代理/基础 URL 字段，不删除通用 `endpoint` 字段；确认前会显示字段路径但隐藏字段值。
- 没有可交互终端时，会跳过第三方 API 痕迹清理。
- 日志隐藏代理 URL、第三方基础 URL 等配置值；报告和备份权限会收紧为仅当前用户可读。
- `NO_PROXY`/`no_proxy` 不定义代理入口，脚本不会自动删除。
- 脚本无法移除父级 shell 中已经存在的环境变量；修复后建议打开新的终端窗口重新检查。

报告和备份默认写入：

```text
~/.claude-mac-env-audit/reports/
~/.claude-mac-env-audit/backups/
```

结构化清理 JSON 配置需要 `python3`。缺少该命令时，脚本只提示相关文件，不会尝试文本替换。

未使用 `--offline` 时，出口检测会依次尝试 `ipinfo.io`、`ifconfig.co`、`ipapi.co`，并请求 `api.anthropic.com` 验证连通性。

## 开发与测试

在 macOS 上运行隔离测试：

```bash
zsh tests/test_cli.zsh
```

GitHub Actions 会在每次推送和 Pull Request 时运行同一组测试。

## 适用范围

此脚本只面向 macOS。它用于本机环境排查和配置卫生检查，不保证解决任何平台账号、风控或服务可用性问题。请遵守你所在地区的法律法规和相关服务条款。

## 许可证

MIT

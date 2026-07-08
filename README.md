# Claude Mac Env Audit

一个面向 macOS 的 Claude Code 环境检测与修复脚本，用于排查常见的代理、时区、DNS、hosts、包管理器代理、Claude/Router 配置残留等问题，并给出中文建议。

脚本默认会自动修复可安全处理的本地配置项。涉及第三方 API 痕迹时会先询问确认，避免误删你仍在使用的自定义服务配置。

## 功能

- 检测 macOS 系统版本、架构、`claude` 和 `node` 环境。
- 检查系统时区，并提示高风险时区配置。
- 检查并可关闭 macOS 系统 HTTP/HTTPS/SOCKS/PAC 代理。
- 检查当前 shell、`launchctl`、常见 shell 启动文件中的代理和基础 URL 环境变量。
- 清理 npm/yarn/pnpm/git 中的代理残留。
- 检查 Claude / Claude Code Router 配置中的代理、自定义端点、第三方 API 痕迹。
- 检查 `/etc/hosts` 中的 Claude/Anthropic 覆盖项。
- 检查出口 IP、DNS 和 `api.anthropic.com` 连通性。
- 每次运行会生成报告；修改文件前会生成备份。

## 使用

只检测，不修改任何配置：

```bash
./claude_mac_env_audit.sh --dry-run
```

执行检测并自动修复可安全处理的项目：

```bash
./claude_mac_env_audit.sh
```

连提示风险的项目也自动处理，例如 `Asia/Singapore` 时区：

```bash
./claude_mac_env_audit.sh --aggressive
```

指定自动修复时区的目标值：

```bash
./claude_mac_env_audit.sh --target-tz Asia/Taipei
```

如果系统提示没有执行权限：

```bash
chmod +x ./claude_mac_env_audit.sh
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--dry-run` | 只显示将要修改的内容，不实际修改文件或系统设置。 |
| `--check-only` | 等同于 `--dry-run`。 |
| `--aggressive` | 连仅提示风险的项目也自动修复，例如 `Asia/Singapore` 时区。 |
| `--target-tz TZ` | 设置自动修复时区时使用的目标时区，默认 `Asia/Taipei`。 |
| `--no-fix` | 只检测，不执行修复。 |
| `-h`, `--help` | 显示帮助。 |

## 安全策略

- 修改用户文件或 `/etc/hosts` 前会先备份。
- 不会删除账号、应用、钥匙串、支付数据或浏览器配置。
- 清理第三方 API 痕迹前会询问确认，输入 `y` 才会执行。
- 没有可交互终端时，会跳过第三方 API 痕迹清理。
- 脚本无法移除父级 shell 中已经存在的环境变量；修复后建议打开新的终端窗口重新检查。

报告和备份默认写入：

```text
~/.claude-mac-env-audit/reports/
~/.claude-mac-env-audit/backups/
```

## 适用范围

此脚本只面向 macOS。它用于本机环境排查和配置卫生检查，不保证解决任何平台账号、风控或服务可用性问题。请遵守你所在地区的法律法规和相关服务条款。

## 许可证

MIT

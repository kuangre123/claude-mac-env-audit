#!/usr/bin/env zsh

# Claude Code macOS 环境检测与修复脚本。
# 参考来源: https://x.com/app_sail/status/2072494971643715658
#
# 默认行为:
# - 执行检测，并在可安全自动处理的地方直接修复。
# - 清理第三方 API 痕迹前会询问确认。
# - 修改系统设置或 /etc/hosts 时会按需申请 sudo 权限。
# - 修改用户文件或 /etc/hosts 前会先创建备份。
# - 不会删除账号、应用、钥匙串、支付数据或浏览器配置。
#
# 常用参数:
#   --dry-run       预览修复，不修改系统或用户配置；仍生成本地报告。
#   --check-only    只检测，不显示拟执行的修复动作。
#   --aggressive    中国大陆时区未指定目标时，使用 Asia/Taipei 作为迁移目标。
#   --target-tz TZ  明确指定要检查并修复到的目标时区。
#   --target-country CC  指定期望的出口国家，两位国家代码，例如 US、JP、SG。
#   --offline       跳过公网 IP 和 Anthropic 端点联网检测。

set -u
set -o pipefail
umask 077

FIX=1
DRY_RUN=0
AGGRESSIVE=0
OFFLINE=0
VERSION="1.1.0"
TARGET_TZ="${TARGET_TZ:-}"
TARGET_COUNTRY="${TARGET_COUNTRY:-}"
TS="$(date +%Y%m%d-%H%M%S)-$$"
BASE_DIR="${HOME}/.claude-mac-env-audit"
BACKUP_DIR="${BASE_DIR}/backups/${TS}"
REPORT_DIR="${BASE_DIR}/reports"
REPORT_FILE="${REPORT_DIR}/report-${TS}.log"
SCRIPT_NAME="${0:t}"

typeset -gi OK_COUNT=0
typeset -gi WARN_COUNT=0
typeset -gi FIXED_COUNT=0
typeset -gi FAIL_COUNT=0
typeset -gi INFO_COUNT=0
typeset -gi SUDO_READY=0
typeset -gi SUDO_DENIED=0

usage() {
  cat <<EOF
Claude Code macOS 环境检测与修复脚本

用法:
  ${SCRIPT_NAME} [--dry-run|--check-only|--no-fix] [--aggressive] [--target-tz TZ] [--target-country CC] [--offline]

默认行为:
  执行检测，并在可安全自动处理的地方直接修复。
  清理第三方 API 痕迹前会询问确认。
  修改系统设置或 /etc/hosts 时会按需申请 sudo 权限。
  修改用户文件或 /etc/hosts 前会先创建备份。
  不会删除账号、应用、钥匙串、支付数据或浏览器配置。

常用参数:
  --dry-run       预览修复，不修改系统或用户配置；仍生成本地报告。
  --check-only    只检测，不显示拟执行的修复动作。
  --no-fix        等同于 --check-only。
  --aggressive    中国大陆时区未指定目标时，使用 Asia/Taipei 作为迁移目标。
  --target-tz TZ  明确指定要检查并修复到的目标时区，例如 Asia/Tokyo。
  --target-country CC  指定期望的出口国家，两位国家代码，例如 US、JP、SG。
  --offline       跳过公网 IP 和 Anthropic 端点联网检测。
  --version       显示版本号。
  -h, --help      显示帮助。
EOF
}

normalize_country_code() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      FIX=1
      shift
      ;;
    --check-only)
      DRY_RUN=0
      FIX=0
      shift
      ;;
    --no-fix)
      DRY_RUN=0
      FIX=0
      shift
      ;;
    --aggressive)
      AGGRESSIVE=1
      shift
      ;;
    --target-tz)
      if [[ $# -lt 2 ]]; then
        echo "--target-tz 需要一个时区值" >&2
        exit 2
      fi
      TARGET_TZ="$2"
      shift 2
      ;;
    --target-country)
      if [[ $# -lt 2 ]]; then
        echo "--target-country 需要一个两位国家代码，例如 US、JP、SG" >&2
        exit 2
      fi
      TARGET_COUNTRY="$(normalize_country_code "$2")"
      shift 2
      ;;
    --offline)
      OFFLINE=1
      shift
      ;;
    --version)
      echo "$VERSION"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

TARGET_COUNTRY="$(normalize_country_code "$TARGET_COUNTRY")"
if [[ -n "$TARGET_COUNTRY" && "$TARGET_COUNTRY" != [A-Z][A-Z] ]]; then
  echo "--target-country 只接受两位国家代码，例如 US、JP、SG" >&2
  exit 2
fi

if [[ -n "$TARGET_TZ" ]]; then
  if [[ "$TARGET_TZ" == /* || "$TARGET_TZ" == *..* || ! -f "/usr/share/zoneinfo/$TARGET_TZ" ]]; then
    echo "无效时区: $TARGET_TZ。示例: Asia/Tokyo、Asia/Singapore、Europe/London" >&2
    exit 2
  fi
fi

mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
chmod -R go-rwx "$BASE_DIR" 2>/dev/null || true
exec > >(tee -a "$REPORT_FILE") 2>&1

log_line() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

ok() {
  OK_COUNT+=1
  log_line "正常" "$*"
}

info() {
  INFO_COUNT+=1
  log_line "信息" "$*"
}

warn() {
  WARN_COUNT+=1
  log_line "警告" "$*"
}

fixed() {
  FIXED_COUNT+=1
  log_line "已修复" "$*"
}

fail() {
  FAIL_COUNT+=1
  log_line "失败" "$*"
}

dry() {
  log_line "预览" "$*"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

confirm_third_party_api_cleanup() {
  local target="$1"
  local answer=""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "实际修复前会询问是否清除第三方 API 痕迹: $target"
    return 0
  fi

  if [[ ! -r /dev/tty ]]; then
    warn "检测到第三方 API 痕迹，但当前没有可交互终端，已跳过清理: $target"
    return 1
  fi

  printf '是否清除 %s 中的第三方 API 痕迹？输入 y 确认，其他输入跳过: ' "$target" > /dev/tty
  if ! IFS= read -r answer < /dev/tty; then
    warn "无法读取确认输入，已跳过清理第三方 API 痕迹: $target"
    return 1
  fi

  case "${answer:l}" in
    y|yes|是|确认)
      info "已确认清理第三方 API 痕迹: $target"
      return 0
      ;;
    *)
      info "已跳过清理第三方 API 痕迹: $target"
      return 1
      ;;
  esac
}

is_third_party_env_name() {
  case "$1" in
    ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|CLAUDE_BASE_URL|CLAUDE_API_BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_third_party_api_trace() {
  local file="$1"
  grep -Eiv '^[[:space:]]*#' "$file" | grep -Eiq '(ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|CLAUDE_.*BASE|CLAUDE_API_BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|base[_-]?url|baseUrl|api[_-]?base)'
}

matching_line_numbers() {
  local file="$1"
  local pattern="$2"
  grep -Ein "$pattern" "$file" 2>/dev/null | sed -E '/^[0-9]+:[[:space:]]*#/d' | cut -d: -f1 | paste -sd ',' -
}

backup_file() {
  local file="$1"
  if [[ ! -e "$file" ]]; then
    return 1
  fi
  local safe
  safe="$(printf '%s' "$file" | sed 's#^/##; s#[/: ]#_#g')"
  local dest="${BACKUP_DIR}/${safe}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "将备份 $file -> $dest"
  else
    if ! mkdir -p "$(dirname "$dest")" || ! cp -p "$file" "$dest" || ! chmod 600 "$dest"; then
      return 1
    fi
  fi
  return 0
}

ensure_sudo() {
  local reason="$1"

  [[ "$EUID" -eq 0 ]] && return 0

  if [[ "$SUDO_READY" -eq 1 ]] && sudo -n true >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$SUDO_DENIED" -eq 1 ]]; then
    return 77
  fi

  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    warn "需要 sudo 权限，但当前没有可交互终端，已跳过: $reason"
    SUDO_DENIED=1
    return 77
  fi

  printf '需要 sudo 权限: %s\n' "$reason" > /dev/tty
  if sudo -v -p '请输入 macOS 管理员密码: ' < /dev/tty; then
    SUDO_READY=1
    return 0
  fi

  warn "sudo 授权失败，已跳过: $reason"
  SUDO_DENIED=1
  return 77
}

run_root_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ "$EUID" -eq 0 ]]; then
      dry "$*"
    else
      dry "sudo $*"
    fi
    return 0
  fi

  if [[ "$EUID" -eq 0 ]]; then
    "$@"
    return $?
  fi

  ensure_sudo "$*" || return 77
  sudo "$@"
  return $?
}

run_root_quiet() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    run_root_cmd "$@"
    return 0
  fi

  if [[ "$EUID" -eq 0 ]]; then
    "$@" >/dev/null 2>&1
    return $?
  fi

  ensure_sudo "$*" || return 77
  sudo "$@" >/dev/null 2>&1
  return $?
}

print_header() {
  echo "Claude Code macOS 环境检测 v$VERSION"
  echo "报告: $REPORT_FILE"
  echo "备份: $BACKUP_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "模式: 仅预览，不修改系统或用户配置（仍生成本地报告）"
  elif [[ "$FIX" -eq 1 ]]; then
    echo "模式: 自动修复；需要系统权限时会申请 sudo，清理第三方 API 痕迹前会询问"
  else
    echo "模式: 只检测"
  fi
  echo
}

audit_os() {
  echo "== 系统 =="
  if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "此脚本仅适用于 macOS。"
    exit 1
  fi

  local product version build arch
  product="$(sw_vers -productName 2>/dev/null || echo macOS)"
  version="$(sw_vers -productVersion 2>/dev/null || echo 未知)"
  build="$(sw_vers -buildVersion 2>/dev/null || echo 未知)"
  arch="$(uname -m)"
  ok "$product $version ($build)，架构=$arch"

  if have claude; then
    local claude_path claude_ver
    claude_path="$(command -v claude)"
    claude_ver="$(claude --version 2>/dev/null | head -1 || true)"
    ok "claude 命令: $claude_path ${claude_ver:+($claude_ver)}"
  else
    warn "PATH 中未找到 claude 命令。"
  fi

  if have node; then
    ok "node: $(command -v node) ($(node --version 2>/dev/null || echo 未知))"
  else
    warn "未找到 node，时区检测将只使用 macOS 系统信息。"
  fi
  echo
}

current_system_timezone() {
  local tz raw
  raw="$(systemsetup -gettimezone 2>/dev/null || true)"
  if [[ "$raw" == Time\ Zone:\ * ]]; then
    tz="${raw#Time Zone: }"
  fi
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz="$(readlink /etc/localtime | sed 's#^.*/zoneinfo/##')"
  fi
  if [[ -z "$tz" ]]; then
    tz="$(current_node_timezone)"
  fi
  printf '%s' "$tz"
}

current_node_timezone() {
  if have node; then
    node -e 'try { console.log(Intl.DateTimeFormat().resolvedOptions().timeZone || "") } catch (_) { process.exit(1) }' 2>/dev/null || true
  fi
}

audit_timezone() {
  echo "== 时区 =="
  local sys_tz node_tz effective_target
  sys_tz="$(current_system_timezone)"
  node_tz="$(current_node_timezone)"
  effective_target="$TARGET_TZ"

  info "系统时区: ${sys_tz:-未知}"
  [[ -n "$node_tz" ]] && info "node Intl 时区: $node_tz"

  local should_fix=0
  if [[ -z "$effective_target" && "$AGGRESSIVE" -eq 1 && ( "$sys_tz" == "Asia/Shanghai" || "$sys_tz" == "Asia/Urumqi" ) ]]; then
    effective_target="Asia/Taipei"
    info "--aggressive 已为中国大陆时区选择迁移目标: $effective_target"
  fi

  if [[ -n "$effective_target" ]]; then
    if [[ "$sys_tz" == "$effective_target" ]]; then
      ok "时区已经符合目标: $effective_target"
    elif [[ -z "$sys_tz" ]]; then
      warn "无法读取系统时区，不能判断是否匹配目标 $effective_target。"
    else
      warn "系统时区 $sys_tz 与明确指定的目标 $effective_target 不一致。"
      should_fix=1
    fi
  else
    case "$sys_tz" in
      Asia/Shanghai|Asia/Urumqi)
        warn "当前是中国大陆时区。脚本不会猜测目标国家；请用 --target-tz 明确指定与你出口环境一致的时区。"
        ;;
      "")
        warn "无法读取系统时区。"
        ;;
      *)
        ok "当前时区为 $sys_tz；未指定目标时区，保持不变。"
        ;;
    esac
  fi

  if [[ "$should_fix" -eq 1 && "$FIX" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "将使用 sudo 把系统时区设置为 $effective_target"
    elif run_root_cmd systemsetup -settimezone "$effective_target"; then
      fixed "已将时区设置为 $effective_target。"
    else
      fail "无法设置时区，可能是 sudo 授权失败或 systemsetup 执行失败。"
    fi
  fi
  echo
}

network_services() {
  networksetup -listallnetworkservices 2>/dev/null | sed '1d; s/^\*//; /^$/d'
}

proxy_enabled_snapshot() {
  scutil --proxy 2>/dev/null | awk '
    /(HTTPEnable|HTTPSEnable|SOCKSEnable|FTPEnable|GopherEnable|RTSPEnable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable) : 1/ { print }
  '
}

disable_proxy_for_service() {
  local service="$1"
  local rc=0
  run_root_quiet networksetup -setwebproxystate "$service" off || rc=1
  run_root_quiet networksetup -setsecurewebproxystate "$service" off || rc=1
  run_root_quiet networksetup -setsocksfirewallproxystate "$service" off || rc=1
  run_root_quiet networksetup -setautoproxystate "$service" off || rc=1
  run_root_quiet networksetup -setproxyautodiscovery "$service" off || rc=1
  return "$rc"
}

audit_system_proxy() {
  echo "== 系统代理 =="
  if ! have scutil; then
    warn "未找到 scutil。"
    echo
    return
  fi

  local before
  before="$(proxy_enabled_snapshot)"
  if [[ -z "$before" ]]; then
    ok "macOS 系统代理均处于关闭状态。"
  else
    warn "macOS 系统代理存在已启用状态:"
    echo "$before"

    if [[ "$FIX" -eq 1 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        dry "将使用 sudo 关闭所有网络服务的 HTTP/HTTPS/SOCKS/PAC/自动发现代理状态"
      else
        local svc
        local changed=0
        local command_failed=0
        while IFS= read -r svc; do
          [[ -z "$svc" ]] && continue
          disable_proxy_for_service "$svc" || command_failed=1
          changed=1
        done < <(network_services)

        if [[ "$changed" -eq 1 ]]; then
          local after
          after="$(proxy_enabled_snapshot)"
          if [[ -z "$after" ]]; then
            fixed "已关闭所有网络服务的 HTTP/HTTPS/SOCKS/PAC 系统代理状态。"
          else
            fail "已尝试关闭系统代理，但仍残留部分代理设置:"
            echo "$after"
          fi
          if [[ "$command_failed" -eq 1 ]]; then
            warn "部分网络服务不支持某些代理开关；已以上方最终状态复核结果为准。"
          fi
        else
          fail "未找到可更新的网络服务。"
        fi
      fi
    fi
  fi

  local utuns
  utuns="$(ifconfig 2>/dev/null | awk -F: '/^utun[0-9]+:/{print $1}' | paste -sd ' ' -)"
  if [[ -n "$utuns" ]]; then
    info "检测到 utun 接口: $utuns。接口存在只说明系统有隧道设备，不代表当前流量一定经过它。"
  else
    warn "当前未检测到 utun 接口。如果你依赖代理客户端，建议使用 TUN/VPN 模式，而不是 macOS 系统代理模式。"
  fi
  echo
}

env_names() {
  cat <<'EOF'
HTTP_PROXY
HTTPS_PROXY
ALL_PROXY
http_proxy
https_proxy
all_proxy
ANTHROPIC_BASE_URL
ANTHROPIC_API_URL
ANTHROPIC_PROXY
CLAUDE_BASE_URL
CLAUDE_API_BASE
CLAUDE_CODE_ROUTER
OPENAI_BASE_URL
EOF
}

audit_launchctl_env() {
  echo "== launchctl 环境变量 =="
  local name value found=0
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    value="$(launchctl getenv "$name" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      found=1
      warn "launchctl $name 已设置（值已隐藏）"
      if [[ "$FIX" -eq 1 ]]; then
        if is_third_party_env_name "$name" && ! confirm_third_party_api_cleanup "launchctl 环境变量 $name"; then
          continue
        fi

        if [[ "$DRY_RUN" -eq 1 ]]; then
          dry "将清除 launchctl 环境变量 $name"
        elif launchctl unsetenv "$name"; then
          fixed "已清除 launchctl $name。"
        else
          fail "无法清除 launchctl $name。"
        fi
      fi
    fi
  done < <(env_names)
  [[ "$found" -eq 0 ]] && ok "launchctl 用户环境中未发现代理或基础 URL 变量。"
  echo
}

audit_process_env() {
  echo "== 当前 Shell 环境变量 =="
  local matches
  matches="$(env | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*(PROXY|BASE|URL|ENDPOINT)|OPENAI_BASE_URL)=' | sed 's/=.*$/=<值已隐藏>/' || true)"
  if [[ -n "$matches" ]]; then
    warn "当前进程包含相关环境变量。脚本无法修改父级 shell；启动文件和 launchctl 会单独处理。"
    echo "$matches"
  else
    ok "当前 shell 未发现代理或基础 URL 环境变量。"
  fi
  echo
}

comment_suspicious_shell_lines() {
  local file="$1"
  local pattern='(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm +config +set +.*proxy|yarn +config +set +.*proxy|pnpm +config +set +.*proxy|git +config +.*http.*proxy)'
  local line_numbers
  [[ -f "$file" ]] || return 1

  line_numbers="$(matching_line_numbers "$file" "$pattern")"
  if [[ -z "$line_numbers" ]]; then
    return 1
  fi

  warn "在 $file 中发现可疑的代理或基础 URL 配置，行号: $line_numbers（内容已隐藏）"

  if [[ "$FIX" -ne 1 ]]; then
    return 0
  fi

  if has_third_party_api_trace "$file"; then
    if ! confirm_third_party_api_cleanup "$file"; then
      return 0
    fi
  fi

  if ! backup_file "$file"; then
    fail "无法备份 $file，已取消修改。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "将注释 $file 中的可疑配置行"
    return 0
  fi

  perl -pi -e '
    if (/^\s*#/) { next; }
    if (/(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm\s+config\s+set\s+.*proxy|yarn\s+config\s+set\s+.*proxy|pnpm\s+config\s+set\s+.*proxy|git\s+config\s+.*http.*proxy)/i) {
      $_ = "# claude-mac-env-audit 已禁用: " . $_;
    }
  ' "$file" && fixed "已注释 $file 中的可疑配置行。" || fail "无法修改 $file；原文件备份已保留。"
}

audit_shell_startup_files() {
  echo "== Shell 启动文件 =="
  local files=(
    "$HOME/.zshenv"
    "$HOME/.zprofile"
    "$HOME/.zshrc"
    "$HOME/.bash_profile"
    "$HOME/.bashrc"
    "$HOME/.profile"
    "$HOME/.config/fish/config.fish"
  )

  local touched=0
  local found_issue=0
  local f
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      touched=1
      if comment_suspicious_shell_lines "$f"; then
        found_issue=1
      fi
    fi
  done
  if [[ "$touched" -eq 0 ]]; then
    info "未找到常见 shell 启动文件。"
  elif [[ "$found_issue" -eq 0 ]]; then
    ok "已检查常见 shell 启动文件，未发现代理或基础 URL 配置。"
  fi
  echo
}

audit_npm_yarn_pnpm() {
  echo "== Node 包管理器代理配置 =="
  local saw=0

  if have npm; then
    local key value
    for key in proxy https-proxy; do
      value="$(npm config get "$key" 2>/dev/null || true)"
      if [[ -n "$value" && "$value" != "null" && "$value" != "undefined" ]]; then
        saw=1
        warn "npm $key 已设置（值已隐藏）"
        if [[ "$FIX" -eq 1 ]]; then
          if [[ "$DRY_RUN" -eq 1 ]]; then
            dry "将删除 npm 配置 $key"
          elif npm config delete "$key"; then
            fixed "已删除 npm 配置 $key。"
          else
            fail "无法删除 npm 配置 $key。"
          fi
        fi
      fi
    done
  else
    info "未找到 npm。"
  fi

  if have yarn; then
    local ykey yvalue
    for ykey in proxy https-proxy; do
      yvalue="$(yarn config get "$ykey" 2>/dev/null | tail -1 || true)"
      if [[ -n "$yvalue" && "$yvalue" != "undefined" && "$yvalue" != "null" ]]; then
        saw=1
        warn "yarn $ykey 已设置（值已隐藏）"
        if [[ "$FIX" -eq 1 ]]; then
          if [[ "$DRY_RUN" -eq 1 ]]; then
            dry "将删除 yarn 配置 $ykey"
          elif yarn config delete "$ykey" >/dev/null 2>&1; then
            fixed "已删除 yarn 配置 $ykey。"
          else
            fail "无法删除 yarn 配置 $ykey。"
          fi
        fi
      fi
    done
  fi

  if have pnpm; then
    local pkey pvalue
    for pkey in proxy https-proxy; do
      pvalue="$(pnpm config get "$pkey" 2>/dev/null || true)"
      if [[ -n "$pvalue" && "$pvalue" != "undefined" && "$pvalue" != "null" ]]; then
        saw=1
        warn "pnpm $pkey 已设置（值已隐藏）"
        if [[ "$FIX" -eq 1 ]]; then
          if [[ "$DRY_RUN" -eq 1 ]]; then
            dry "将删除 pnpm 配置 $pkey"
          elif pnpm config delete "$pkey" >/dev/null 2>&1; then
            fixed "已删除 pnpm 配置 $pkey。"
          else
            fail "无法删除 pnpm 配置 $pkey。"
          fi
        fi
      fi
    done
  fi

  local npmrc="$HOME/.npmrc"
  local npmrc_lines=""
  [[ -f "$npmrc" ]] && npmrc_lines="$(matching_line_numbers "$npmrc" '(^|-)proxy[[:space:]]*=')"
  if [[ -n "$npmrc_lines" ]]; then
    saw=1
    warn "在 $npmrc 中发现代理配置，行号: $npmrc_lines（内容已隐藏）"
    if [[ "$FIX" -eq 1 ]]; then
      if ! backup_file "$npmrc"; then
        fail "无法备份 $npmrc，已取消修改。"
      elif [[ "$DRY_RUN" -eq 1 ]]; then
        dry "将注释 $npmrc 中的代理配置行"
      elif perl -pi -e 'if (/^\s*#/){next}; if (/(^|-)proxy\s*=/i){$_="# claude-mac-env-audit 已禁用: ".$_}' "$npmrc"; then
        fixed "已注释 $npmrc 中的代理配置行。"
      else
        fail "无法修改 $npmrc；原文件备份已保留。"
      fi
    fi
  fi

  [[ "$saw" -eq 0 ]] && ok "未发现 npm/yarn/pnpm 代理配置。"
  echo
}

audit_git_proxy() {
  echo "== Git 代理配置 =="
  if ! have git; then
    info "未找到 git。"
    echo
    return
  fi

  local keys=(
    "http.proxy"
    "https.proxy"
    "http.https://api.anthropic.com.proxy"
    "http.https://claude.ai.proxy"
  )
  local saw=0
  local key value
  for key in "${keys[@]}"; do
    value="$(git config --global --get "$key" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      saw=1
      warn "git $key 已设置（值已隐藏）"
      if [[ "$FIX" -eq 1 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
          dry "将清除 git 配置 $key"
        elif git config --global --unset-all "$key"; then
          fixed "已清除 git 配置 $key。"
        else
          fail "无法清除 git 配置 $key。"
        fi
      fi
    fi
  done

  local extra
  extra="$(git config --global --list 2>/dev/null | grep -Ei '(proxy|anthropic|claude|baseurl|base-url)' | sed 's/=.*$//' | sort -u || true)"
  if [[ -n "$extra" ]]; then
    warn "仍存在其他相关的全局 git 配置键（值已隐藏）:"
    echo "$extra"
  elif [[ "$saw" -eq 0 ]]; then
    ok "未发现全局 git 代理配置。"
  fi
  echo
}

json_sensitive_paths() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    sys.exit(2)

bad_key = re.compile(
    r"^(proxy|https?_proxy|all_proxy|anthropic_proxy|base[_-]?url|baseUrl|"
    r"api[_-]?base(?:[_-]?url)?|apiBase(?:Url)?|ANTHROPIC_(?:BASE|API)_URL|"
    r"CLAUDE_(?:BASE_URL|API_BASE|CODE_ROUTER)|OPENAI_BASE_URL)$",
    re.I,
)

matches = []

def walk(value, current="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            child_path = f"{current}.{key}"
            if bad_key.search(str(key)):
                matches.append(child_path)
            else:
                walk(child, child_path)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{current}[{index}]")

walk(data)
if not matches:
    sys.exit(3)
print("\n".join(matches))
PY
}

json_scrub_file() {
  local file="$1"
  local pattern='(proxy|base[_-]?url|baseUrl|api[_-]?base([_-]?url)?|apiBase(Url)?|ANTHROPIC_(BASE|API)_URL|CLAUDE_(BASE_URL|API_BASE|CODE_ROUTER)|OPENAI_BASE_URL)'
  [[ -f "$file" ]] || return 0

  if ! grep -Eiq "$pattern" "$file"; then
    return 0
  fi

  if ! have python3; then
    warn "在 $file 中发现相关字符串，但未找到 python3，无法确认或结构化清理 JSON；文件保持不变。"
    return 0
  fi

  local paths path_status
  paths="$(json_sensitive_paths "$file" 2>/dev/null)"
  path_status=$?
  case "$path_status" in
    0)
      warn "Claude 或工具配置中包含将被清理的字段路径（值已隐藏）: $file"
      echo "$paths"
      ;;
    2)
      warn "无法解析 JSON，文件保持不变: $file"
      return 0
      ;;
    3)
      return 0
      ;;
    *)
      warn "无法检查 JSON 字段，文件保持不变: $file"
      return 0
      ;;
  esac

  if [[ "$FIX" -ne 1 ]]; then
    return 0
  fi

  if ! confirm_third_party_api_cleanup "$file"; then
    return 0
  fi

  if ! backup_file "$file"; then
    fail "无法备份 $file，已取消修改。"
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "将从 $file 中清理明确匹配的代理或基础 URL 字段"
    return 0
  fi

  python3 - "$file" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"无法解析 JSON，保持文件不变: {path}: {exc}")
    sys.exit(2)

bad_key = re.compile(
    r"^(proxy|https?_proxy|all_proxy|anthropic_proxy|base[_-]?url|baseUrl|"
    r"api[_-]?base(?:[_-]?url)?|apiBase(?:Url)?|ANTHROPIC_(?:BASE|API)_URL|"
    r"CLAUDE_(?:BASE_URL|API_BASE|CODE_ROUTER)|OPENAI_BASE_URL)$",
    re.I,
)

def scrub(value):
    changed = False
    if isinstance(value, dict):
        for key in list(value.keys()):
            if bad_key.search(str(key)):
                del value[key]
                changed = True
            else:
                new_value, child_changed = scrub(value[key])
                value[key] = new_value
                changed = changed or child_changed
    elif isinstance(value, list):
        for idx, item in enumerate(value):
            new_item, child_changed = scrub(item)
            value[idx] = new_item
            changed = changed or child_changed
    return value, changed

data, changed = scrub(data)
if changed:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已清理 {path}")
else:
    print(f"未从 {path} 删除 JSON 字段")
    sys.exit(3)
PY
  case "$?" in
    0) fixed "已从 $file 清理代理或基础 URL 字段。" ;;
    3) info "$file 没有需要结构化删除的字段，文件保持不变。" ;;
    *) fail "无法安全清理 $file；备份已保留。" ;;
  esac
}

audit_claude_configs() {
  echo "== Claude / Router 配置文件 =="
  local files=(
    "$HOME/.claude/settings.json"
    "$HOME/.claude/settings.local.json"
    "$HOME/.claude.json"
    "$HOME/.config/claude/settings.json"
    "$HOME/.config/claude-code/settings.json"
    "$HOME/.config/claude-code-router/config.json"
    "$HOME/.claude-code-router/config.json"
    "$HOME/.claude-code-router.json"
  )

  local found=0
  local file
  for file in "${files[@]}"; do
    if [[ -f "$file" ]]; then
      found=1
      json_scrub_file "$file"
    fi
  done

  local dir
  for dir in "$HOME/.claude" "$HOME/.config/claude" "$HOME/.config/claude-code" "$HOME/.config/claude-code-router" "$HOME/.claude-code-router"; do
    if [[ -d "$dir" ]]; then
      local hits_file="$(mktemp)"
      find "$dir" -maxdepth 4 -type f \
        \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' -o -name '*.env' -o -name 'settings*' -o -name 'config*' \) \
        ! -path '*/cache/*' \
        ! -path '*/plugins/*' \
        ! -path '*/skills/*' \
        ! -path '*/security/*' \
        ! -path '*/file-history/*' \
        ! -path '*/tasks/*' \
        ! -path '*/history.jsonl' \
        ! -path '*/backups/*' \
        ! -path '*/stats-cache.json' \
        ! -path '*/claude-switch-state.json' \
        ! -name '*.bak-*' \
        ! -path "$HOME/.claude/settings.json" \
        ! -path "$HOME/.claude/settings.local.json" \
        ! -path "$HOME/.claude-code-router/config.json" \
        -print0 2>/dev/null \
        | xargs -0 grep -IlE '(ANTHROPIC_BASE_URL|proxy|base_url|baseUrl|api_base|endpoint|aihubmix|openai-sb|oneapi|newapi|siliconflow|deepseek|moonshot|kimi|zhipu|minimax)' 2>/dev/null \
        | head -50 > "$hits_file" || true
      if [[ -s "$hits_file" ]]; then
        found=1
        warn "在 $dir 下发现相关字符串:"
        grep '^/' "$hits_file" || true
      fi
      rm -f "$hits_file"
    fi
  done

  [[ "$found" -eq 0 ]] && ok "未发现常见 Claude/router 配置文件。"
  echo
}

audit_hosts_file() {
  echo "== /etc/hosts =="
  local hosts="/etc/hosts"
  if [[ ! -f "$hosts" ]]; then
    warn "未找到 /etc/hosts。"
    echo
    return
  fi

  local hits
  hits="$(awk '
    function target(host, lower) {
      lower = tolower(host)
      return lower == "anthropic.com" || lower ~ /\.anthropic\.com$/ || lower == "claude.ai" || lower ~ /\.claude\.ai$/
    }
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      count = split(line, fields, /[[:space:]]+/)
      for (i = 2; i <= count; i++) {
        if (target(fields[i])) {
          print NR
          break
        }
      }
    }
  ' "$hosts" | paste -sd ',' -)"
  if [[ -z "$hits" ]]; then
    ok "/etc/hosts 中未发现 Claude/Anthropic 覆盖项。"
    echo
    return
  fi

  warn "在 /etc/hosts 中发现 Claude/Anthropic 覆盖项，行号: $hits（内容已隐藏）"

  if [[ "$FIX" -eq 1 ]]; then
    local tmp
    tmp="$(mktemp)"
    awk '
      function target(host, lower) {
        lower = tolower(host)
        return lower == "anthropic.com" || lower ~ /\.anthropic\.com$/ || lower == "claude.ai" || lower ~ /\.claude\.ai$/
      }
      {
        original = $0
        hash = index(original, "#")
        if (hash > 0) {
          comment = substr(original, hash)
          data = substr(original, 1, hash - 1)
        } else {
          comment = ""
          data = original
        }

        gsub(/^[[:space:]]+|[[:space:]]+$/, "", data)
        count = split(data, fields, /[[:space:]]+/)
        if (count < 2 || fields[1] == "") {
          print original
          next
        }

        output = fields[1]
        kept = 0
        removed = 0
        for (i = 2; i <= count; i++) {
          if (fields[i] == "") continue
          if (target(fields[i])) {
            removed = 1
          } else {
            output = output "\t" fields[i]
            kept++
          }
        }

        if (!removed) {
          print original
        } else if (kept > 0) {
          print output (comment != "" ? "\t" comment : "")
        } else if (comment != "") {
          print comment
        }
      }
    ' "$hosts" > "$tmp"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "将备份 /etc/hosts -> ${BACKUP_DIR}/etc_hosts"
      dry "将从 /etc/hosts 移除 Claude/Anthropic host 覆盖行"
      rm -f "$tmp"
    else
      if ! cp -p "$hosts" "${BACKUP_DIR}/etc_hosts" || ! chmod 600 "${BACKUP_DIR}/etc_hosts"; then
        fail "无法备份 /etc/hosts，已取消修改。"
      elif run_root_cmd cp "$tmp" "$hosts"; then
        fixed "已移除 /etc/hosts 中的 Claude/Anthropic 覆盖项。"
      else
        fail "无法编辑 /etc/hosts，可能是 sudo 授权失败或文件写入失败。"
      fi
      rm -f "$tmp"
    fi
  fi
  echo
}

extract_json_field() {
  local file="$1"
  local field="$2"
  if have plutil; then
    plutil -extract "$field" raw -o - "$file" 2>/dev/null && return 0
  fi
  if ! have python3; then
    return 1
  fi
  python3 - "$file" "$field" <<'PY' 2>/dev/null
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(1)
value = data
for part in field.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    sys.exit(1)
print(value)
PY
}

json_file_valid() {
  local file="$1"
  if have python3; then
    python3 -m json.tool "$file" >/dev/null 2>&1
    return $?
  fi
  if have plutil; then
    plutil -convert json -o /dev/null "$file" >/dev/null 2>&1
    return $?
  fi
  return 0
}

fetch_ip_json() {
  local tmp="$1"
  local user_agent="claude-mac-env-audit/$VERSION"
  curl -fsS -A "$user_agent" --max-time 8 https://ipinfo.io/json -o "$tmp" 2>/dev/null && json_file_valid "$tmp" && return 0
  curl -fsS -A "$user_agent" --max-time 8 https://ifconfig.co/json -o "$tmp" 2>/dev/null && json_file_valid "$tmp" && return 0
  curl -fsS -A "$user_agent" --max-time 8 https://ipapi.co/json -o "$tmp" 2>/dev/null && json_file_valid "$tmp" && return 0
  return 1
}

probe_family_country() {
  local family_flag="$1"
  local code
  code="$(curl "$family_flag" -fsS -A "claude-mac-env-audit/$VERSION" --connect-timeout 2 --max-time 4 https://ifconfig.co/country-iso 2>/dev/null || true)"
  code="$(printf '%s' "$code" | tr -d '\r\n[:space:]' | tr '[:lower:]' '[:upper:]')"
  if [[ "$code" == [A-Z][A-Z] ]]; then
    printf '%s' "$code"
    return 0
  fi
  return 1
}

audit_exit_ip() {
  echo "== 出口 IP =="
  if ! have curl; then
    warn "未找到 curl，无法检测出口 IP。"
    echo
    return
  fi

  local tmp ip country country_code org city region tz
  tmp="$(mktemp)"
  if ! fetch_ip_json "$tmp"; then
    fail "无法获取公网 IP 元数据。"
    rm -f "$tmp"
    echo
    return
  fi

  ip="$(extract_json_field "$tmp" ip || true)"
  country="$(extract_json_field "$tmp" country || extract_json_field "$tmp" country_name || true)"
  country_code="$(extract_json_field "$tmp" country_code || extract_json_field "$tmp" country_iso || true)"
  if [[ -z "$country_code" && "$country" == [A-Za-z][A-Za-z] ]]; then
    country_code="$country"
  fi
  country_code="$(normalize_country_code "$country_code")"
  org="$(extract_json_field "$tmp" org || extract_json_field "$tmp" asn.org || extract_json_field "$tmp" asn_org || extract_json_field "$tmp" asn || true)"
  city="$(extract_json_field "$tmp" city || true)"
  region="$(extract_json_field "$tmp" region || extract_json_field "$tmp" region_name || true)"
  tz="$(extract_json_field "$tmp" timezone || extract_json_field "$tmp" time_zone || true)"
  rm -f "$tmp"

  info "IP=${ip:-未知} 国家=${country:-未知} 国家代码=${country_code:-未知} 地区=${region:-未知} 城市=${city:-未知} 时区=${tz:-未知}"
  [[ -n "$org" ]] && info "ASN/组织=$org"
  info "这是本次运行的出口快照，不能单凭一次结果证明出口国家长期固定。"

  if [[ -n "$TARGET_COUNTRY" ]]; then
    if [[ -z "$country_code" ]]; then
      warn "无法确认出口国家代码，不能判断是否匹配目标国家 $TARGET_COUNTRY。"
    elif [[ "$country_code" == "$TARGET_COUNTRY" ]]; then
      ok "出口国家代码符合目标: $TARGET_COUNTRY。"
    else
      warn "当前出口国家代码是 ${country_code}，不等于目标 ${TARGET_COUNTRY}。如果你要求固定国家，建议切换到目标出口。"
    fi
  else
    if [[ -z "$country_code" ]]; then
      warn "无法确认当前出口国家代码。如需按国家检查，可传 --target-country CC。"
    elif [[ "$country_code" == "CN" ]]; then
      warn "当前出口国家代码是 CN。建议检查代理/TUN 是否按预期工作。"
    else
      ok "当前出口国家代码是 ${country_code}。默认策略接受中国大陆以外的国家；如需严格匹配，可传 --target-country ${country_code}。"
    fi
  fi

  local country_v4 country_v6
  country_v4="$(probe_family_country -4 || true)"
  country_v6="$(probe_family_country -6 || true)"
  [[ -n "$country_v4" ]] && info "IPv4 出口国家代码=$country_v4"
  if [[ -n "$country_v6" ]]; then
    info "IPv6 出口国家代码=$country_v6"
  else
    info "未检测到可用的 IPv6 公网出口。"
  fi

  if [[ -n "$country_v4" && -n "$country_v6" && "$country_v4" != "$country_v6" ]]; then
    warn "IPv4 与 IPv6 的出口国家不一致: $country_v4 / $country_v6。请检查 IPv6 是否绕过代理或 TUN。"
  fi
  if [[ -n "$TARGET_COUNTRY" ]]; then
    [[ -n "$country_v4" && "$country_v4" != "$TARGET_COUNTRY" ]] && warn "IPv4 出口不匹配目标国家 $TARGET_COUNTRY。"
    [[ -n "$country_v6" && "$country_v6" != "$TARGET_COUNTRY" ]] && warn "IPv6 出口不匹配目标国家 $TARGET_COUNTRY。"
  else
    [[ "$country_v4" == "CN" ]] && warn "IPv4 出口国家代码是 CN。"
    [[ "$country_v6" == "CN" ]] && warn "IPv6 出口国家代码是 CN，可能存在 IPv6 绕行。"
  fi

  local org_lc
  org_lc="$(printf '%s' "$org" | tr '[:upper:]' '[:lower:]')"
  if [[ "$org_lc" =~ "(aliyun|alibaba|tencent|qcloud|huawei|volc|bytedance|baidu|china|cn2|ctyun|ucloud)" ]]; then
    warn "ASN/组织看起来与中国云厂商或网络服务商有关。如非预期，建议换成目标国家内更中性的服务商或网络出口。"
  fi
  echo
}

audit_dns() {
  echo "== DNS =="
  local dns
  dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | sort -u | paste -sd ' ' -)"
  if [[ -z "$dns" ]]; then
    warn "无法读取 DNS nameserver。"
    echo
    return
  fi

  info "DNS 服务器: $dns"
  if echo "$dns" | grep -Eq '(^| )(114\.114\.114\.114|223\.5\.5\.5|223\.6\.6\.6|119\.29\.29\.29|180\.76\.76\.76)( |$)'; then
    warn "DNS 包含常见中国公共 DNS。若非预期，请优先检查代理/TUN 客户端的 DNS 设置；脚本不会自动改 DNS。"
  else
    ok "未检测到常见中国公共 DNS 解析器。"
  fi
  echo
}

audit_anthropic_reachability() {
  echo "== Anthropic 端点连通性 =="
  if ! have curl; then
    warn "未找到 curl，跳过端点连通性检测。"
    echo
    return
  fi

  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://api.anthropic.com/v1/messages 2>/dev/null || true)"
  case "$code" in
    000|"")
      warn "无法连接 https://api.anthropic.com/v1/messages。"
      ;;
    200|201|204|401|404|405)
      ok "api.anthropic.com 可达，返回 HTTP $code。"
      ;;
    403|429)
      warn "api.anthropic.com 可达，但返回 HTTP $code；这可能是访问策略、频率限制或网络环境问题。"
      ;;
    5??)
      warn "api.anthropic.com 返回 HTTP $code，远端服务或中间网络可能异常。"
      ;;
    *)
      info "api.anthropic.com 返回 HTTP $code。"
      ;;
  esac
  echo
}

final_summary() {
  echo "== 总结 =="
  echo "正常=$OK_COUNT 警告=$WARN_COUNT 已修复=$FIXED_COUNT 失败=$FAIL_COUNT 信息=$INFO_COUNT"
  echo "报告已保存到: $REPORT_FILE"
  echo "备份已保存到: $BACKUP_DIR"
  if [[ "$FIX" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    echo "重新检查环境变量前请打开一个新的终端会话；子进程无法移除父级 shell 中已经存在的变量。"
  fi
}

main() {
  print_header
  audit_os
  audit_timezone
  audit_system_proxy
  audit_launchctl_env
  audit_process_env
  audit_shell_startup_files
  audit_npm_yarn_pnpm
  audit_git_proxy
  audit_claude_configs
  audit_hosts_file
  audit_dns
  if [[ "$OFFLINE" -eq 1 ]]; then
    info "已启用 --offline，跳过公网 IP 和 Anthropic 端点联网检测。"
  else
    audit_exit_ip
    audit_anthropic_reachability
  fi
  final_summary
}

main "$@"

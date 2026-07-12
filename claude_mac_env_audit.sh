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
#   --dry-run       只显示将要修改的内容，不实际修改文件或系统设置。
#   --check-only    等同于 --dry-run，用于只检测不修复。
#   --aggressive    连仅提示风险的项目也自动修复，例如 Asia/Singapore 时区。
#   --target-tz TZ  自动修复时区时使用的目标时区，默认 Asia/Taipei。
#   --target-country CC  指定固定出口国家，两位国家代码，例如 US、JP、SG。

set -u
set -o pipefail

FIX=1
DRY_RUN=0
AGGRESSIVE=0
TARGET_TZ="${TARGET_TZ:-Asia/Taipei}"
TARGET_COUNTRY="${TARGET_COUNTRY:-}"
TS="$(date +%Y%m%d-%H%M%S)"
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
  ${SCRIPT_NAME} [--dry-run|--check-only] [--aggressive] [--target-tz TZ] [--target-country CC]

默认行为:
  执行检测，并在可安全自动处理的地方直接修复。
  清理第三方 API 痕迹前会询问确认。
  修改系统设置或 /etc/hosts 时会按需申请 sudo 权限。
  修改用户文件或 /etc/hosts 前会先创建备份。
  不会删除账号、应用、钥匙串、支付数据或浏览器配置。

常用参数:
  --dry-run       只显示将要修改的内容，不实际修改文件或系统设置。
  --check-only    等同于 --dry-run，用于只检测不修复。
  --aggressive    连仅提示风险的项目也自动修复，例如 Asia/Singapore 时区。
  --target-tz TZ  自动修复时区时使用的目标时区，默认 Asia/Taipei。
  --target-country CC  指定固定出口国家，两位国家代码，例如 US、JP、SG。
  -h, --help      显示帮助。
EOF
}

normalize_country_code() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--check-only)
      DRY_RUN=1
      FIX=0
      shift
      ;;
    --no-fix)
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

mkdir -p "$BACKUP_DIR" "$REPORT_DIR"
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

has_third_party_api_trace() {
  local file="$1"
  grep -Eiq '(ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|CLAUDE_.*BASE|CLAUDE_API_BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|base[_-]?url|baseUrl|api[_-]?base|endpoint|aihubmix|openai-sb|oneapi|newapi|siliconflow|deepseek|moonshot|kimi|zhipu|minimax)' "$file"
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
    mkdir -p "$(dirname "$dest")"
    cp -p "$file" "$dest"
  fi
  return 0
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "$*"
    return 0
  fi
  "$@"
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
  echo "Claude Code macOS 环境检测"
  echo "报告: $REPORT_FILE"
  echo "备份: $BACKUP_DIR"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "模式: 仅预览，不做修改"
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
  local sys_tz node_tz
  sys_tz="$(current_system_timezone)"
  node_tz="$(current_node_timezone)"

  info "系统时区: ${sys_tz:-未知}"
  [[ -n "$node_tz" ]] && info "node Intl 时区: $node_tz"

  local should_fix=0
  case "$sys_tz" in
    Asia/Shanghai|Asia/Urumqi)
      warn "当前是中国大陆时区，目标时区为 $TARGET_TZ。"
      should_fix=1
      ;;
    Asia/Singapore)
      warn "当前是 Asia/Singapore。原文把它视为较高风险的兜底时区；使用 --aggressive 会自动改掉。"
      [[ "$AGGRESSIVE" -eq 1 ]] && should_fix=1
      ;;
    "$TARGET_TZ")
      ok "时区已经符合目标: $TARGET_TZ"
      ;;
    "")
      warn "无法读取系统时区。"
      ;;
    *)
      ok "当前时区不属于此脚本处理的高风险值。"
      ;;
  esac

  if [[ "$should_fix" -eq 1 && "$FIX" -eq 1 ]]; then
    if run_root_cmd systemsetup -settimezone "$TARGET_TZ"; then
      fixed "已将时区设置为 $TARGET_TZ。"
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
    /(HTTPProxy|HTTPSProxy|SOCKSProxy|FTPProxy|GopherProxy|RTSPProxy|ProxyAutoConfigURLString) : / { print }
  '
}

disable_proxy_for_service() {
  local service="$1"
  run_root_quiet networksetup -setwebproxystate "$service" off
  run_root_quiet networksetup -setsecurewebproxystate "$service" off
  run_root_quiet networksetup -setsocksfirewallproxystate "$service" off
  run_root_quiet networksetup -setftpproxystate "$service" off
  run_root_quiet networksetup -setgopherproxystate "$service" off
  run_root_quiet networksetup -setstreamingproxystate "$service" off
  run_root_quiet networksetup -setautoproxystate "$service" off
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
    ok "macOS 系统代理为空。"
  else
    warn "macOS 系统代理已启用，或存在代理配置值:"
    echo "$before"

    if [[ "$FIX" -eq 1 ]]; then
      local svc
      local changed=0
      while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        disable_proxy_for_service "$svc"
        changed=1
      done < <(network_services)

      if [[ "$changed" -eq 1 ]]; then
        local after
        after="$(proxy_enabled_snapshot)"
        if [[ -z "$after" || "$DRY_RUN" -eq 1 ]]; then
          fixed "已关闭所有网络服务的 HTTP/HTTPS/SOCKS/PAC 系统代理状态。"
        else
          fail "已尝试关闭系统代理，但仍残留部分代理设置:"
          echo "$after"
        fi
      else
        fail "未找到可更新的网络服务。"
      fi
    fi
  fi

  local utuns
  utuns="$(ifconfig 2>/dev/null | awk -F: '/^utun[0-9]+:/{print $1}' | paste -sd ' ' -)"
  if [[ -n "$utuns" ]]; then
    ok "检测到 utun 接口: $utuns"
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
NO_PROXY
http_proxy
https_proxy
all_proxy
no_proxy
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
      warn "launchctl $name=$value"
      if [[ "$FIX" -eq 1 ]]; then
        if run_cmd launchctl unsetenv "$name"; then
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
  matches="$(env | grep -Ei '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*(PROXY|BASE|URL|ENDPOINT)|OPENAI_BASE_URL)=' || true)"
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
  [[ -f "$file" ]] || return 1

  if ! grep -Eiq '(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm +config +set +.*proxy|yarn +config +set +.*proxy|pnpm +config +set +.*proxy|git +config +.*http.*proxy)' "$file"; then
    return 1
  fi

  warn "在 $file 中发现可疑的代理或基础 URL 配置行"
  grep -Ein '(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm +config +set +.*proxy|yarn +config +set +.*proxy|pnpm +config +set +.*proxy|git +config +.*http.*proxy)' "$file" || true

  if [[ "$FIX" -ne 1 ]]; then
    return 0
  fi

  if has_third_party_api_trace "$file"; then
    if ! confirm_third_party_api_cleanup "$file"; then
      return 0
    fi
  fi

  backup_file "$file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    fixed "将注释 $file 中的可疑配置行。"
    return 0
  fi

  perl -pi -e '
    if (/^\s*#/) { next; }
    if (/(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm\s+config\s+set\s+.*proxy|yarn\s+config\s+set\s+.*proxy|pnpm\s+config\s+set\s+.*proxy|git\s+config\s+.*http.*proxy)/i) {
      $_ = "# claude-mac-env-audit 已禁用: " . $_;
    }
  ' "$file"
  fixed "已注释 $file 中的可疑配置行。"
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
    for key in proxy https-proxy noproxy; do
      value="$(npm config get "$key" 2>/dev/null || true)"
      if [[ -n "$value" && "$value" != "null" && "$value" != "undefined" ]]; then
        saw=1
        warn "npm $key=$value"
        if [[ "$FIX" -eq 1 ]]; then
          if run_cmd npm config delete "$key"; then
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
        warn "yarn $ykey=$yvalue"
        [[ "$FIX" -eq 1 ]] && run_cmd yarn config delete "$ykey" >/dev/null 2>&1 && fixed "已删除 yarn 配置 $ykey。"
      fi
    done
  fi

  if have pnpm; then
    local pkey pvalue
    for pkey in proxy https-proxy noproxy; do
      pvalue="$(pnpm config get "$pkey" 2>/dev/null || true)"
      if [[ -n "$pvalue" && "$pvalue" != "undefined" && "$pvalue" != "null" ]]; then
        saw=1
        warn "pnpm $pkey=$pvalue"
        [[ "$FIX" -eq 1 ]] && run_cmd pnpm config delete "$pkey" >/dev/null 2>&1 && fixed "已删除 pnpm 配置 $pkey。"
      fi
    done
  fi

  local npmrc="$HOME/.npmrc"
  if [[ -f "$npmrc" ]] && grep -Eiq '(^|-)proxy\s*=' "$npmrc"; then
    saw=1
    warn "在 $npmrc 中发现代理配置行"
    grep -Ein '(^|-)proxy\s*=' "$npmrc" || true
    if [[ "$FIX" -eq 1 ]]; then
      backup_file "$npmrc"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        fixed "将注释 $npmrc 中的代理配置行。"
      else
        perl -pi -e 'if (/^\s*#/){next}; if (/(^|-)proxy\s*=/i){$_="# claude-mac-env-audit 已禁用: ".$_}' "$npmrc"
        fixed "已注释 $npmrc 中的代理配置行。"
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
      warn "git $key=$value"
      if [[ "$FIX" -eq 1 ]]; then
        if run_cmd git config --global --unset-all "$key"; then
          fixed "已清除 git 配置 $key。"
        else
          fail "无法清除 git 配置 $key。"
        fi
      fi
    fi
  done

  local extra
  extra="$(git config --global --list 2>/dev/null | grep -Ei '(proxy|anthropic|claude|baseurl|base-url)' || true)"
  if [[ -n "$extra" ]]; then
    warn "仍存在其他相关的全局 git 配置:"
    echo "$extra"
  elif [[ "$saw" -eq 0 ]]; then
    ok "未发现全局 git 代理配置。"
  fi
  echo
}

json_scrub_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  if ! grep -Eiq '(proxy|base[_-]?url|baseUrl|api[_-]?base|endpoint|ANTHROPIC_BASE_URL|CLAUDE_CODE_ROUTER)' "$file"; then
    return 0
  fi

  warn "Claude 或工具配置中包含代理或自定义端点字段: $file"
  grep -Ein '(proxy|base[_-]?url|baseUrl|api[_-]?base|endpoint|ANTHROPIC_BASE_URL|CLAUDE_CODE_ROUTER)' "$file" || true

  if [[ "$FIX" -ne 1 ]]; then
    return 0
  fi

  if ! confirm_third_party_api_cleanup "$file"; then
    return 0
  fi

  backup_file "$file"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    fixed "将从 $file 中清理代理或基础 URL 字段。"
    return 0
  fi

  python3 - "$file" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception as exc:
    print(f"无法解析 JSON，保持文件不变: {path}: {exc}")
    sys.exit(2)

bad_key = re.compile(r"(proxy|base[_-]?url|baseUrl|api[_-]?base|endpoint|ANTHROPIC_BASE_URL|CLAUDE_CODE_ROUTER)", re.I)

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
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"已清理 {path}")
else:
    print(f"未从 {path} 删除 JSON 字段")
PY
  case "$?" in
    0) fixed "已从 $file 清理代理或基础 URL 字段。" ;;
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
        ! -path '*/history.jsonl' \
        ! -path '*/backups/*' \
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
  hits="$(grep -Ein '(anthropic|claude\.ai|api\.anthropic\.com)' "$hosts" || true)"
  if [[ -z "$hits" ]]; then
    ok "/etc/hosts 中未发现 Claude/Anthropic 覆盖项。"
    echo
    return
  fi

  warn "在 /etc/hosts 中发现 Claude/Anthropic 覆盖项:"
  echo "$hits"

  if [[ "$FIX" -eq 1 ]]; then
    local tmp
    tmp="$(mktemp)"
    awk 'tolower($0) !~ /(anthropic|claude\.ai|api\.anthropic\.com)/ { print }' "$hosts" > "$tmp"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      dry "将备份 /etc/hosts -> ${BACKUP_DIR}/etc_hosts"
      dry "将从 /etc/hosts 移除 Claude/Anthropic host 覆盖行"
      fixed "将移除 /etc/hosts 中的 Claude/Anthropic 覆盖项。"
      rm -f "$tmp"
    else
      if run_root_cmd cp "$hosts" "${BACKUP_DIR}/etc_hosts" && run_root_cmd cp "$tmp" "$hosts"; then
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

fetch_ip_json() {
  local tmp="$1"
  curl -fsS --max-time 8 https://ipinfo.io/json -o "$tmp" 2>/dev/null && return 0
  curl -fsS --max-time 8 https://ifconfig.co/json -o "$tmp" 2>/dev/null && return 0
  curl -fsS --max-time 8 https://ipapi.co/json -o "$tmp" 2>/dev/null && return 0
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
  country="$(extract_json_field "$tmp" country || true)"
  country_code="$(extract_json_field "$tmp" country_code || extract_json_field "$tmp" country_iso || true)"
  if [[ -z "$country_code" && "$country" == [A-Za-z][A-Za-z] ]]; then
    country_code="$country"
  fi
  country_code="$(normalize_country_code "$country_code")"
  org="$(extract_json_field "$tmp" org || extract_json_field "$tmp" asn.org || true)"
  city="$(extract_json_field "$tmp" city || true)"
  region="$(extract_json_field "$tmp" region || true)"
  tz="$(extract_json_field "$tmp" timezone || true)"
  rm -f "$tmp"

  info "IP=${ip:-未知} 国家=${country:-未知} 国家代码=${country_code:-未知} 地区=${region:-未知} 城市=${city:-未知} 时区=${tz:-未知}"
  [[ -n "$org" ]] && info "ASN/组织=$org"

  if [[ -n "$TARGET_COUNTRY" ]]; then
    if [[ -z "$country_code" ]]; then
      warn "无法确认出口国家代码，不能判断是否匹配目标国家 $TARGET_COUNTRY。"
    elif [[ "$country_code" == "$TARGET_COUNTRY" ]]; then
      ok "出口国家代码符合目标: $TARGET_COUNTRY。"
    else
      warn "出口国家代码是 ${country_code}，不等于目标 ${TARGET_COUNTRY}。如果你要求固定国家，建议切换到目标出口。"
    fi
  else
    if [[ -z "$country_code" ]]; then
      warn "无法确认出口国家代码。建议使用中国大陆以外的固定出口；如需严格检查，可传 --target-country CC。"
    elif [[ "$country_code" == "CN" ]]; then
      warn "出口国家代码是 CN。建议使用中国大陆以外的固定出口。"
    else
      ok "出口国家代码是 ${country_code}。默认策略接受中国大陆以外的固定出口；如需严格固定国家，可传 --target-country ${country_code}。"
    fi
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
    warn "DNS 包含常见中国公共 DNS。若非预期，建议把当前网络服务切到 1.1.1.1 / 8.8.8.8。"
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
    401|403|404|405)
      ok "api.anthropic.com 可达；无凭证时返回 HTTP $code 属于预期。"
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
  audit_exit_ip
  audit_dns
  audit_anthropic_reachability
  final_summary
}

main "$@"

#!/usr/bin/env zsh

set -eu
set -o pipefail

ROOT_DIR="${0:A:h:h}"
SCRIPT="${ROOT_DIR}/claude_mac_env_audit.sh"
TEST_HOME="$(mktemp -d)"
OUTPUT="$(mktemp)"
CHECK_OUTPUT="$(mktemp)"

cleanup() {
  rm -rf "$TEST_HOME" "$OUTPUT" "$CHECK_OUTPUT"
}
trap cleanup EXIT

fail() {
  print -u2 -- "测试失败: $*"
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "未找到预期文本: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "发现不应出现的文本: $unexpected"
  fi
}

mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/bin"
print -r -- '#!/usr/bin/env zsh
if [[ "$1" == "getenv" && "$2" == "ANTHROPIC_BASE_URL" ]]; then
  print -- "https://launchctl-private.example"
elif [[ "$1" == "unsetenv" ]]; then
  print -- "$2" >> "$TEST_LAUNCHCTL_LOG"
fi' > "$TEST_HOME/bin/launchctl"
chmod +x "$TEST_HOME/bin/launchctl"
export PATH="$TEST_HOME/bin:$PATH"
export TEST_LAUNCHCTL_LOG="$TEST_HOME/launchctl-unset.log"

print -r -- 'export HTTP_PROXY=http://audit-user:audit-password@127.0.0.1:7890' > "$TEST_HOME/.zshrc"
print -r -- 'export NO_PROXY=localhost,127.0.0.1' >> "$TEST_HOME/.zshrc"

print -r -- '{
  "env": {
    "ANTHROPIC_BASE_URL": "https://private-api.example",
    "ANTHROPIC_API_KEY": "private-api-key"
  },
  "mcpServers": {
    "example": {
      "endpoint": "https://endpoint-must-stay.example"
    }
  }
}' > "$TEST_HOME/.claude/settings.json"

zsh -n "$SCRIPT"
[[ "$($SCRIPT --version)" == "1.1.0" ]] || fail "版本号不正确"
HOME="$TEST_HOME" "$SCRIPT" --dry-run --offline > "$OUTPUT"

assert_contains "$OUTPUT" "模式: 仅预览，不修改系统或用户配置（仍生成本地报告）"
assert_contains "$OUTPUT" "行号: 1（内容已隐藏）"
assert_contains "$OUTPUT" '[预览] 将注释'
assert_contains "$OUTPUT" '$.env.ANTHROPIC_BASE_URL'
assert_contains "$OUTPUT" '实际修复前会询问是否清除第三方 API 痕迹: launchctl 环境变量 ANTHROPIC_BASE_URL'
assert_contains "$OUTPUT" '将清除 launchctl 环境变量 ANTHROPIC_BASE_URL'
assert_not_contains "$OUTPUT" 'audit-password'
assert_not_contains "$OUTPUT" 'launchctl-private.example'
assert_not_contains "$OUTPUT" 'private-api.example'
assert_not_contains "$OUTPUT" 'private-api-key'
assert_not_contains "$OUTPUT" '$.mcpServers.example.endpoint'
assert_not_contains "$OUTPUT" '[已修复]'

grep -Fq 'HTTP_PROXY=http://audit-user:audit-password@127.0.0.1:7890' "$TEST_HOME/.zshrc" || fail "dry-run 修改了 shell 启动文件"
grep -Fq 'NO_PROXY=localhost,127.0.0.1' "$TEST_HOME/.zshrc" || fail "NO_PROXY 被修改"
grep -Fq 'private-api.example' "$TEST_HOME/.claude/settings.json" || fail "dry-run 修改了 JSON 配置"
grep -Fq 'endpoint-must-stay.example' "$TEST_HOME/.claude/settings.json" || fail "通用 endpoint 字段被修改"
[[ ! -e "$TEST_LAUNCHCTL_LOG" ]] || fail "dry-run 执行了 launchctl unsetenv"

REPORT_FILE="$(find "$TEST_HOME/.claude-mac-env-audit/reports" -type f -name 'report-*.log' | head -1)"
[[ -n "$REPORT_FILE" ]] || fail "未生成报告"
[[ "$(stat -f '%Lp' "$REPORT_FILE")" == "600" ]] || fail "报告权限不是 600"

HOME="$TEST_HOME" "$SCRIPT" --check-only --offline > "$CHECK_OUTPUT"
assert_not_contains "$CHECK_OUTPUT" '[预览]'

if HOME="$TEST_HOME" "$SCRIPT" --target-country USA --offline >/dev/null 2>&1; then
  fail "错误国家代码未被拒绝"
fi

if HOME="$TEST_HOME" "$SCRIPT" --target-tz Invalid/Timezone --offline >/dev/null 2>&1; then
  fail "错误时区未被拒绝"
fi

print -- "全部测试通过"

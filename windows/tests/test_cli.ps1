#Requires -Version 5.1
# claude-win-env-audit 隔离测试。
# 测试只在临时目录内操作，不改动真实用户配置、注册表和 hosts。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root 'claude_win_env_audit.ps1'
if (-not (Test-Path -LiteralPath $target)) {
  Write-Host '[失败] 找不到 claude_win_env_audit.ps1'
  exit 1
}

$psExe = (Get-Process -Id $PID).Path
$tmpRoot = Join-Path $root '.test-tmp'
$workDir = Join-Path $tmpRoot ([guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $workDir 'home'
$reportStub = $null

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Label)
  if (-not $Text.Contains($Expected)) {
    Write-Host ('[失败] ' + $Label + ': 未找到预期文本: ' + $Expected)
    throw 'assert-contains'
  }
}

function Assert-NotContains {
  param([string]$Text, [string]$Unexpected, [string]$Label)
  if ($Text.Contains($Unexpected)) {
    Write-Host ('[失败] ' + $Label + ': 发现不应出现的文本: ' + $Unexpected)
    throw 'assert-not-contains'
  }
}

function Invoke-AuditCli {
  param([string[]]$Arguments)
  $output = & $psExe -NoProfile -ExecutionPolicy Bypass -File $target @Arguments 2>&1 | Out-String
  $code = $LASTEXITCODE
  return [pscustomobject]@{ Text = $output; ExitCode = $code }
}

function Assert-FileContains {
  param([string]$Path, [string]$Expected, [string]$Label)
  $text = [System.IO.File]::ReadAllText($Path)
  if (-not $text.Contains($Expected)) {
    Write-Host ('[失败] ' + $Label + ': ' + $Path + ' 中缺少: ' + $Expected)
    throw 'assert-file-contains'
  }
}

function Assert-FileNotContains {
  param([string]$Path, [string]$Unexpected, [string]$Label)
  $text = [System.IO.File]::ReadAllText($Path)
  if ($text.Contains($Unexpected)) {
    Write-Host ('[失败] ' + $Label + ': ' + $Path + ' 中不应出现: ' + $Unexpected)
    throw 'assert-file-not-contains'
  }
}

try {
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome 'Documents\WindowsPowerShell') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null

  # 模拟 PowerShell 启动文件
  $profilePath = Join-Path $fakeHome 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
  $profileLines = @(
    '$env:HTTP_PROXY = ''http://audit-user:audit-password@127.0.0.1:7890''',
    '$env:NO_PROXY = ''localhost,127.0.0.1'''
  )
  Set-Content -LiteralPath $profilePath -Value $profileLines -Encoding UTF8

  # 模拟 Claude 配置，包含第三方 base URL 与必须保留的通用 endpoint
  $settingsPath = Join-Path $fakeHome '.claude\settings.json'
  $settings = @'
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://private-api.example",
    "ANTHROPIC_API_KEY": "private-api-key"
  },
  "mcpServers": {
    "example": {
      "endpoint": "https://endpoint-must-stay.example"
    }
  }
}
'@
  Set-Content -LiteralPath $settingsPath -Value $settings -Encoding UTF8

  # 语法检查
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    Write-Host ('[失败] 语法解析出错: ' + $errors[0].Message)
    throw 'syntax'
  }

  # 版本号
  $versionResult = Invoke-AuditCli -Arguments @('-Version')
  if ($versionResult.ExitCode -ne 0) { throw '版本号命令退出码非 0' }
  Assert-Contains -Text $versionResult.Text -Expected '1.0.0' -Label '版本号'

  # dry-run
  $dryRun = Invoke-AuditCli -Arguments @('-DryRun', '-Offline', '-AuditHome', $fakeHome)
  Assert-Contains -Text $dryRun.Text -Expected '模式: 仅预览，不修改系统或用户配置（仍会生成本地报告）' -Label 'dry-run 模式'
  Assert-Contains -Text $dryRun.Text -Expected '行号: 1（内容已隐藏）' -Label 'dry-run 行号'
  Assert-Contains -Text $dryRun.Text -Expected '[预览] 将注释' -Label 'dry-run 预览注释'
  Assert-Contains -Text $dryRun.Text -Expected '$.env.ANTHROPIC_BASE_URL' -Label 'dry-run 字段路径'
  Assert-Contains -Text $dryRun.Text -Expected '实际修复前会询问是否清除第三方 API 痕迹' -Label 'dry-run 确认门'
  Assert-NotContains -Text $dryRun.Text -Unexpected 'audit-password' -Label 'dry-run 隐藏密码'
  Assert-NotContains -Text $dryRun.Text -Unexpected 'private-api.example' -Label 'dry-run 隐藏 base URL'
  Assert-NotContains -Text $dryRun.Text -Unexpected 'private-api-key' -Label 'dry-run 隐藏 key'
  Assert-NotContains -Text $dryRun.Text -Unexpected '$.mcpServers.example.endpoint' -Label 'dry-run 不碰通用 endpoint'
  Assert-NotContains -Text $dryRun.Text -Unexpected '[已修复]' -Label 'dry-run 不修复'

  Assert-FileContains -Path $profilePath -Expected 'audit-password' -Label 'dry-run 未改启动文件'
  Assert-FileContains -Path $profilePath -Expected 'NO_PROXY' -Label 'dry-run 未改 NO_PROXY'
  Assert-FileContains -Path $settingsPath -Expected 'private-api.example' -Label 'dry-run 未改 JSON'
  Assert-FileContains -Path $settingsPath -Expected 'endpoint-must-stay.example' -Label 'dry-run 未改 endpoint'

  # 报告文件
  $reportDir = Join-Path $fakeHome '.claude-win-env-audit\reports'
  $reports = @(Get-ChildItem -LiteralPath $reportDir -Filter 'report-*.log' -ErrorAction SilentlyContinue)
  if ($reports.Count -lt 1) { throw '未生成报告文件' }

  # check-only
  $checkOnly = Invoke-AuditCli -Arguments @('-CheckOnly', '-Offline', '-AuditHome', $fakeHome)
  Assert-NotContains -Text $checkOnly.Text -Unexpected '[预览]' -Label 'check-only 无预览'

  # 真实修复：只跑 claude-configs，限制在临时目录
  $fixResult = Invoke-AuditCli -Arguments @('-Only', 'claude-configs', '-Force', '-Offline', '-AuditHome', $fakeHome)
  Assert-Contains -Text $fixResult.Text -Expected '[已修复]' -Label 'JSON 清理已修复'
  Assert-FileNotContains -Path $settingsPath -Unexpected 'ANTHROPIC_BASE_URL' -Label 'JSON 已清理 base URL'
  Assert-FileNotContains -Path $settingsPath -Unexpected 'private-api.example' -Label 'JSON 已清理值'
  Assert-FileContains -Path $settingsPath -Expected 'endpoint-must-stay.example' -Label 'JSON 保留 endpoint'
  Assert-FileContains -Path $settingsPath -Expected 'private-api-key' -Label 'JSON 保留 API key 字段'

  $backupDir = Join-Path $fakeHome '.claude-win-env-audit\backups'
  $backups = @(Get-ChildItem -LiteralPath $backupDir -Recurse -File -ErrorAction SilentlyContinue)
  if ($backups.Count -lt 1) { throw '修复前未生成备份' }

  # 参数校验
  $badCountry = Invoke-AuditCli -Arguments @('-TargetCountry', 'USA', '-Offline', '-AuditHome', $fakeHome)
  if ($badCountry.ExitCode -ne 2) { throw '错误国家代码未被拒绝（期望退出码 2）' }

  $badTz = Invoke-AuditCli -Arguments @('-TargetTz', 'Invalid/Timezone', '-Offline', '-AuditHome', $fakeHome)
  if ($badTz.ExitCode -ne 2) { throw '错误时区未被拒绝（期望退出码 2）' }

  $badSection = Invoke-AuditCli -Arguments @('-Only', 'no-such-section', '-Offline', '-AuditHome', $fakeHome)
  if ($badSection.ExitCode -ne 2) { throw '未知小节未被拒绝（期望退出码 2）' }

  $script:TestPassed = $true
  Write-Host '全部测试通过'
} catch {
  if ($_.Exception.Message -in @('assert-contains', 'assert-not-contains', 'assert-file-contains', 'assert-file-not-contains', 'syntax')) {
    Write-Host '[失败] 测试未通过'
  } else {
    Write-Host ('[失败] ' + $_.Exception.Message)
  }
  if ($null -ne $fixResult) {
    Write-Host '--- 修复运行输出 ---'
    Write-Host $fixResult.Text
    Write-Host '--- 输出结束 ---'
  }
  Write-Host ('测试目录保留在: ' + $workDir)
  exit 1
} finally {
  if ($script:TestPassed -and (Test-Path -LiteralPath $workDir)) {
    try { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

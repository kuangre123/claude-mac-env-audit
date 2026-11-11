#Requires -Version 5.1
# claude-win-env-audit 图形界面的委托测试：
# 1) 主脚本与 GUI 脚本语法
# 2) GUI 的 XAML 与控件完整性
# 3) 审计事件流（GUI 数据来源）结构正确
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$engine = Join-Path $root 'claude_win_env_audit.ps1'
$gui = Join-Path $root 'app\ClaudeWinEnvAudit.Gui.ps1'
$psExe = (Get-Process -Id $PID).Path

$tmpRoot = Join-Path $root '.test-tmp'
$workDir = Join-Path $tmpRoot ([guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $workDir 'home'
$eventPath = Join-Path $workDir 'events.jsonl'
$script:TestPassed = $false

function Assert-True {
  param([bool]$Condition, [string]$Label)
  if (-not $Condition) {
    Write-Host ('[失败] ' + $Label)
    throw 'assert-true'
  }
}

function Assert-EngineSyntax {
  param([string]$Path)
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    Write-Host ('[失败] 语法错误 ' + $Path + ': ' + $errors[0].Message)
    throw 'syntax'
  }
}

try {
  Assert-True (Test-Path -LiteralPath $engine) '找不到主脚本'
  Assert-True (Test-Path -LiteralPath $gui) '找不到 GUI 脚本'
  Assert-EngineSyntax -Path $engine
  Assert-EngineSyntax -Path $gui
  Write-Host '[通过] 脚本语法检查'

  # XAML 与控件完整性
  $validate = & $psExe -NoProfile -STA -ExecutionPolicy Bypass -File $gui -ValidateOnly 2>&1 | Out-String
  $validateCode = $LASTEXITCODE
  Assert-True ($validateCode -eq 0) ('XAML 校验退出码 ' + $validateCode + ' 输出: ' + $validate)
  Assert-True ($validate.Contains('XAML OK')) 'XAML 校验未输出 XAML OK'
  Write-Host '[通过] XAML 与控件校验'

  # 审计事件流
  New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
  $runOut = & $psExe -NoProfile -ExecutionPolicy Bypass -File $engine -DryRun -Offline -Only os,timezone -AuditHome $fakeHome -EventLog $eventPath 2>&1 | Out-String
  $runCode = $LASTEXITCODE
  Assert-True ($runCode -eq 0) ('审计事件流运行退出码 ' + $runCode)
  Assert-True (Test-Path -LiteralPath $eventPath) '未生成事件文件'

  $rawLines = [System.IO.File]::ReadAllLines($eventPath, [System.Text.Encoding]::UTF8)
  Assert-True ($rawLines.Count -gt 0) '事件文件为空'

  $events = @()
  foreach ($line in $rawLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $events += ($line | ConvertFrom-Json)
  }

  $meta = @($events | Where-Object { $_.type -eq 'meta' })
  Assert-True ($meta.Count -eq 1) '缺少唯一的 meta 事件'
  Assert-True ([int]$meta[0].total -eq 2) ('meta.total 应为 2，实际 ' + $meta[0].total)
  Assert-True ($meta[0].offline -is [bool]) 'meta.offline 必须是布尔值'

  $starts = @($events | Where-Object { $_.type -eq 'section-start' })
  $ends = @($events | Where-Object { $_.type -eq 'section-end' })
  Assert-True ($starts.Count -eq 2) ('section-start 数量应为 2，实际 ' + $starts.Count)
  Assert-True ($ends.Count -eq 2) ('section-end 数量应为 2，实际 ' + $ends.Count)
  Assert-True ($starts[0].section -eq 'os') '第一个检查项应为 os'
  Assert-True ($starts[1].section -eq 'timezone') '第二个检查项应为 timezone'
  Assert-True ([int]$starts[1].index -eq 2) 'section-start 序号应递增'

  $findings = @($events | Where-Object { $_.type -eq 'finding' })
  Assert-True ($findings.Count -gt 0) '缺少 finding 事件'
  $validLevels = @('正常', '信息', '警告', '已修复', '失败', '预览')
  foreach ($finding in $findings) {
    Assert-True ($validLevels -contains [string]$finding.level) ('未知级别: ' + $finding.level)
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$finding.message)) 'finding.message 为空'
  }

  $done = @($events | Where-Object { $_.type -eq 'done' })
  Assert-True ($done.Count -eq 1) '缺少唯一的 done 事件'
  Assert-True ([int]$done[0].total -eq 2) 'done.total 应为 2'
  $sum = [int]$done[0].ok + [int]$done[0].warn + [int]$done[0].fixed + [int]$done[0].fail + [int]$done[0].info
  Assert-True ($sum -eq $findings.Count) ('done 计数之和应等于 finding 数量: ' + $sum + ' vs ' + $findings.Count)
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$done[0].reportFile)) 'done.reportFile 为空'
  Write-Host ('[通过] 事件流结构（meta/section/finding/done，共 ' + $events.Count + ' 条事件）')

  $script:TestPassed = $true
  Write-Host '全部测试通过'
} catch {
  if ($_.Exception.Message -in @('assert-true', 'syntax')) {
    Write-Host '[失败] 测试未通过'
  } else {
    Write-Host ('[失败] ' + $_.Exception.Message)
  }
  Write-Host ('测试目录保留在: ' + $workDir)
  exit 1
} finally {
  if ($script:TestPassed -and (Test-Path -LiteralPath $workDir)) {
    try { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

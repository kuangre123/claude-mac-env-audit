#Requires -Version 5.1
<#
.SYNOPSIS
  Claude Code Windows 环境检测与修复脚本。

.DESCRIPTION
  claude-mac-env-audit 的 Windows 实现。用于排查常见的代理、时区、DNS、
  hosts、包管理器代理、Claude / Claude Code Router 配置残留等问题，并给出中文建议。

  默认行为:
  - 执行检测，并在可安全自动处理的地方直接修复。
  - 清理第三方 API 痕迹前会询问确认（-Force 可跳过询问）。
  - 修改系统级设置（时区、WinHTTP 代理、hosts、机器级环境变量）需要管理员权限；
    未提权时只会提示并跳过，可加 -Elevate 自动以管理员身份重启本脚本。
  - 修改用户文件或 hosts 前会先创建备份。
  - 不会删除账号、应用、凭据、支付数据或浏览器配置。

.PARAMETER DryRun
  预览将要执行的修复，不修改系统或用户配置；仍会生成本地报告。

.PARAMETER CheckOnly
  只检测，不显示拟执行的修复动作。等同 -NoFix。

.PARAMETER Aggressive
  中国大陆时区（China Standard Time）且未指定目标时区时，使用
  Taiwan Standard Time 作为迁移目标；不会修改其他境外时区。

.PARAMETER TargetTz
  明确指定要检查并修复到的目标时区，可写 Windows 时区 ID（如 Tokyo Standard Time）
  或常用 IANA 名称（如 Asia/Tokyo）。

.PARAMETER TargetCountry
  指定期望的出口国家，两位国家代码，例如 US、JP、SG。

.PARAMETER Only
  只执行指定小节，逗号分隔，例如 -Only timezone,claude-configs。

.PARAMETER Offline
  跳过公网 IP 和 Anthropic 端点联网检测。

.PARAMETER Force
  自动确认第三方 API 痕迹清理，不再逐个询问。请确认这些配置确实不再使用。

.PARAMETER NonInteractive
  没有可交互终端时使用；会跳过所有需要人工确认的清理。

.PARAMETER Elevate
  需要管理员权限时，自动以管理员身份重新启动本脚本。

.PARAMETER AuditHome
  指定用户主目录（用于测试或审计其他用户配置），默认 $env:USERPROFILE。

.EXAMPLE
  .\claude_win_env_audit.ps1 -DryRun

.EXAMPLE
  .\claude_win_env_audit.ps1 -TargetTz Asia/Tokyo -TargetCountry JP

.EXAMPLE
  .\claude_win_env_audit.ps1 -CheckOnly -Offline
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$CheckOnly,
  [switch]$NoFix,
  [switch]$Aggressive,
  [string]$TargetTz = '',
  [string]$TargetCountry = '',
  [string[]]$Only = @(),
  [switch]$Offline,
  [switch]$Force,
  [switch]$NonInteractive,
  [switch]$Elevate,
  [string]$AuditHome = '',
  [string]$EventLog = '',
  [switch]$Version,
  [switch]$Help
)

$script:ScriptVersion = '1.0.0'
$script:SCRIPT_NAME = [System.IO.Path]::GetFileName($MyInvocation.MyCommand.Path)
$script:IsWindowsHost = $true
if ($PSVersionTable.PSEdition -eq 'Core') {
  $script:IsWindowsHost = [bool]$IsWindows
}

# ------------------------------------------------------------
# 命令行帮助
# ------------------------------------------------------------
function Write-Usage {
  $lines = @(
    ('Claude Code Windows 环境检测与修复脚本 v' + $script:ScriptVersion),
    '',
    '用法:',
    ('  ' + $script:SCRIPT_NAME + ' [-DryRun|-CheckOnly|-NoFix] [-Aggressive] [-TargetTz TZ]'),
    ('  ' + (' ' * $script:SCRIPT_NAME.Length) + ' [-TargetCountry CC] [-Only 小节...] [-Offline]'),
    ('  ' + (' ' * $script:SCRIPT_NAME.Length) + ' [-Force] [-NonInteractive] [-Elevate] [-AuditHome 路径]'),
    '',
    '默认行为:',
    '  执行检测，并在可安全自动处理的地方直接修复。',
    '  清理第三方 API 痕迹前会询问确认。',
    '  修改系统级设置时会申请管理员权限，未提权则提示并跳过。',
    '  修改用户文件或 hosts 前会先创建备份。',
    '',
    '常用参数:',
    '  -DryRun            预览修复，不修改系统或用户配置；仍生成本地报告。',
    '  -CheckOnly         只检测，不显示拟执行的修复动作。',
    '  -NoFix             等同于 -CheckOnly。',
    '  -Aggressive        中国大陆时区未指定目标时，使用 Taiwan Standard Time 作为迁移目标。',
    '  -TargetTz TZ       明确指定目标时区，支持 Windows 时区 ID 或 IANA 名称。',
    '  -TargetCountry CC  指定期望的出口国家，两位国家代码，例如 US、JP、SG。',
    '  -Only 小节         小节: os timezone system-proxy env shell-startup',
    '                            package-managers git claude-configs hosts dns',
    '                            exit-ip anthropic',
    '  -Offline           跳过公网 IP 和 Anthropic 端点联网检测。',
    '  -Force             自动确认第三方 API 痕迹清理。',
    '  -NonInteractive    跳过所有需要人工确认的清理。',
    '  -Elevate           需要管理员权限时自动以管理员身份重启本脚本。',
    '  -AuditHome 路径    指定用户主目录（默认 $env:USERPROFILE）。',
    '  -Version           显示版本号。',
    '  -Help              显示帮助。'
  )
  foreach ($line in $lines) { Write-Host $line }
}

if ($Help) { Write-Usage; exit 0 }
if ($Version) { Write-Host $script:ScriptVersion; exit 0 }

if (-not $script:IsWindowsHost) {
  Write-Host '[失败] 此脚本仅适用于 Windows。'
  exit 1
}

# ------------------------------------------------------------
# 运行模式与目标解析
# ------------------------------------------------------------
$script:DryRun = [bool]$DryRun
$script:Fix = $true
if ($CheckOnly -or $NoFix) { $script:Fix = $false }
if ($script:DryRun) { $script:Fix = $true }
$script:Offline = [bool]$Offline
$script:ForceCleanup = [bool]$Force
$script:NonInteractive = [bool]$NonInteractive -or (-not [Environment]::UserInteractive)
$script:Aggressive = [bool]$Aggressive

if ([string]::IsNullOrWhiteSpace($AuditHome)) {
  $script:HomeDir = $env:USERPROFILE
} else {
  $script:HomeDir = [System.IO.Path]::GetFullPath($AuditHome)
}
$script:BaseDir = Join-Path $script:HomeDir '.claude-win-env-audit'
$script:EventLogPath = ''
if (-not [string]::IsNullOrWhiteSpace($EventLog)) {
  $script:EventLogPath = [System.IO.Path]::GetFullPath($EventLog)
}

$script:ExpectedCountry = ''
if (-not [string]::IsNullOrWhiteSpace($TargetCountry)) {
  $script:ExpectedCountry = $TargetCountry.Trim().ToUpperInvariant()
  if ($script:ExpectedCountry -notmatch '^[A-Z]{2}$') {
    Write-Host '[错误] -TargetCountry 只接受两位国家代码，例如 US、JP、SG' -ForegroundColor Yellow
    exit 2
  }
}

$script:TargetTimeZone = ''
if (-not [string]::IsNullOrWhiteSpace($TargetTz)) {
  $script:TargetTimeZone = $TargetTz.Trim()
}

# Windows 时区 ID 与常用 IANA 名称的对应表。
# Windows 使用固定时区 ID，没有 IANA 数据库；这张表覆盖常见长期出口环境。
$script:TzIanaToWindows = @{
  'Asia/Shanghai'        = 'China Standard Time'
  'Asia/Urumqi'          = 'China Standard Time'
  'Asia/Hong_Kong'       = 'Hong Kong Standard Time'
  'Asia/Taipei'          = 'Taiwan Standard Time'
  'Asia/Tokyo'           = 'Tokyo Standard Time'
  'Asia/Seoul'           = 'Korea Standard Time'
  'Asia/Singapore'       = 'Singapore Standard Time'
  'Asia/Bangkok'         = 'SE Asia Standard Time'
  'Asia/Jakarta'         = 'SE Asia Standard Time'
  'Asia/Manila'          = 'Singapore Standard Time'
  'Asia/Kolkata'         = 'India Standard Time'
  'Asia/Dubai'           = 'Arabian Standard Time'
  'Europe/London'        = 'GMT Standard Time'
  'Europe/Dublin'        = 'GMT Standard Time'
  'Europe/Lisbon'        = 'GMT Standard Time'
  'Europe/Paris'         = 'Romance Standard Time'
  'Europe/Berlin'        = 'W. Europe Standard Time'
  'Europe/Amsterdam'     = 'W. Europe Standard Time'
  'Europe/Madrid'        = 'Romance Standard Time'
  'Europe/Rome'          = 'W. Europe Standard Time'
  'Europe/Zurich'        = 'W. Europe Standard Time'
  'Europe/Warsaw'        = 'Central European Standard Time'
  'Europe/Moscow'        = 'Russian Standard Time'
  'Europe/Istanbul'      = 'Turkey Standard Time'
  'America/New_York'     = 'Eastern Standard Time'
  'America/Toronto'      = 'Eastern Standard Time'
  'America/Chicago'      = 'Central Standard Time'
  'America/Denver'       = 'Mountain Standard Time'
  'America/Phoenix'      = 'US Mountain Standard Time'
  'America/Los_Angeles'  = 'Pacific Standard Time'
  'America/Vancouver'    = 'Pacific Standard Time'
  'America/Sao_Paulo'    = 'E. South America Standard Time'
  'Australia/Sydney'     = 'AUS Eastern Standard Time'
  'Australia/Melbourne'  = 'AUS Eastern Standard Time'
  'Australia/Perth'      = 'W. Australia Standard Time'
  'Pacific/Auckland'     = 'New Zealand Standard Time'
  'UTC'                  = 'UTC'
  'Etc/UTC'              = 'UTC'
}

$script:WindowsTimeZoneIds = $null

function Get-WindowsTimeZoneIds {
  if ($null -ne $script:WindowsTimeZoneIds) { return $script:WindowsTimeZoneIds }
  $ids = @()
  try {
    $ids = @(Get-TimeZone -ListAvailable -ErrorAction Stop | ForEach-Object { $_.Id })
  } catch {
    $ids = @()
  }
  $script:WindowsTimeZoneIds = $ids
  return $script:WindowsTimeZoneIds
}

function Resolve-TargetTimeZoneId {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

  $ids = Get-WindowsTimeZoneIds
  foreach ($id in $ids) {
    if ($id -ieq $Value.Trim()) { return $id }
  }
  foreach ($key in $script:TzIanaToWindows.Keys) {
    if ($key -ieq $Value.Trim()) { return $script:TzIanaToWindows[$key] }
  }
  return ''
}

if (-not [string]::IsNullOrWhiteSpace($script:TargetTimeZone)) {
  $resolved = Resolve-TargetTimeZoneId -Value $script:TargetTimeZone
  if ([string]::IsNullOrWhiteSpace($resolved)) {
    Write-Host ('[错误] 无效时区: ' + $script:TargetTimeZone + '。示例: Asia/Tokyo、Asia/Singapore、Europe/London 或 Tokyo Standard Time') -ForegroundColor Yellow
    exit 2
  }
  $script:TargetTimeZone = $resolved
}

$script:AllSections = @(
  'os', 'timezone', 'system-proxy', 'env', 'shell-startup', 'package-managers',
  'git', 'claude-configs', 'hosts', 'dns', 'exit-ip', 'anthropic'
)

$script:ActiveSections = @()
if ($Only.Count -gt 0) {
  foreach ($item in $Only) {
    foreach ($part in ($item -split ',')) {
      $name = $part.Trim().ToLowerInvariant()
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      if ($script:AllSections -notcontains $name) {
        Write-Host ('[错误] 未知小节: ' + $name + '。可用小节: ' + ($script:AllSections -join ', ')) -ForegroundColor Yellow
        exit 2
      }
      if ($script:ActiveSections -notcontains $name) { $script:ActiveSections += $name }
    }
  }
} else {
  $script:ActiveSections = @($script:AllSections)
}

$timestamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID
$script:BackupDir = Join-Path (Join-Path $script:BaseDir 'backups') $timestamp
$script:ReportDir = Join-Path $script:BaseDir 'reports'
$script:ReportFile = Join-Path $script:ReportDir ('report-' + $timestamp + '.log')
$script:ReportLines = New-Object 'System.Collections.Generic.List[string]'
$script:ReportDirWritable = $false
$script:BackupDirReady = $false
$script:CountOk = 0
$script:CountInfo = 0
$script:CountWarn = 0
$script:CountFixed = 0
$script:CountFail = 0
$script:ElevationNoticeShown = $false

# ------------------------------------------------------------
# 日志与计数
# ------------------------------------------------------------
function Write-AuditRaw {
  param([string]$Message = '')
  Write-Host $Message
  [void]$script:ReportLines.Add($Message)
}

function Write-AuditLog {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('正常', '信息', '警告', '已修复', '失败', '预览')][string]$Level,
    [Parameter(Mandatory = $true)][string]$Message
  )
  switch ($Level) {
    '正常' { $script:CountOk++ }
    '信息' { $script:CountInfo++ }
    '警告' { $script:CountWarn++ }
    '已修复' { $script:CountFixed++ }
    '失败' { $script:CountFail++ }
  }
  $line = '[' + $Level + '] ' + $Message
  Write-Host $line
  [void]$script:ReportLines.Add($line)
  Write-AuditEvent @{ type = 'finding'; level = $Level; message = $Message }
}

function Write-AuditEvent {
  param([hashtable]$Event)
  if (-not $script:EventLogPath) { return }
  try {
    $json = $Event | ConvertTo-Json -Compress -Depth 4
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($script:EventLogPath, $json + "`n", $encoding)
  } catch {
    # 事件流写入失败不应影响审计本身
  }
}

function Get-SectionDisplayName {
  param([string]$Section)
  switch ($Section) {
    'os' { return '系统' }
    'timezone' { return '时区' }
    'system-proxy' { return '系统代理' }
    'env' { return '环境变量' }
    'shell-startup' { return 'Shell 启动文件' }
    'package-managers' { return 'Node 包管理器代理配置' }
    'git' { return 'Git 代理配置' }
    'claude-configs' { return 'Claude / Router 配置文件' }
    'hosts' { return 'hosts 文件' }
    'dns' { return 'DNS' }
    'exit-ip' { return '出口 IP' }
    'anthropic' { return 'Anthropic 端点连通性' }
    default { return $Section }
  }
}

function Write-SectionTitle {
  param([string]$Title)
  Write-AuditRaw ('== ' + $Title + ' ==')
}

# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------
function Test-CommandAvailable {
  param([string]$Name)
  return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Test-Elevated {
  try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

function Read-TextFileContent {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $hasBom = $false
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $hasBom = $true
  }
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  return [pscustomobject]@{ Text = $text; Utf8Bom = $hasBom }
}

function Write-TextFileContent {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Text,
    [bool]$Utf8Bom = $false
  )
  $encoding = New-Object System.Text.UTF8Encoding($Utf8Bom)
  [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Restrict-PathAcl {
  param([string]$Path, [switch]$Directory)
  try {
    $user = $env:USERDOMAIN + '\' + $env:USERNAME
    if ($Directory) {
      & icacls.exe $Path '/inheritance:r' '/grant:r' ($user + ':(OI)(CI)F') /T 2>$null | Out-Null
    } else {
      & icacls.exe $Path '/inheritance:r' '/grant:r' ($user + ':F') 2>$null | Out-Null
    }
  } catch {
    # 权限收紧失败不影响主流程
  }
}

function Get-ShortPathHash {
  param([string]$Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    return (-join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') }))
  } finally {
    $sha.Dispose()
  }
}

function Backup-AuditFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  # 备份名用短哈希 + 文件名，避免深层目录触发 Windows MAX_PATH 限制
  $leaf = Split-Path -Leaf $Path
  $safeLeaf = $leaf -replace '[\\/:*?"<>| ]', '_'
  if ($safeLeaf.Length -gt 60) { $safeLeaf = $safeLeaf.Substring(0, 60) }
  $safe = (Get-ShortPathHash -Value $Path) + '-' + $safeLeaf
  $dest = Join-Path $script:BackupDir $safe
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将备份 ' + $Path + ' -> ' + $dest)
    return $true
  }
  try {
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    Restrict-PathAcl -Path $dest
    return $true
  } catch {
    return $false
  }
}

function Backup-RegistryKey {
  param([string]$KeyPath)
  $safe = $KeyPath -replace '[\\/:*?"<>| ]', '_'
  $dest = Join-Path $script:BackupDir ('reg_' + $safe + '.reg')
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将备份注册表 ' + $KeyPath + ' -> ' + $dest)
    return $true
  }
  try {
    $parent = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    & reg.exe export $KeyPath $dest /y | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    Restrict-PathAcl -Path $dest
    return $true
  } catch {
    return $false
  }
}

function Invoke-RootAction {
  param([string]$Reason, [scriptblock]$Action)
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将以管理员权限执行: ' + $Reason)
    return $true
  }
  if (-not (Test-Elevated)) {
    if (-not $script:ElevationNoticeShown) {
      Write-AuditLog -Level '警告' -Message '需要管理员权限，系统级修复已跳过。请以管理员身份重新打开 PowerShell，或加 -Elevate 重新运行。'
      $script:ElevationNoticeShown = $true
    }
    Write-AuditLog -Level '警告' -Message ('已跳过（权限不足）: ' + $Reason)
    return $false
  }
  try {
    & $Action
    return $true
  } catch {
    Write-AuditLog -Level '失败' -Message ('执行失败: ' + $Reason + ' : ' + $_.Exception.Message)
    return $false
  }
}

function Send-EnvironmentChange {
  try {
    if (-not ('Win32.EnvBroadcast' -as [type])) {
      Add-Type -Namespace Win32 -Name EnvBroadcast -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $result = [UIntPtr]::Zero
    [void][Win32.EnvBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
  } catch {
    # 广播失败只影响已打开的窗口是否需要重启
  }
}

# ------------------------------------------------------------
# 第三方 API 痕迹确认门
# ------------------------------------------------------------
function Confirm-ThirdPartyCleanup {
  param([string]$Target)
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('实际修复前会询问是否清除第三方 API 痕迹: ' + $Target)
    return $true
  }
  if ($script:ForceCleanup) {
    Write-AuditLog -Level '信息' -Message ('已通过 -Force 确认清理第三方 API 痕迹: ' + $Target)
    return $true
  }
  if ($script:NonInteractive) {
    Write-AuditLog -Level '警告' -Message ('检测到第三方 API 痕迹，但当前不可交互，已跳过清理: ' + $Target)
    return $false
  }
  $answer = ''
  try {
    $answer = Read-Host ('是否清除 ' + $Target + ' 中的第三方 API 痕迹？输入 y 确认，其他输入跳过')
  } catch {
    Write-AuditLog -Level '警告' -Message ('无法读取确认输入，已跳过清理第三方 API 痕迹: ' + $Target)
    return $false
  }
  if ($answer -match '^(y|yes|是|确认)$') {
    Write-AuditLog -Level '信息' -Message ('已确认清理第三方 API 痕迹: ' + $Target)
    return $true
  }
  Write-AuditLog -Level '信息' -Message ('已跳过清理第三方 API 痕迹: ' + $Target)
  return $false
}

# ------------------------------------------------------------
# 常量与匹配模式
# ------------------------------------------------------------
$script:EnvNames = @(
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'ANTHROPIC_BASE_URL', 'ANTHROPIC_API_URL',
  'ANTHROPIC_PROXY', 'CLAUDE_BASE_URL', 'CLAUDE_API_BASE', 'CLAUDE_CODE_ROUTER', 'OPENAI_BASE_URL'
)
$script:ThirdPartyEnvNames = @(
  'ANTHROPIC_BASE_URL', 'ANTHROPIC_API_URL', 'CLAUDE_BASE_URL', 'CLAUDE_API_BASE',
  'CLAUDE_CODE_ROUTER', 'OPENAI_BASE_URL'
)
$script:SuspiciousLinePattern = '(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|http_proxy|https_proxy|all_proxy|ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|ANTHROPIC_PROXY|CLAUDE_.*BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|npm\s+config\s+set\s+.*proxy|yarn\s+config\s+set\s+.*proxy|pnpm\s+config\s+set\s+.*proxy|git\s+config\s+.*http.*proxy)'
$script:ThirdPartyTracePattern = '(ANTHROPIC_BASE_URL|ANTHROPIC_API_URL|CLAUDE_.*BASE|CLAUDE_API_BASE|CLAUDE_CODE_ROUTER|OPENAI_BASE_URL|base[_-]?url|baseUrl|api[_-]?base)'
$script:JsonKeyPattern = '^(proxy|https?_proxy|all_proxy|anthropic_proxy|base[_-]?url|baseUrl|api[_-]?base(?:[_-]?url)?|apiBase(?:Url)?|ANTHROPIC_(?:BASE|API)_URL|CLAUDE_(?:BASE_URL|API_BASE|CODE_ROUTER)|OPENAI_BASE_URL)$'
$script:ChinaDnsList = @('114.114.114.114', '223.5.5.5', '223.6.6.6', '119.29.29.29', '180.76.76.76')
$script:ChinaCloudPattern = '(aliyun|alibaba|tencent|qcloud|huawei|volc|bytedance|baidu|chinanet|cn2|ctyun|ucloud|chinamobile|chinaunicom|chinatelecom)'

# ------------------------------------------------------------
# 初始化：报告与备份目录
# ------------------------------------------------------------
function Initialize-AuditContext {
  $dirs = @($script:ReportDir, $script:BackupDir)
  foreach ($dir in $dirs) {
    try {
      if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
      }
    } catch {
      Write-Host ('[警告] 无法创建目录: ' + $dir + ' : ' + $_.Exception.Message)
    }
  }
  Restrict-PathAcl -Path $script:BaseDir -Directory

  if ($script:EventLogPath) {
    try {
      $eventParent = Split-Path -Parent $script:EventLogPath
      if ($eventParent -and -not (Test-Path -LiteralPath $eventParent)) {
        New-Item -ItemType Directory -Path $eventParent -Force -ErrorAction Stop | Out-Null
      }
      [System.IO.File]::WriteAllText($script:EventLogPath, '', (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      $script:EventLogPath = ''
    }
  }

  $script:BackupDirReady = Test-Path -LiteralPath $script:BackupDir

  # 探测报告目录是否可写，用于在总结里如实说明报告状态
  $script:ReportDirWritable = $false
  try {
    $probe = Join-Path $script:ReportDir ('.probe-' + $PID)
    [System.IO.File]::WriteAllText($probe, 'ok')
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    $script:ReportDirWritable = $true
  } catch {
    $script:ReportDirWritable = $false
  }
}

function Try-RelaunchElevated {
  if (-not $Elevate) { return $false }
  if ($script:DryRun -or -not $script:Fix) { return $false }
  if (Test-Elevated) { return $false }

  $exe = (Get-Process -Id $PID).Path
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($AuditHome) { $argList += @('-AuditHome', $AuditHome) }
  if ($script:Aggressive) { $argList += '-Aggressive' }
  if ($script:TargetTimeZone) { $argList += @('-TargetTz', $script:TargetTimeZone) }
  if ($script:ExpectedCountry) { $argList += @('-TargetCountry', $script:ExpectedCountry) }
  if ($Only.Count -gt 0) { $argList += @('-Only', ($Only -join ',')) }
  if ($script:Offline) { $argList += '-Offline' }
  if ($script:ForceCleanup) { $argList += '-Force' }
  if ($script:NonInteractive) { $argList += '-NonInteractive' }

  Write-Host '需要管理员权限，正在以管理员身份重新启动本脚本...'
  try {
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
  } catch {
    Write-Host ('[警告] 提权启动失败: ' + $_.Exception.Message)
    return $false
  }
  return $true
}

function Write-Header {
  Write-AuditRaw ('Claude Code Windows 环境检测 v' + $script:ScriptVersion)
  Write-AuditRaw ('报告: ' + $script:ReportFile)
  Write-AuditRaw ('备份: ' + $script:BackupDir)
  if ($script:DryRun) {
    Write-AuditRaw '模式: 仅预览，不修改系统或用户配置（仍会生成本地报告）'
  } elseif ($script:Fix) {
    Write-AuditRaw '模式: 自动修复；需要管理员权限时会提示（可加 -Elevate），清理第三方 API 痕迹前会询问'
  } else {
    Write-AuditRaw '模式: 只检测'
  }
  $modeText = if ($script:DryRun) { 'dry-run' } elseif ($script:Fix) { 'fix' } else { 'check-only' }
  Write-AuditEvent @{ type = 'meta'; version = $script:ScriptVersion; mode = $modeText; sections = @($script:ActiveSections); total = $script:ActiveSections.Count; offline = [bool]$script:Offline; elevated = (Test-Elevated) }

  if (-not (Test-Elevated)) {
    Write-AuditRaw '权限: 当前未以管理员身份运行，系统级修复将被跳过'
  } else {
    Write-AuditRaw '权限: 当前已具备管理员权限'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 系统
# ------------------------------------------------------------
function Get-OsInfo {
  $info = [pscustomobject]@{
    Caption = 'Windows'
    Version = '未知'
    Build   = '未知'
  }
  try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $info.Caption = $os.Caption
    $info.Version = $os.Version
    $info.Build = [string]$os.BuildNumber
  } catch {
    try {
      $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
      $info.Caption = [string]$cv.ProductName
      $info.Version = [string]$cv.CurrentVersion
      $info.Build = [string]$cv.CurrentBuild
    } catch {
      # 保留默认值
    }
  }
  return $info
}

function Invoke-AuditOs {
  Write-SectionTitle '系统'
  $osInfo = Get-OsInfo
  $arch = $env:PROCESSOR_ARCHITECTURE
  Write-AuditLog -Level '正常' -Message ($osInfo.Caption + ' ' + $osInfo.Version + ' (Build ' + $osInfo.Build + ')，架构=' + $arch)

  if (Test-CommandAvailable -Name 'claude') {
    $claudePath = (Get-Command -Name 'claude' -ErrorAction SilentlyContinue).Source
    $claudeVersion = ''
    try {
      $claudeVersion = (& claude --version 2>$null | Select-Object -First 1)
    } catch {
      $claudeVersion = ''
    }
    if ($claudeVersion) {
      Write-AuditLog -Level '正常' -Message ('claude 命令: ' + $claudePath + ' (' + $claudeVersion + ')')
    } else {
      Write-AuditLog -Level '正常' -Message ('claude 命令: ' + $claudePath)
    }
  } else {
    Write-AuditLog -Level '信息' -Message 'PATH 中未找到 claude 命令（不影响其他检查项；只用于显示 CLI 版本）。'
  }

  if (Test-CommandAvailable -Name 'node') {
    $nodePath = (Get-Command -Name 'node' -ErrorAction SilentlyContinue).Source
    $nodeVersion = ''
    try { $nodeVersion = (& node --version 2>$null | Select-Object -First 1) } catch { $nodeVersion = '' }
    Write-AuditLog -Level '正常' -Message ('node: ' + $nodePath + ' (' + $nodeVersion + ')')
  } else {
    Write-AuditLog -Level '信息' -Message '未找到 node，时区检测将只使用 Windows 系统信息。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 时区
# ------------------------------------------------------------
function Get-CurrentTimeZoneId {
  try {
    $tz = Get-TimeZone -ErrorAction Stop
    if ($tz) { return [string]$tz.Id }
  } catch {
    # 继续尝试 tzutil
  }
  try {
    $value = & tzutil.exe /g 2>$null
    if ($value) { return ([string]$value).Trim() }
  } catch {
    # 放弃
  }
  return ''
}

function Get-NodeTimeZone {
  if (-not (Test-CommandAvailable -Name 'node')) { return '' }
  try {
    $value = & node -e "try { console.log(Intl.DateTimeFormat().resolvedOptions().timeZone || '') } catch (_) { process.exit(1) }" 2>$null
    if ($value) { return ([string]$value).Trim() }
  } catch {
    return ''
  }
  return ''
}

function Get-AutoTimeZoneServiceState {
  try {
    $svc = Get-Service -Name 'tzautoupdate' -ErrorAction Stop
    return [string]$svc.StartType
  } catch {
    return '未知'
  }
}

function Invoke-AuditTimezone {
  Write-SectionTitle '时区'

  $sysTz = Get-CurrentTimeZoneId
  $nodeTz = Get-NodeTimeZone
  $autoState = Get-AutoTimeZoneServiceState

  if ($sysTz) {
    Write-AuditLog -Level '信息' -Message ('系统时区: ' + $sysTz)
  } else {
    Write-AuditLog -Level '警告' -Message '无法读取系统时区。'
  }
  if ($nodeTz) {
    Write-AuditLog -Level '信息' -Message ('node Intl 时区: ' + $nodeTz)
  }

  $effectiveTarget = $script:TargetTimeZone
  if (-not $effectiveTarget -and $script:Aggressive -and $sysTz -eq 'China Standard Time') {
    $effectiveTarget = 'Taiwan Standard Time'
    Write-AuditLog -Level '信息' -Message ('-Aggressive 已为中国大陆时区选择迁移目标: ' + $effectiveTarget)
  }

  $shouldFix = $false
  if ($effectiveTarget) {
    if ($sysTz -eq $effectiveTarget) {
      Write-AuditLog -Level '正常' -Message ('时区已经符合目标: ' + $effectiveTarget)
    } elseif (-not $sysTz) {
      Write-AuditLog -Level '警告' -Message ('无法读取系统时区，不能判断是否匹配目标 ' + $effectiveTarget + '。')
    } else {
      Write-AuditLog -Level '警告' -Message ('系统时区 ' + $sysTz + ' 与明确指定的目标 ' + $effectiveTarget + ' 不一致。')
      $shouldFix = $true
    }
  } else {
    switch ($sysTz) {
      'China Standard Time' {
        Write-AuditLog -Level '警告' -Message '当前是中国大陆时区。脚本不会猜测目标国家；请用 -TargetTz 明确指定与你出口环境一致的时区。'
      }
      '' {
        Write-AuditLog -Level '警告' -Message '无法读取系统时区。'
      }
      default {
        Write-AuditLog -Level '正常' -Message ('当前时区为 ' + $sysTz + '；未指定目标时区，保持不变。')
      }
    }
  }

  if ($shouldFix -and $script:Fix) {
    if ($script:DryRun) {
      Write-AuditLog -Level '预览' -Message ('将以管理员权限把系统时区设置为 ' + $effectiveTarget)
    } else {
      $targetId = $effectiveTarget
      $ok = Invoke-RootAction -Reason ('设置系统时区为 ' + $targetId) -Action {
        Set-TimeZone -Id $targetId -ErrorAction Stop
      }
      if ($ok) {
        $after = Get-CurrentTimeZoneId
        if ($after -eq $targetId) {
          Write-AuditLog -Level '已修复' -Message ('已将时区设置为 ' + $targetId + '。')
        } else {
          Write-AuditLog -Level '失败' -Message ('已尝试设置时区，但当前仍为 ' + $after + '。')
        }
      } else {
        Write-AuditLog -Level '失败' -Message '无法设置时区，可能是管理员权限不足或 Set-TimeZone 执行失败。'
      }
    }
  }

  if ($sysTz -and $autoState -ne 'Disabled' -and $effectiveTarget) {
    Write-AuditLog -Level '信息' -Message ('系统时区自动同步服务 tzautoupdate 状态: ' + $autoState + '；修改时区后可能被系统自动改回。')
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 系统代理（WinINET + WinHTTP）
# ------------------------------------------------------------
$script:ProxyRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Get-WinInetProxyState {
  $state = [pscustomobject]@{
    ProxyEnable  = 0
    ProxyServer  = ''
    AutoConfigUrl = ''
    ProxyOverride = ''
    Exists       = $false
  }
  if (-not (Test-Path -LiteralPath $script:ProxyRegPath)) { return $state }
  try {
    $props = Get-ItemProperty -Path $script:ProxyRegPath -ErrorAction Stop
    $state.Exists = $true
    if ($null -ne $props.ProxyEnable) { $state.ProxyEnable = [int]$props.ProxyEnable }
    if ($null -ne $props.ProxyServer) { $state.ProxyServer = [string]$props.ProxyServer }
    if ($null -ne $props.AutoConfigURL) { $state.AutoConfigUrl = [string]$props.AutoConfigURL }
    if ($null -ne $props.ProxyOverride) { $state.ProxyOverride = [string]$props.ProxyOverride }
  } catch {
    # 读不到就按默认关闭处理
  }
  return $state
}

function Get-WinHttpProxyState {
  $result = [pscustomobject]@{ HasProxy = $false; Text = '' }
  try {
    $output = & netsh.exe winhttp show proxy 2>$null
    $text = ($output | Out-String)
    $result.Text = $text.Trim()
    if ($text -match 'Proxy Server\(s\)\s*:\s*(\S+)') { $result.HasProxy = $true }
  } catch {
    # 忽略
  }
  return $result
}

function Get-TunnelAdapters {
  $names = @()
  try {
    $adapters = Get-NetAdapter -ErrorAction Stop | Where-Object { [string]$_.Status -eq 'Up' }
    foreach ($adapter in $adapters) {
      $desc = [string]$adapter.InterfaceDescription
      if ($desc -match '(?i)(TAP|TUN|Wintun|WireGuard|Tailscale|ZeroTier|Clash|Mihomo|V2Ray|sing-box|SoftEther|OpenVPN|Netch|Surge|Shadowrocket)') {
        $names += ([string]$adapter.Name + '(' + $desc + ')')
      }
    }
  } catch {
    # 旧系统或受限环境
  }
  return $names
}

function Invoke-AuditSystemProxy {
  Write-SectionTitle '系统代理'

  $state = Get-WinInetProxyState
  $enabled = ($state.ProxyEnable -eq 1) -or (-not [string]::IsNullOrWhiteSpace($state.AutoConfigUrl))
  $winhttp = Get-WinHttpProxyState

  if (-not $enabled -and -not $winhttp.HasProxy) {
    Write-AuditLog -Level '正常' -Message 'Windows 系统代理（WinINET/WinHTTP）均处于关闭状态。'
  } else {
    if ($enabled) {
      Write-AuditLog -Level '警告' -Message ('Windows 系统代理（WinINET）已启用: ProxyEnable=' + $state.ProxyEnable + '，PAC=' + [bool](-not [string]::IsNullOrWhiteSpace($state.AutoConfigUrl)) + '（地址值已隐藏）')
    }
    if ($winhttp.HasProxy) {
      Write-AuditLog -Level '警告' -Message 'WinHTTP 代理已设置（值已隐藏）。'
    }

    if ($script:Fix) {
      if ($script:DryRun) {
        Write-AuditLog -Level '预览' -Message '将关闭 WinINET 系统代理并清除 PAC 自动配置地址'
        if ($winhttp.HasProxy) {
          Write-AuditLog -Level '预览' -Message '将以管理员权限执行 netsh winhttp reset proxy'
        }
      } else {
        if ($state.Exists) {
          if (-not (Backup-RegistryKey -KeyPath 'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings')) {
            Write-AuditLog -Level '失败' -Message '无法备份 Internet Settings 注册表项，已取消关闭系统代理。'
          } else {
            try {
              Set-ItemProperty -Path $script:ProxyRegPath -Name 'ProxyEnable' -Value 0 -Type DWord
              if (-not [string]::IsNullOrWhiteSpace($state.AutoConfigUrl)) {
                Remove-ItemProperty -Path $script:ProxyRegPath -Name 'AutoConfigURL' -Force
              }
              Send-EnvironmentChange
              $after = Get-WinInetProxyState
              if ($after.ProxyEnable -eq 0 -and [string]::IsNullOrWhiteSpace($after.AutoConfigUrl)) {
                Write-AuditLog -Level '已修复' -Message '已关闭 WinINET 系统代理并清除 PAC 自动配置地址。'
              } else {
                Write-AuditLog -Level '失败' -Message '已尝试关闭系统代理，但仍残留部分设置。'
              }
            } catch {
              Write-AuditLog -Level '失败' -Message ('无法关闭系统代理: ' + $_.Exception.Message)
            }
          }
        }

        if ($winhttp.HasProxy) {
          $ok = Invoke-RootAction -Reason '执行 netsh winhttp reset proxy' -Action {
            & netsh.exe winhttp reset proxy | Out-Null
          }
          if ($ok) {
            $winhttpAfter = Get-WinHttpProxyState
            if ($winhttpAfter.HasProxy) {
              Write-AuditLog -Level '失败' -Message '已尝试重置 WinHTTP 代理，但仍检测到代理设置。'
            } else {
              Write-AuditLog -Level '已修复' -Message '已重置 WinHTTP 代理。'
            }
          }
        }
      }
    }
  }

  $tunnels = Get-TunnelAdapters
  if ($tunnels.Count -gt 0) {
    Write-AuditLog -Level '信息' -Message ('检测到虚拟网卡: ' + ($tunnels -join ', ') + '。网卡存在只说明系统有隧道设备，不代表当前流量一定经过它。')
  } else {
    Write-AuditLog -Level '警告' -Message '当前未检测到正在运行的 TUN/VPN 虚拟网卡。如果你依赖代理客户端，建议使用 TUN/VPN 模式，而不是系统代理模式。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 环境变量（进程 / 用户 / 机器）
# ------------------------------------------------------------
function Get-ScopedEnvNames {
  param([ValidateSet('Process', 'User', 'Machine')][string]$Scope)
  $found = @()
  if ($Scope -eq 'Process') {
    $all = [Environment]::GetEnvironmentVariables('Process')
    foreach ($key in $all.Keys) { $found += [string]$key }
    return $found
  }

  $path = ''
  if ($Scope -eq 'User') { $path = 'HKCU:\Environment' }
  else { $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }

  if (-not (Test-Path -LiteralPath $path)) { return $found }
  try {
    $props = Get-ItemProperty -Path $path -ErrorAction Stop
    foreach ($prop in $props.PSObject.Properties) {
      if ($prop.Name -like 'PS*') { continue }
      $found += [string]$prop.Name
    }
  } catch {
    # 忽略
  }
  return $found
}

function Get-EnvValueSafe {
  param(
    [ValidateSet('Process', 'User', 'Machine')][string]$Scope,
    [string]$Name
  )
  try {
    return [Environment]::GetEnvironmentVariable($Name, $Scope)
  } catch {
    return $null
  }
}

function Invoke-AuditEnv {
  Write-SectionTitle '环境变量'
  $foundAny = $false
  $wanted = @($script:EnvNames | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)

  # 当前进程
  $processFound = @()
  foreach ($name in (Get-ScopedEnvNames -Scope 'Process')) {
    if ($wanted -contains $name.ToUpperInvariant()) { $processFound += $name }
  }
  if ($processFound.Count -gt 0) {
    $foundAny = $true
    Write-AuditLog -Level '警告' -Message ('当前进程包含相关环境变量（值已隐藏）: ' + ($processFound -join ', ') + '。脚本无法修改父级 shell 的变量。')
  } else {
    Write-AuditLog -Level '正常' -Message '当前进程未发现代理或基础 URL 环境变量。'
  }

  # 用户级
  $userPath = 'HKCU:\Environment'
  $userFound = @()
  foreach ($name in (Get-ScopedEnvNames -Scope 'User')) {
    if ($wanted -contains $name.ToUpperInvariant()) { $userFound += $name }
  }
  if ($userFound.Count -gt 0) {
    $foundAny = $true
    foreach ($name in $userFound) {
      Write-AuditLog -Level '警告' -Message ('用户环境变量 ' + $name + ' 已设置（值已隐藏）')
      if (-not $script:Fix) { continue }
      if ($script:ThirdPartyEnvNames -contains $name) {
        if (-not (Confirm-ThirdPartyCleanup -Target ('用户环境变量 ' + $name))) { continue }
      }
      if ($script:DryRun) {
        Write-AuditLog -Level '预览' -Message ('将删除用户环境变量 ' + $name)
        continue
      }
      if (-not (Backup-RegistryKey -KeyPath 'HKCU\Environment')) {
        Write-AuditLog -Level '失败' -Message ('无法备份 HKCU\Environment，已取消删除 ' + $name + '。')
        continue
      }
      try {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        Send-EnvironmentChange
        if ($null -eq (Get-EnvValueSafe -Scope 'User' -Name $name)) {
          Write-AuditLog -Level '已修复' -Message ('已删除用户环境变量 ' + $name + '。')
        } else {
          Write-AuditLog -Level '失败' -Message ('无法删除用户环境变量 ' + $name + '。')
        }
      } catch {
        Write-AuditLog -Level '失败' -Message ('无法删除用户环境变量 ' + $name + ': ' + $_.Exception.Message)
      }
    }
  } else {
    Write-AuditLog -Level '正常' -Message '用户环境变量中未发现代理或基础 URL 变量。'
  }

  # 机器级
  $machineFound = @()
  foreach ($name in (Get-ScopedEnvNames -Scope 'Machine')) {
    if ($wanted -contains $name.ToUpperInvariant()) { $machineFound += $name }
  }
  if ($machineFound.Count -gt 0) {
    $foundAny = $true
    foreach ($name in $machineFound) {
      Write-AuditLog -Level '警告' -Message ('机器级环境变量 ' + $name + ' 已设置（值已隐藏）')
      if (-not $script:Fix) { continue }
      if ($script:ThirdPartyEnvNames -contains $name) {
        if (-not (Confirm-ThirdPartyCleanup -Target ('机器级环境变量 ' + $name))) { continue }
      }
      if ($script:DryRun) {
        Write-AuditLog -Level '预览' -Message ('将以管理员权限删除机器级环境变量 ' + $name)
        continue
      }
      $varName = $name
      $ok = Invoke-RootAction -Reason ('删除机器级环境变量 ' + $varName) -Action {
        [Environment]::SetEnvironmentVariable($varName, $null, 'Machine')
      }
      if ($ok) {
        if ($null -eq (Get-EnvValueSafe -Scope 'Machine' -Name $varName)) {
          Write-AuditLog -Level '已修复' -Message ('已删除机器级环境变量 ' + $varName + '。')
        } else {
          Write-AuditLog -Level '失败' -Message ('无法删除机器级环境变量 ' + $varName + '。')
        }
      }
    }
  }

  # NO_PROXY 不是代理入口，脚本不会删除
  $noProxy = Get-EnvValueSafe -Scope 'User' -Name 'NO_PROXY'
  if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = Get-EnvValueSafe -Scope 'Process' -Name 'NO_PROXY' }
  if ([string]::IsNullOrWhiteSpace($noProxy)) { $noProxy = Get-EnvValueSafe -Scope 'Machine' -Name 'NO_PROXY' }
  if (-not [string]::IsNullOrWhiteSpace($noProxy)) {
    Write-AuditLog -Level '信息' -Message 'NO_PROXY / no_proxy 已设置。它不是代理入口，脚本不会自动删除。'
  }

  if (-not $foundAny) {
    Write-AuditLog -Level '正常' -Message '未发现代理或基础 URL 环境变量残留。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# Shell / PowerShell 启动文件
# ------------------------------------------------------------
function Get-StartupFileCandidates {
  $files = @()
  $docs = Join-Path $script:HomeDir 'Documents'
  $files += (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')
  $files += (Join-Path $docs 'WindowsPowerShell\profile.ps1')
  $files += (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
  $files += (Join-Path $docs 'PowerShell\profile.ps1')
  $files += (Join-Path $script:HomeDir '.config\powershell\profile.ps1')
  $files += (Join-Path $script:HomeDir '.bashrc')
  $files += (Join-Path $script:HomeDir '.zshrc')
  return $files
}

function Get-MatchingLineNumbers {
  param([string]$Text, [string]$Pattern)
  $lines = $Text -split "`r?`n"
  $hits = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*#') { continue }
    if ($lines[$i] -match $Pattern) { $hits += ($i + 1) }
  }
  return $hits
}

function Update-SuspiciousFileLines {
  param([string]$Path, [string]$Pattern, [string]$Target)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

  $raw = Read-TextFileContent -Path $Path
  $text = $raw.Text
  $hits = @(Get-MatchingLineNumbers -Text $text -Pattern $Pattern)
  if ($hits.Count -eq 0) { return $false }

  $lineNumbers = ($hits -join ',')
  Write-AuditLog -Level '警告' -Message ('在 ' + $Path + ' 中发现可疑的代理或基础 URL 配置，行号: ' + $lineNumbers + '（内容已隐藏）')

  if (-not $script:Fix) { return $true }

  if ($text -match $script:ThirdPartyTracePattern) {
    if (-not (Confirm-ThirdPartyCleanup -Target $Target)) { return $true }
  }

  if (-not (Backup-AuditFile -Path $Path)) {
    Write-AuditLog -Level '失败' -Message ('无法备份 ' + $Path + '，已取消修改。')
    return $true
  }
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将注释 ' + $Path + ' 中的可疑配置行')
    return $true
  }

  $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $lines = $text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*#') { continue }
    if ($lines[$i] -match $Pattern) {
      $lines[$i] = '# claude-win-env-audit 已禁用: ' + $lines[$i]
    }
  }
  try {
    Write-TextFileContent -Path $Path -Text ($lines -join $newline) -Utf8Bom $raw.Utf8Bom
    Write-AuditLog -Level '已修复' -Message ('已注释 ' + $Path + ' 中的可疑配置行。')
  } catch {
    Write-AuditLog -Level '失败' -Message ('无法修改 ' + $Path + '；原文件备份已保留。')
  }
  return $true
}

function Invoke-AuditShellStartup {
  Write-SectionTitle 'Shell 启动文件'
  $foundAny = $false
  $touched = 0
  foreach ($file in (Get-StartupFileCandidates)) {
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $touched++
      if (Update-SuspiciousFileLines -Path $file -Pattern $script:SuspiciousLinePattern -Target $file) {
        $foundAny = $true
      }
    }
  }

  # cmd.exe AutoRun
  $autorunKeys = @(
    'HKCU:\Software\Microsoft\Command Processor',
    'HKLM:\SOFTWARE\Microsoft\Command Processor'
  )
  foreach ($key in $autorunKeys) {
    if (-not (Test-Path -LiteralPath $key)) { continue }
    try {
      $props = Get-ItemProperty -Path $key -ErrorAction Stop
      $autorun = [string]$props.Autorun
    } catch {
      $autorun = ''
    }
    if ([string]::IsNullOrWhiteSpace($autorun)) { continue }
    if ($autorun -notmatch $script:SuspiciousLinePattern) { continue }
    $touched++
    $foundAny = $true
    Write-AuditLog -Level '警告' -Message ('cmd.exe AutoRun 中存在可疑配置: ' + $key + '（内容已隐藏）')
    if (-not $script:Fix) { continue }
    if ($autorun -match $script:ThirdPartyTracePattern) {
      if (-not (Confirm-ThirdPartyCleanup -Target ('cmd AutoRun ' + $key))) { continue }
    }
    if ($script:DryRun) {
      Write-AuditLog -Level '预览' -Message ('将清除 ' + $key + ' 的 Autorun 值')
      continue
    }
    if (-not (Backup-RegistryKey -KeyPath ($key -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'))) {
      Write-AuditLog -Level '失败' -Message ('无法备份 ' + $key + '，已取消修改。')
      continue
    }
    try {
      Remove-ItemProperty -Path $key -Name 'Autorun' -Force
      Write-AuditLog -Level '已修复' -Message ('已清除 ' + $key + ' 的 AutoRun 值。')
    } catch {
      Write-AuditLog -Level '失败' -Message ('无法清除 ' + $key + ' 的 AutoRun 值: ' + $_.Exception.Message)
    }
  }

  if (Test-CommandAvailable -Name 'wsl') {
    Write-AuditLog -Level '信息' -Message '检测到 WSL。WSL 内部的 .bashrc / .zshrc 与代理变量不在本脚本范围内，需要时请在 WSL 内单独检查。'
  }

  if ($touched -eq 0) {
    Write-AuditLog -Level '信息' -Message '未找到常见 PowerShell / shell 启动文件。'
  } elseif (-not $foundAny) {
    Write-AuditLog -Level '正常' -Message '已检查常见启动文件，未发现代理或基础 URL 配置。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# Node 包管理器代理
# ------------------------------------------------------------
function Get-PackageManagerConfigValue {
  param([string]$Command, [string]$Key)
  try {
    $value = & $Command config get $Key 2>$null
    if ($null -eq $value) { return '' }
    $text = ([string]($value | Select-Object -Last 1)).Trim()
    return $text
  } catch {
    return ''
  }
}

function Remove-PackageManagerProxy {
  param([string]$Command, [string]$Key)
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将删除 ' + $Command + ' 配置 ' + $Key)
    return
  }
  try {
    & $Command config delete $Key 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-AuditLog -Level '已修复' -Message ('已删除 ' + $Command + ' 配置 ' + $Key + '。')
    } else {
      Write-AuditLog -Level '失败' -Message ('无法删除 ' + $Command + ' 配置 ' + $Key + '。')
    }
  } catch {
    Write-AuditLog -Level '失败' -Message ('无法删除 ' + $Command + ' 配置 ' + $Key + '。')
  }
}

function Invoke-AuditPackageManagers {
  Write-SectionTitle 'Node 包管理器代理配置'
  $saw = $false

  foreach ($command in @('npm', 'yarn', 'pnpm')) {
    if (-not (Test-CommandAvailable -Name $command)) {
      if ($command -eq 'npm') { Write-AuditLog -Level '信息' -Message '未找到 npm。' }
      continue
    }
    foreach ($key in @('proxy', 'https-proxy')) {
      $value = Get-PackageManagerConfigValue -Command $command -Key $key
      if ([string]::IsNullOrWhiteSpace($value)) { continue }
      if ($value -eq 'null' -or $value -eq 'undefined') { continue }
      $saw = $true
      Write-AuditLog -Level '警告' -Message ($command + ' ' + $key + ' 已设置（值已隐藏）')
      if ($script:Fix) { Remove-PackageManagerProxy -Command $command -Key $key }
    }
  }

  # 配置文件里的代理行
  $profileFiles = @(
    (Join-Path $script:HomeDir '.npmrc'),
    (Join-Path $script:HomeDir '.yarnrc'),
    (Join-Path $script:HomeDir '.yarnrc.yml'),
    (Join-Path $env:APPDATA 'npm\etc\npmrc')
  )
  foreach ($file in $profileFiles) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
    $raw = Read-TextFileContent -Path $file
    $pattern = '(^|[\s:"-])(proxy|https-proxy|http-proxy|httpProxy|httpsProxy)\s*[:=]'
    $hits = @(Get-MatchingLineNumbers -Text $raw.Text -Pattern $pattern)
    if ($hits.Count -eq 0) { continue }
    $saw = $true
    Write-AuditLog -Level '警告' -Message ('在 ' + $file + ' 中发现代理配置，行号: ' + ($hits -join ',') + '（内容已隐藏）')
    if (-not $script:Fix) { continue }
    if (-not (Backup-AuditFile -Path $file)) {
      Write-AuditLog -Level '失败' -Message ('无法备份 ' + $file + '，已取消修改。')
      continue
    }
    if ($script:DryRun) {
      Write-AuditLog -Level '预览' -Message ('将注释 ' + $file + ' 中的代理配置行')
      continue
    }
    $newline = if ($raw.Text -match "`r`n") { "`r`n" } else { "`n" }
    $lines = $raw.Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*#') { continue }
      if ($lines[$i] -match $pattern) {
        $lines[$i] = '# claude-win-env-audit 已禁用: ' + $lines[$i]
      }
    }
    try {
      Write-TextFileContent -Path $file -Text ($lines -join $newline) -Utf8Bom $raw.Utf8Bom
      Write-AuditLog -Level '已修复' -Message ('已注释 ' + $file + ' 中的代理配置行。')
    } catch {
      Write-AuditLog -Level '失败' -Message ('无法修改 ' + $file + '；原文件备份已保留。')
    }
  }

  if (-not $saw) {
    Write-AuditLog -Level '正常' -Message '未发现 npm/yarn/pnpm 代理配置。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# Git 代理配置
# ------------------------------------------------------------
function Invoke-AuditGitProxy {
  Write-SectionTitle 'Git 代理配置'
  if (-not (Test-CommandAvailable -Name 'git')) {
    Write-AuditLog -Level '信息' -Message '未找到 git。'
    Write-AuditRaw ''
    return
  }

  $keys = @(
    'http.proxy',
    'https.proxy',
    'http.https://api.anthropic.com.proxy',
    'http.https://claude.ai.proxy'
  )
  $saw = $false
  foreach ($key in $keys) {
    $value = ''
    try {
      $value = [string](& git config --global --get $key 2>$null)
    } catch {
      $value = ''
    }
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    $saw = $true
    Write-AuditLog -Level '警告' -Message ('git ' + $key + ' 已设置（值已隐藏）')
    if (-not $script:Fix) { continue }
    if ($script:DryRun) {
      Write-AuditLog -Level '预览' -Message ('将清除 git 配置 ' + $key)
      continue
    }
    try {
      & git config --global --unset-all $key 2>$null | Out-Null
      Write-AuditLog -Level '已修复' -Message ('已清除 git 配置 ' + $key + '。')
    } catch {
      Write-AuditLog -Level '失败' -Message ('无法清除 git 配置 ' + $key + '。')
    }
  }

  $extra = @()
  try {
    $list = & git config --global --list 2>$null
    foreach ($line in $list) {
      if ([string]$line -match '(?i)(proxy|anthropic|claude|baseurl|base-url)') {
        $extra += (([string]$line) -replace '=.*$', '')
      }
    }
    $extra = @($extra | Select-Object -Unique)
  } catch {
    $extra = @()
  }
  if ($extra.Count -gt 0) {
    Write-AuditLog -Level '警告' -Message ('仍存在其他相关的全局 git 配置键（值已隐藏）: ' + ($extra -join ', '))
  } elseif (-not $saw) {
    Write-AuditLog -Level '正常' -Message '未发现全局 git 代理配置。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# Claude / Router 配置文件
# ------------------------------------------------------------
function ConvertTo-DeepMap {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($prop in $Value.PSObject.Properties) {
      $map[$prop.Name] = ConvertTo-DeepMap -Value $prop.Value
    }
    return $map
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $map = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($key in @($Value.Keys)) {
      $map[$key] = ConvertTo-DeepMap -Value $Value[$key]
    }
    return $map
  }
  if ($Value -is [System.Collections.IList] -and -not ($Value -is [string])) {
    $list = New-Object System.Collections.ArrayList
    foreach ($item in $Value) { [void]$list.Add((ConvertTo-DeepMap -Value $item)) }
    return , $list
  }
  return $Value
}

function Get-JsonMatchPaths {
  param($Node, [string]$Prefix = '$')
  $paths = @()
  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($key in @($Node.Keys)) {
      $childPath = $Prefix + '.' + $key
      if (([string]$key) -match $script:JsonKeyPattern) {
        $paths += $childPath
      } else {
        $paths += @(Get-JsonMatchPaths -Node $Node[$key] -Prefix $childPath)
      }
    }
  } elseif ($Node -is [System.Collections.IList]) {
    for ($i = 0; $i -lt $Node.Count; $i++) {
      $paths += @(Get-JsonMatchPaths -Node $Node[$i] -Prefix ($Prefix + '[' + $i + ']'))
    }
  }
  return $paths
}

function Remove-JsonMatchingKeys {
  param($Node)
  $changed = $false
  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($key in @($Node.Keys)) {
      if (([string]$key) -match $script:JsonKeyPattern) {
        $Node.Remove($key)
        $changed = $true
      } elseif (Remove-JsonMatchingKeys -Node $Node[$key]) {
        $changed = $true
      }
    }
  } elseif ($Node -is [System.Collections.IList]) {
    foreach ($item in $Node) {
      if (Remove-JsonMatchingKeys -Node $item) { $changed = $true }
    }
  }
  return $changed
}

function Invoke-JsonScrubFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

  $raw = ''
  try {
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  } catch {
    Write-AuditLog -Level '警告' -Message ('无法读取 ' + $Path + '，文件保持不变。')
    return
  }

  if ($raw -notmatch $script:ThirdPartyTracePattern) { return }

  $parsed = $null
  try {
    $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    Write-AuditLog -Level '警告' -Message ('无法解析 JSON，文件保持不变: ' + $Path)
    return
  }

  $map = ConvertTo-DeepMap -Value $parsed
  $paths = @(Get-JsonMatchPaths -Node $map)
  if ($paths.Count -eq 0) { return }

  Write-AuditLog -Level '警告' -Message ('Claude 或工具配置中包含将被清理的字段路径（值已隐藏）: ' + $Path)
  foreach ($jsonPath in $paths) { Write-AuditRaw ('  ' + $jsonPath) }

  if (-not $script:Fix) { return }
  if (-not (Confirm-ThirdPartyCleanup -Target $Path)) { return }
  if (-not (Backup-AuditFile -Path $Path)) {
    Write-AuditLog -Level '失败' -Message ('无法备份 ' + $Path + '，已取消修改。')
    return
  }
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将从 ' + $Path + ' 中清理明确匹配的代理或基础 URL 字段')
    return
  }

  $changed = Remove-JsonMatchingKeys -Node $map
  if (-not $changed) {
    Write-AuditLog -Level '信息' -Message ($Path + ' 没有需要结构化删除的字段，文件保持不变。')
    return
  }
  try {
    $json = $map | ConvertTo-Json -Depth 100
    $null = $json | ConvertFrom-Json -ErrorAction Stop
    Write-TextFileContent -Path $Path -Text ($json + "`r`n") -Utf8Bom $false
    Write-AuditLog -Level '已修复' -Message ('已从 ' + $Path + ' 清理代理或基础 URL 字段。')
  } catch {
    Write-AuditLog -Level '失败' -Message ('无法安全清理 ' + $Path + '；备份已保留。')
  }
}

function Invoke-AuditClaudeConfigs {
  Write-SectionTitle 'Claude / Router 配置文件'

  $files = @(
    (Join-Path $script:HomeDir '.claude\settings.json'),
    (Join-Path $script:HomeDir '.claude\settings.local.json'),
    (Join-Path $script:HomeDir '.claude.json'),
    (Join-Path $script:HomeDir '.config\claude\settings.json'),
    (Join-Path $script:HomeDir '.claude-code-router\config.json'),
    (Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'),
    (Join-Path $env:APPDATA 'Claude\config.json'),
    (Join-Path $env:APPDATA 'claude-code-router\config.json'),
    (Join-Path $env:LOCALAPPDATA 'claude-code-router\config.json')
  )

  $found = $false
  foreach ($file in $files) {
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $found = $true
      Invoke-JsonScrubFile -Path $file
    }
  }

  # 目录内其他相关字符串（只提示，不自动改写）
  $scanDirs = @(
    (Join-Path $script:HomeDir '.claude'),
    (Join-Path $script:HomeDir '.claude-code-router'),
    (Join-Path $env:APPDATA 'Claude'),
    (Join-Path $env:APPDATA 'claude-code-router')
  )
  foreach ($dir in $scanDirs) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    $found = $true
    $hits = @()
    try {
      $candidates = Get-ChildItem -LiteralPath $dir -Recurse -Depth 4 -File -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Extension -in @('.json', '.yaml', '.yml', '.toml', '.env') -or
          $_.Name -like 'settings*' -or $_.Name -like 'config*'
        } |
        Where-Object {
          $_.FullName -notmatch '\\(cache|plugins|skills|security|file-history|tasks|backups)\\' -and
          $_.Name -ne 'history.jsonl' -and
          $_.Name -ne 'stats-cache.json' -and
          $_.Name -ne 'claude-switch-state.json' -and
          $_.Name -notlike '*.bak-*'
        }
      $marker = '(ANTHROPIC_BASE_URL|proxy|base_url|baseUrl|api_base|endpoint|aihubmix|openai-sb|oneapi|newapi|siliconflow|deepseek|moonshot|kimi|zhipu|minimax)'
      $hits = @($candidates | Select-String -Pattern $marker -CaseSensitive -List -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Path } | Select-Object -Unique | Select-Object -First 50)
    } catch {
      $hits = @()
    }
    if ($hits.Count -gt 0) {
      Write-AuditLog -Level '警告' -Message ('在 ' + $dir + ' 下发现相关字符串，请人工确认:')
      foreach ($hit in $hits) { Write-AuditRaw ('  ' + $hit) }
    }
  }

  if (-not $found) {
    Write-AuditLog -Level '正常' -Message '未发现常见 Claude/router 配置文件。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# hosts
# ------------------------------------------------------------
function Test-TargetHostName {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  $lower = $Name.ToLowerInvariant()
  return ($lower -eq 'anthropic.com' -or $lower -match '\.anthropic\.com$' -or $lower -eq 'claude.ai' -or $lower -match '\.claude\.ai$')
}

function Invoke-AuditHostsFile {
  Write-SectionTitle 'hosts 文件'
  $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
    Write-AuditLog -Level '警告' -Message ('未找到 hosts 文件: ' + $hostsPath)
    Write-AuditRaw ''
    return
  }

  $raw = Read-TextFileContent -Path $hostsPath
  $text = $raw.Text
  $newline = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $lines = $text -split "`r?`n"

  $hitLines = @()
  $newLines = New-Object System.Collections.ArrayList

  foreach ($line in $lines) {
    $original = $line
    $comment = ''
    $hashIndex = $line.IndexOf('#')
    if ($hashIndex -ge 0) {
      $comment = $line.Substring($hashIndex)
      $data = $line.Substring(0, $hashIndex)
    } else {
      $data = $line
    }
    $fields = @($data.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($fields.Count -lt 2) {
      [void]$newLines.Add($original)
      continue
    }

    $removed = $false
    $kept = @()
    for ($i = 1; $i -lt $fields.Count; $i++) {
      if (Test-TargetHostName -Name $fields[$i]) {
        $removed = $true
      } else {
        $kept += $fields[$i]
      }
    }
    if (-not $removed) {
      [void]$newLines.Add($original)
      continue
    }
    if (-not ($hitLines -contains $original)) { $hitLines += $original }

    if ($kept.Count -gt 0) {
      $rebuilt = $fields[0] + "`t" + ($kept -join "`t")
      if ($comment) { $rebuilt = $rebuilt + "`t" + $comment }
      [void]$newLines.Add($rebuilt)
    } elseif ($comment) {
      [void]$newLines.Add($comment)
    }
  }

  if ($hitLines.Count -eq 0) {
    Write-AuditLog -Level '正常' -Message 'hosts 中未发现 Claude/Anthropic 覆盖项。'
    Write-AuditRaw ''
    return
  }

  Write-AuditLog -Level '警告' -Message ('在 hosts 中发现 Claude/Anthropic 覆盖项，共 ' + $hitLines.Count + ' 行（内容已隐藏）')

  if (-not $script:Fix) {
    Write-AuditRaw ''
    return
  }

  $newText = $newLines -join $newline
  if ($script:DryRun) {
    Write-AuditLog -Level '预览' -Message ('将备份 ' + $hostsPath + ' 并从 hosts 移除 Claude/Anthropic 覆盖行')
    Write-AuditRaw ''
    return
  }

  if (-not (Backup-AuditFile -Path $hostsPath)) {
    Write-AuditLog -Level '失败' -Message '无法备份 hosts，已取消修改。'
    Write-AuditRaw ''
    return
  }

  $hostsTarget = $hostsPath
  $hostsContent = $newText
  $ok = Invoke-RootAction -Reason ('写入 ' + $hostsTarget) -Action {
    $attributes = [System.IO.File]::GetAttributes($hostsTarget)
    if ($attributes -band [System.IO.FileAttributes]::ReadOnly) {
      [System.IO.File]::SetAttributes($hostsTarget, ($attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)))
    }
    Write-TextFileContent -Path $hostsTarget -Text $hostsContent -Utf8Bom $false
  }
  if ($ok) {
    $after = Read-TextFileContent -Path $hostsPath
    $stillHit = $false
    foreach ($line in ($after.Text -split "`r?`n")) {
      $data = ($line -split '#')[0]
      foreach ($field in @($data.Trim() -split '\s+' | Where-Object { $_ -ne '' })) {
        if (Test-TargetHostName -Name $field) { $stillHit = $true }
      }
    }
    if ($stillHit) {
      Write-AuditLog -Level '失败' -Message '已尝试清理 hosts，但仍残留 Claude/Anthropic 覆盖项。'
    } else {
      Write-AuditLog -Level '已修复' -Message '已移除 hosts 中的 Claude/Anthropic 覆盖项。'
    }
  } else {
    Write-AuditLog -Level '失败' -Message '无法编辑 hosts，可能是管理员权限不足或文件写入失败。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# DNS
# ------------------------------------------------------------
function Invoke-AuditDns {
  Write-SectionTitle 'DNS'
  $servers = @()
  try {
    $addresses = Get-DnsClientServerAddress -ErrorAction Stop
    foreach ($entry in $addresses) {
      foreach ($server in @($entry.ServerAddresses)) {
        if ([string]::IsNullOrWhiteSpace([string]$server)) { continue }
        if ($servers -notcontains [string]$server) { $servers += [string]$server }
      }
    }
  } catch {
    $servers = @()
  }

  # 回退：受限环境或旧系统里 Get-DnsClientServerAddress 不可用时解析 ipconfig
  if ($servers.Count -eq 0) {
    try {
      $text = (& ipconfig.exe /all 2>$null | Out-String)
      foreach ($match in [regex]::Matches($text, '(?im)DNS Servers?\s*[\.:]*\s*((?:\d{1,3}\.){3}\d{1,3})')) {
        $server = $match.Groups[1].Value
        if ($servers -notcontains $server) { $servers += $server }
      }
    } catch {
      $servers = @()
    }
  }

  if ($servers.Count -eq 0) {
    Write-AuditLog -Level '警告' -Message '无法读取 DNS 服务器列表。'
    Write-AuditRaw ''
    return
  }

  Write-AuditLog -Level '信息' -Message ('DNS 服务器: ' + ($servers -join ' '))

  $chinaDns = @()
  foreach ($server in $servers) {
    if ($script:ChinaDnsList -contains $server) { $chinaDns += $server }
  }
  if ($chinaDns.Count -gt 0) {
    Write-AuditLog -Level '警告' -Message ('DNS 包含常见中国公共 DNS: ' + ($chinaDns -join ', ') + '。若非预期，请优先检查代理/TUN 客户端的 DNS 设置；脚本不会自动改 DNS。')
  } else {
    Write-AuditLog -Level '正常' -Message '未检测到常见中国公共 DNS 解析器。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 出口 IP
# ------------------------------------------------------------
function Enable-Tls12 {
  try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  } catch {
    # 忽略
  }
}

function Invoke-HttpJson {
  param([string]$Url)
  Enable-Tls12
  $headers = @{ 'User-Agent' = 'claude-win-env-audit/' + $script:ScriptVersion }
  try {
    return Invoke-RestMethod -Uri $Url -Headers $headers -TimeoutSec 8 -ErrorAction Stop
  } catch {
    return $null
  }
}

function Get-JsonFieldValue {
  param($Object, [string]$Name)
  if ($null -eq $Object) { return '' }
  try {
    $value = $Object.$Name
    if ($null -eq $value) { return '' }
    return [string]$value
  } catch {
    return ''
  }
}

function Get-ExitIpMetadata {
  $sources = @(
    'https://ipinfo.io/json',
    'https://ifconfig.co/json',
    'https://ipapi.co/json'
  )
  foreach ($url in $sources) {
    $data = Invoke-HttpJson -Url $url
    if ($null -eq $data) { continue }
    $result = [pscustomobject]@{
      Ip          = Get-JsonFieldValue -Object $data -Name 'ip'
      Country     = Get-JsonFieldValue -Object $data -Name 'country'
      CountryCode = Get-JsonFieldValue -Object $data -Name 'country_code'
      Org         = Get-JsonFieldValue -Object $data -Name 'org'
      City        = Get-JsonFieldValue -Object $data -Name 'city'
      Region      = Get-JsonFieldValue -Object $data -Name 'region'
      TimeZone    = Get-JsonFieldValue -Object $data -Name 'timezone'
    }
    if (-not $result.Country) { $result.Country = Get-JsonFieldValue -Object $data -Name 'country_name' }
    if (-not $result.CountryCode) { $result.CountryCode = Get-JsonFieldValue -Object $data -Name 'country_iso' }
    if (-not $result.Org) { $result.Org = Get-JsonFieldValue -Object $data -Name 'asn_org' }
    if (-not $result.Region) { $result.Region = Get-JsonFieldValue -Object $data -Name 'region_name' }
    if (-not $result.TimeZone) { $result.TimeZone = Get-JsonFieldValue -Object $data -Name 'time_zone' }
    if (-not $result.Ip) { continue }
    return $result
  }
  return $null
}

function Get-FamilyCountry {
  param([string]$Family)
  if (-not (Test-CommandAvailable -Name 'curl')) { return '' }
  try {
    $output = & curl.exe $Family -fsS -A ('claude-win-env-audit/' + $script:ScriptVersion) --connect-timeout 2 --max-time 4 'https://ifconfig.co/country-iso' 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $code = (($output | Out-String) -replace '[\r\n\s]', '').ToUpperInvariant()
    if ($code -match '^[A-Z]{2}$') { return $code }
  } catch {
    return ''
  }
  return ''
}

function Invoke-AuditExitIp {
  Write-SectionTitle '出口 IP'
  $meta = Get-ExitIpMetadata
  if ($null -eq $meta) {
    Write-AuditLog -Level '失败' -Message '无法获取公网 IP 元数据（网络不可达或查询服务不可用）。'
    Write-AuditRaw ''
    return
  }

  $countryCode = $meta.CountryCode.ToUpperInvariant()
  if (-not $countryCode -and $meta.Country -match '^[A-Za-z]{2}$') { $countryCode = $meta.Country.ToUpperInvariant() }

  Write-AuditLog -Level '信息' -Message ('IP=' + $meta.Ip + ' 国家=' + $meta.Country + ' 国家代码=' + $countryCode + ' 地区=' + $meta.Region + ' 城市=' + $meta.City + ' 时区=' + $meta.TimeZone)
  if ($meta.Org) { Write-AuditLog -Level '信息' -Message ('ASN/组织=' + $meta.Org) }
  Write-AuditLog -Level '信息' -Message '这是本次运行的出口快照，不能单凭一次结果证明出口国家长期固定。'

  if ($script:ExpectedCountry) {
    if (-not $countryCode) {
      Write-AuditLog -Level '警告' -Message ('无法确认出口国家代码，不能判断是否匹配目标国家 ' + $script:ExpectedCountry + '。')
    } elseif ($countryCode -eq $script:ExpectedCountry) {
      Write-AuditLog -Level '正常' -Message ('出口国家代码符合目标: ' + $script:ExpectedCountry + '。')
    } else {
      Write-AuditLog -Level '警告' -Message ('当前出口国家代码是 ' + $countryCode + '，不等于目标 ' + $script:ExpectedCountry + '。如果你要求固定国家，建议切换到目标出口。')
    }
  } else {
    if (-not $countryCode) {
      Write-AuditLog -Level '警告' -Message '无法确认当前出口国家代码。如需按国家检查，可传 -TargetCountry CC。'
    } elseif ($countryCode -eq 'CN') {
      Write-AuditLog -Level '警告' -Message '当前出口国家代码是 CN。建议检查代理/TUN 是否按预期工作。'
    } else {
      Write-AuditLog -Level '正常' -Message ('当前出口国家代码是 ' + $countryCode + '。默认策略接受中国大陆以外的国家；如需严格匹配，可传 -TargetCountry ' + $countryCode + '。')
    }
  }

  $countryV4 = Get-FamilyCountry -Family '-4'
  $countryV6 = Get-FamilyCountry -Family '-6'
  if ($countryV4) { Write-AuditLog -Level '信息' -Message ('IPv4 出口国家代码=' + $countryV4) }
  if ($countryV6) {
    Write-AuditLog -Level '信息' -Message ('IPv6 出口国家代码=' + $countryV6)
  } else {
    Write-AuditLog -Level '信息' -Message '未检测到可用的 IPv6 公网出口。'
  }

  if ($countryV4 -and $countryV6 -and $countryV4 -ne $countryV6) {
    Write-AuditLog -Level '警告' -Message ('IPv4 与 IPv6 的出口国家不一致: ' + $countryV4 + ' / ' + $countryV6 + '。请检查 IPv6 是否绕过代理或 TUN。')
  }
  if ($script:ExpectedCountry) {
    if ($countryV4 -and $countryV4 -ne $script:ExpectedCountry) {
      Write-AuditLog -Level '警告' -Message ('IPv4 出口不匹配目标国家 ' + $script:ExpectedCountry + '。')
    }
    if ($countryV6 -and $countryV6 -ne $script:ExpectedCountry) {
      Write-AuditLog -Level '警告' -Message ('IPv6 出口不匹配目标国家 ' + $script:ExpectedCountry + '。')
    }
  } else {
    if ($countryV4 -eq 'CN') { Write-AuditLog -Level '警告' -Message 'IPv4 出口国家代码是 CN。' }
    if ($countryV6 -eq 'CN') { Write-AuditLog -Level '警告' -Message 'IPv6 出口国家代码是 CN，可能存在 IPv6 绕行。' }
  }

  if ($meta.Org -and ($meta.Org -match $script:ChinaCloudPattern)) {
    Write-AuditLog -Level '警告' -Message 'ASN/组织看起来与中国云厂商或网络服务商有关。如非预期，建议换成目标国家内更中性的服务商或网络出口。'
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# Anthropic 端点连通性
# ------------------------------------------------------------
function Invoke-AuditAnthropicReachability {
  Write-SectionTitle 'Anthropic 端点连通性'
  Enable-Tls12
  $url = 'https://api.anthropic.com/v1/messages'
  $code = ''
  try {
    $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    $code = [string][int]$response.StatusCode
  } catch {
    $response = $null
    if ($null -ne $_.Exception) {
      $ex = $_.Exception
      while ($null -ne $ex) {
        if ($ex.PSObject.Properties.Name -contains 'Response' -and $null -ne $ex.Response) {
          try {
            $code = [string][int]$ex.Response.StatusCode
            break
          } catch {
            $code = ''
          }
        }
        $ex = $ex.InnerException
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($code) -or $code -eq '0') {
    Write-AuditLog -Level '警告' -Message ('无法连接 ' + $url + '。')
  } elseif ($code -in @('200', '201', '204', '401', '404', '405', '400')) {
    Write-AuditLog -Level '正常' -Message ('api.anthropic.com 可达，返回 HTTP ' + $code + '。')
  } elseif ($code -in @('403', '429')) {
    Write-AuditLog -Level '警告' -Message ('api.anthropic.com 可达，但返回 HTTP ' + $code + '；这可能是访问策略、频率限制或网络环境问题。')
  } elseif ($code -match '^5\d\d$') {
    Write-AuditLog -Level '警告' -Message ('api.anthropic.com 返回 HTTP ' + $code + '，远端服务或中间网络可能异常。')
  } else {
    Write-AuditLog -Level '信息' -Message ('api.anthropic.com 返回 HTTP ' + $code + '。')
  }
  Write-AuditRaw ''
}

# ------------------------------------------------------------
# 总结与报告
# ------------------------------------------------------------
function Write-Summary {
  Write-SectionTitle '总结'
  Write-AuditRaw ('正常=' + $script:CountOk + ' 警告=' + $script:CountWarn + ' 已修复=' + $script:CountFixed + ' 失败=' + $script:CountFail + ' 信息=' + $script:CountInfo)
  if ($script:ReportDirWritable) {
    Write-AuditRaw ('报告已保存到: ' + $script:ReportFile)
  } else {
    Write-AuditRaw ('报告未能写入（目录不可写）: ' + $script:ReportFile)
  }
  if ($script:BackupDirReady) {
    Write-AuditRaw ('备份已保存到: ' + $script:BackupDir)
  } else {
    Write-AuditRaw ('备份目录不可用（未创建）: ' + $script:BackupDir)
  }
  if ($script:Fix -and -not $script:DryRun) {
    Write-AuditRaw '重新检查环境变量前请打开新的终端窗口；子进程无法移除父级 shell 中已经存在的变量。'
  }
}

function Save-Report {
  if (-not $script:ReportDirWritable) { return }
  try {
    $parent = Split-Path -Parent $script:ReportFile
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
    }
    $content = ($script:ReportLines -join "`r`n") + "`r`n"
    Write-TextFileContent -Path $script:ReportFile -Text $content -Utf8Bom $false
    Restrict-PathAcl -Path $script:ReportFile
  } catch {
    Write-Host ('[警告] 无法写入报告文件: ' + $_.Exception.Message)
  }
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
function Invoke-Main {
  Initialize-AuditContext
  if (Try-RelaunchElevated) { return }
  Write-Header

  $total = $script:ActiveSections.Count
  $index = 0
  foreach ($section in $script:ActiveSections) {
    $index++
    $beforeOk = $script:CountOk
    $beforeWarn = $script:CountWarn
    $beforeFixed = $script:CountFixed
    $beforeFail = $script:CountFail
    $beforeInfo = $script:CountInfo
    $title = Get-SectionDisplayName -Section $section
    Write-AuditEvent @{ type = 'section-start'; section = $section; title = $title; index = $index; total = $total }

    switch ($section) {
      'os' { Invoke-AuditOs }
      'timezone' { Invoke-AuditTimezone }
      'system-proxy' { Invoke-AuditSystemProxy }
      'env' { Invoke-AuditEnv }
      'shell-startup' { Invoke-AuditShellStartup }
      'package-managers' { Invoke-AuditPackageManagers }
      'git' { Invoke-AuditGitProxy }
      'claude-configs' { Invoke-AuditClaudeConfigs }
      'hosts' { Invoke-AuditHostsFile }
      'dns' { Invoke-AuditDns }
      'exit-ip' {
        if ($script:Offline) {
          Write-SectionTitle '出口 IP'
          Write-AuditLog -Level '信息' -Message '已启用 -Offline，跳过公网 IP 检测。'
          Write-AuditRaw ''
        } else {
          Invoke-AuditExitIp
        }
      }
      'anthropic' {
        if ($script:Offline) {
          Write-SectionTitle 'Anthropic 端点连通性'
          Write-AuditLog -Level '信息' -Message '已启用 -Offline，跳过 Anthropic 端点联网检测。'
          Write-AuditRaw ''
        } else {
          Invoke-AuditAnthropicReachability
        }
      }
      default { }
    }

    Write-AuditEvent @{ type = 'section-end'; section = $section; title = $title; index = $index; total = $total; ok = ($script:CountOk - $beforeOk); warn = ($script:CountWarn - $beforeWarn); fixed = ($script:CountFixed - $beforeFixed); fail = ($script:CountFail - $beforeFail); info = ($script:CountInfo - $beforeInfo) }
  }

  Write-Summary
  Save-Report

  Write-AuditEvent @{ type = 'done'; ok = $script:CountOk; warn = $script:CountWarn; fixed = $script:CountFixed; fail = $script:CountFail; info = $script:CountInfo; total = $total; reportFile = $script:ReportFile; backupDir = $script:BackupDir; reportSaved = $script:ReportDirWritable }
}

Invoke-Main
exit 0

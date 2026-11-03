#requires -Version 3.0
<#
    宽带自动拨号 · 一键部署工具  (v3)
    ============================================================
    作者: 弥琉
    QQ  : 458423691

    兼容性:
      - Windows 10 / Windows 11（Windows 8 及以上亦可）
      - PowerShell 3.0 及以上；推荐 5.1（Win10/Win11 自带）
      - 低于 3.0 会明确提示，不会静默失败

    功能:
      1  安装 / 修复   全自动完成，只需输入宽带账号密码
      2  修改账号密码
      3  一键卸载
      4  删除指定宽带连接
      5  仅新增宽带账号（不安装自动拨号）
      6  查看当前状态（诊断用）

    部署产物:
      C:\ProgramData\AutoDialGuard\autodial-guard.ps1   守护脚本
      计划任务「自动拨号宽带」

    运行要求: 管理员权限（脚本自动提权）

    ------------------------------------------------------------
    本工具由 弥琉 制作，QQ 458423691
    可自由使用与分发，请保留此署名信息
    ------------------------------------------------------------
#>

param(
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

# ================================================================ 常量
$TaskName   = '自动拨号宽带'
$InstallDir = Join-Path $env:ProgramData 'AutoDialGuard'
$GuardPath  = Join-Path $InstallDir 'autodial-guard.ps1'
$LogPath    = Join-Path $InstallDir 'guard.log'
# 用 $env:ProgramData 而非硬编码 C:\，兼容 ProgramData 被重定位的环境
$PbkPath    = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
# 记录「由本工具创建」的连接名。卸载时只删这个文件里记录的连接，
# 用户原有的连接一律不动。
$MarkerPath = Join-Path $InstallDir 'created-entry.txt'
# 默认连接名沿用 Windows 自带命名惯例（宽带连接），不预设任何特定名称
$DefaultEntryName = '宽带连接'

# ================================================================ 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "正在请求管理员权限..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($NoPause) { $argList += '-NoPause' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -ErrorAction Stop
        Write-Host "已在新窗口启动，请切换到新窗口操作。" -ForegroundColor Green
    } catch {
        Write-Host ("提权失败: " + $_.Exception.Message) -ForegroundColor Red
    }
    exit
}

# 注意: 不要修改 [Console]::OutputEncoding。
# 它决定 PowerShell 如何解码原生命令（rasdial）的输出。
# 中文 Windows 默认 GBK(936)，强制改成 UTF8 会让 rasdial 输出变成乱码，
# 进而导致错误码解析失败。PowerShell 自身的 Write-Host 输出不受此影响。

$psMajor = $PSVersionTable.PSVersion.Major
$psMinor = $PSVersionTable.PSVersion.Minor
Write-Host ("运行环境: Windows " + [Environment]::OSVersion.Version.Major + "." + [Environment]::OSVersion.Version.Minor + " / PowerShell " + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
if ($psMajor -lt 3) {
    Write-Host ""
    Write-Host ("当前 PowerShell 版本过低（" + $PSVersionTable.PSVersion + "），需要 3.0 及以上。") -ForegroundColor Red
    Write-Host "Windows 10 / 11 自带 5.1，请确认没有在旧系统上运行。" -ForegroundColor Yellow
    if (-not $NoPause) { Read-Host "按回车退出" }
    exit 1
}
if ($psMajor -lt 5) {
    Write-Host "提示: PowerShell 版本较低，建议升级到 5.1 以获得最佳兼容性。" -ForegroundColor Yellow
}

# ================================================================ 守护脚本模板（内嵌）
$GuardTemplate = @'
#requires -Version 3.0
<#
    自动拨号守护脚本（由计划任务调用，请勿直接运行）
    状态文件: C:\ProgramData\AutoDialGuard\state.json
    日志文件: C:\ProgramData\AutoDialGuard\guard.log
#>

param(
    [string]$EntryName      = '@@ENTRY@@',
    [string]$UserName       = '@@USER@@',
    [string]$Password       = '@@PASS@@',
    [int]$WindowMinutes     = 10,
    [int]$CooldownMinutes   = 30,
    [int]$Threshold         = 2,
    [int]$DialRetries       = 3,
    [int]$RetryDelaySec     = 20
)

$ErrorActionPreference = 'Continue'

$stateDir  = Join-Path $env:ProgramData 'AutoDialGuard'
$stateFile = Join-Path $stateDir 'state.json'
$logFile   = Join-Path $stateDir 'guard.log'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Write-Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try {
        # 日志轮转：超过 512KB 滚为 .old，避免长期运行无限增长
        if (Test-Path $logFile) {
            if ((Get-Item $logFile).Length -gt 524288) {
                Move-Item -LiteralPath $logFile -Destination ($logFile + '.old') -Force -ErrorAction SilentlyContinue
            }
        }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch {}
}

function Read-State {
    if (Test-Path $stateFile) {
        try { return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ Count = 0; LastEvent = $null; CooldownUntil = $null }
}

function Save-State {
    param($s)
    try { $s | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8 } catch {}
}

$now   = Get-Date
$state = Read-State

# ---------------------------------------------------------------- 冷却期检查
if ($state.CooldownUntil) {
    $until = $null
    try { $until = [datetime]::Parse($state.CooldownUntil) } catch {}
    if ($until -and $now -lt $until) {
        Write-Log ("冷却中，跳过拨号。解除时间: " + $until.ToString('yyyy-MM-dd HH:mm:ss'))
        exit 0
    }
}

# ---------------------------------------------------------------- 是否已连接
$connected = $false
try {
    $ad = Get-NetAdapter -Name $EntryName -ErrorAction Stop
    if ($ad -and $ad.Status -eq 'Up') { $connected = $true }
} catch {
    try {
        $ip = Get-NetIPAddress -InterfaceAlias $EntryName -AddressFamily IPv4 -ErrorAction Stop
        foreach ($a in $ip) {
            if ($a.IPAddress -and $a.IPAddress -notlike '169.254.*') { $connected = $true; break }
        }
    } catch {}
}

if ($connected) {
    Write-Log ("「" + $EntryName + "」已连接，无需操作")
    exit 0
}

# ---------------------------------------------------------------- 判断触发来源
$isDisconnectEvent = $false
try {
    $logName = 'Microsoft-Windows-NetworkProfile/Operational'
    $q = '<QueryList><Query Id="0" Path="' + $logName + '"><Select Path="' + $logName + '">' +
         "*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10001]]" +
         '</Select></Query></QueryList>'
    $ev = Get-WinEvent -FilterXml $q -MaxEvents 1 -ErrorAction Stop
    if ($ev -and $ev.TimeCreated -gt $now.AddSeconds(-30)) { $isDisconnectEvent = $true }
} catch {}

# ---------------------------------------------------------------- 计数与熔断
if ($isDisconnectEvent) {
    $prev = $null
    if ($state.LastEvent) { try { $prev = [datetime]::Parse($state.LastEvent) } catch {} }

    if ($prev -and ($now - $prev).TotalMinutes -lt $WindowMinutes) {
        $state.Count = [int]$state.Count + 1
    } else {
        $state.Count = 1
    }
    $state.LastEvent = $now.ToString('o')

    Write-Log ("检测到断开事件，连续计数 = " + $state.Count + "（阈值 " + $Threshold + "）")

    if ($state.Count -ge $Threshold) {
        $state.CooldownUntil = $now.AddMinutes($CooldownMinutes).ToString('o')
        Save-State $state
        Write-Log ("连续断开达到 " + $Threshold + " 次，判定为主动断开，进入 " + $CooldownMinutes + " 分钟冷却，不再重拨")
        exit 0
    }
    Save-State $state
} else {
    Write-Log "非断开事件触发（开机/登录/解锁），直接拨号，不参与计数"
}

# ---------------------------------------------------------------- 拨号
$ok = $false
for ($i = 1; $i -le $DialRetries; $i++) {
    Write-Log ("拨号尝试 " + $i + "/" + $DialRetries)
    $out = & rasdial $EntryName $UserName $Password 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        Write-Log "拨号成功"
        $ok = $true
        break
    }
    $msg = ($out -join ' ').Trim()
    Write-Log ("拨号失败，退出码 " + $code + "，输出: " + $msg)
    if ($i -lt $DialRetries) { Start-Sleep -Seconds $RetryDelaySec }
}

if ($ok) {
    Write-Log "拨号成功，保留计数（下次断开在时间窗内则累加）"
} else {
    Write-Log "全部尝试失败，等待下次触发"
}

exit 0
'@

# ================================================================ 工具函数
function Test-Installed {
    # 注意: 用「或」而不是「与」。
    # 只要任务或安装目录任一存在，就视为已安装。
    # 否则目录被误删时，卸载会误判为未安装，留下孤儿任务无法清理。
    $hasTask = ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
    $hasDir  = (Test-Path $InstallDir)
    return ($hasTask -or $hasDir)
}

function Get-InstallState {
    $hasTask = ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
    $hasDir  = (Test-Path $InstallDir)
    $hasFile = (Test-Path $GuardPath)
    return [pscustomobject]@{
        Task     = $hasTask
        Dir      = $hasDir
        Script   = $hasFile
        Complete = ($hasTask -and $hasFile)
    }
}

function Get-PppoeEntries {
    $result = @()
    if (Test-Path $PbkPath) {
        $lines = Get-Content -LiteralPath $PbkPath -Encoding UTF8
        $cur = $null
        foreach ($l in $lines) {
            if ($l -match '^\[(.*)\]\s*$') {
                # 名称为空的段落直接忽略，不计入有效连接
                $n = $Matches[1].Trim()
                $cur = if ($n) { $n } else { $null }
            }
            elseif ($l -match '^Type=5' -and $cur) { $result += $cur; $cur = $null }
        }
    }
    # 直接输出集合，由调用方用 @() 包裹成数组。
    # 不要用 Write-Output -NoEnumerate —— 它与调用方的 @() 叠加会产生嵌套数组。
    return $result
}

# 生成不与现有连接冲突的默认名称（宽带连接 / 宽带连接 2 / 宽带连接 3 ...）
function Get-UniqueEntryName {
    param([string]$Base)
    $existing = @(Get-PppoeEntries)
    if ($existing -notcontains $Base) { return $Base }
    for ($n = 2; $n -le 99; $n++) {
        $cand = "$Base $n"
        if ($existing -notcontains $cand) { return $cand }
    }
    return ($Base + ' ' + (Get-Random -Minimum 100 -Maximum 999))
}

function Get-PppoePort {
    if (Test-Path $PbkPath) {
        foreach ($l in (Get-Content -LiteralPath $PbkPath -Encoding UTF8)) {
            if ($l -match '^Port=(PPPoE\d+-\d+)\s*$') { return $Matches[1] }
        }
    }
    return 'PPPoE0-0'
}

function Get-CurrentConfig {
    if (-not (Test-Path $GuardPath)) { return $null }
    $t = Get-Content -LiteralPath $GuardPath -Raw -Encoding UTF8
    $e = [regex]::Match($t, "\`$EntryName\s*=\s*'((?:[^']|'')*)'")
    $u = [regex]::Match($t, "\`$UserName\s*=\s*'((?:[^']|'')*)'")
    $p = [regex]::Match($t, "\`$Password\s*=\s*'((?:[^']|'')*)'")
    # 写入时把 ' 转义成 ''，读回必须反转义，否则沿用原密码会变成两个引号
    $un = { param($m) if ($m.Success) { $m.Groups[1].Value.Replace("''", "'") } else { '' } }
    return [pscustomobject]@{
        EntryName = & $un $e
        UserName  = & $un $u
        Password  = & $un $p
    }
}

# ---------------------------------------------------------------- 安装目录权限加固
# ProgramData 默认允许 Users 在子目录中创建文件。若不收紧，普通用户可删除
# 守护脚本后投放同名脚本，被以最高权限运行的计划任务执行 —— 等于提权通道。
# 这里断开继承，并把 Users 收紧为只读+执行。
function Set-InstallDirAcl {
    param([string]$Dir)
    try {
        if (-not (Test-Path $Dir)) { return }
        $acl = Get-Acl -LiteralPath $Dir
        $acl.SetAccessRuleProtection($true, $true)
        foreach ($r in @($acl.Access)) {
            if ($r.AccessControlType -eq 'Allow' -and
                $r.IdentityReference -match 'Users' -and
                ($r.FileSystemRights.ToString() -match 'Write|Modify|FullControl')) {
                [void]$acl.RemoveAccessRule($r)
            }
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Dir -AclObject $acl
    } catch {}
}

function Write-GuardScript {
    param([string]$EntryName, [string]$UserName, [string]$Password)
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $body = $GuardTemplate
    $body = $body.Replace('@@ENTRY@@', $EntryName.Replace("'", "''"))
    $body = $body.Replace('@@USER@@',  $UserName.Replace("'", "''"))
    $body = $body.Replace('@@PASS@@',  $Password.Replace("'", "''"))
    [System.IO.File]::WriteAllText($GuardPath, $body, (New-Object System.Text.UTF8Encoding($true)))
    Set-InstallDirAcl -Dir $InstallDir
}

# 返回上一级的信号。子功能捕获后直接回到主菜单。
$script:BackSignal = 'BACK_TO_MENU'

# 判断输入是否为「返回上一级」：b / back / 返回；-AllowZero 未指定时 0 也算
function Test-BackInput {
    param([string]$Value, [switch]$AllowZero)
    $t = ("" + $Value).Trim()
    if ($t -eq 'b' -or $t -eq 'B' -or $t -eq 'back' -or $t -eq 'BACK' -or $t -eq '返回') { return $true }
    if (-not $AllowZero -and $t -eq '0') { return $true }
    return $false
}

# 统一输入入口：识别到返回指令时抛出信号，由子功能统一捕获
function Read-Input {
    param([string]$Prompt, [switch]$AllowZero)
    $v = Read-Host $Prompt
    if (Test-BackInput -Value $v -AllowZero:$AllowZero) { throw $script:BackSignal }
    return $v
}

function Read-Password {
    param([string]$Prompt)
    $sec  = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $p    = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    # 密码输入同样支持 b / 返回
    if ($p -eq 'b' -or $p -eq 'B' -or $p -eq 'back' -or $p -eq '返回') { throw $script:BackSignal }
    return $p
}

# ---------------------------------------------------------------- 新建 PPPoE 连接
function New-PppoeEntry {
    param([string]$Name, [string]$UserName)

    # 名称校验：方括号会破坏 [节名] 结构
    $Name = ($Name -replace '[\r\n\t]', '').Trim()
    if (-not $Name) { throw "连接名不能为空" }
    if ($Name -match '[\[\]]') { throw "连接名不能包含方括号 [ ]" }
    if ($Name.Length -gt 100) { throw "连接名过长（最多 100 字符）" }

    # 重名检查：直接追加会产生重复节，导致该连接行为异常
    $existing = @(Get-PppoeEntries)
    if ($existing -contains $Name) {
        throw ("连接「" + $Name + "」已存在。请换一个名称，或返回菜单选择使用现有连接")
    }

    # 空电话簿（0 字节）直接清除重写，避免残留空行影响后续解析
    if ((Test-Path $PbkPath) -and (Get-Item $PbkPath).Length -eq 0) {
        Remove-Item -LiteralPath $PbkPath -Force -ErrorAction SilentlyContinue
        Write-Host "   检测到空电话簿，已清除" -ForegroundColor DarkGray
    }

    # 从未用过拨号的机器可能没有电话簿文件，需要先创建
    if (-not (Test-Path $PbkPath)) {
        $pbkDir = Split-Path -Parent $PbkPath
        if (-not (Test-Path $pbkDir)) { New-Item -ItemType Directory -Path $pbkDir -Force | Out-Null }
        [System.IO.File]::WriteAllText($PbkPath, '', (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "   电话簿不存在，已新建" -ForegroundColor DarkGray
    } else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bak = "$PbkPath.bak-$stamp"
        Copy-Item -LiteralPath $PbkPath -Destination $bak -Force
        Write-Host ("   已备份电话簿: " + $bak) -ForegroundColor DarkGray
    }

    $port = Get-PppoePort
    $guid = [guid]::NewGuid().ToString('N').ToUpper()
    $uid  = Get-Random -Minimum 1000000 -Maximum 9999999

    $ft    = [DateTime]::UtcNow.ToFileTimeUtc()
    $bytes = [BitConverter]::GetBytes([int64]$ft)
    $low   = [BitConverter]::ToInt32($bytes, 0)
    $high  = [BitConverter]::ToInt32($bytes, 4)

    $entry = @'

[@@NAME@@]
Encoding=1
PBVersion=8
Type=5
AutoLogon=0
UseRasCredentials=0
UserName=@@USER@@
LowDateTime=@@LOW@@
HighDateTime=@@HIGH@@
DialParamsUID=@@UID@@
Guid=@@GUID@@
VpnStrategy=0
ExcludedProtocols=0
LcpExtensions=1
DataEncryption=8
SwCompression=0
NegotiateMultilinkAlways=0
SkipDoubleDialDialog=0
DialMode=0
OverridePref=15
RedialAttempts=3
RedialSeconds=60
IdleDisconnectSeconds=0
RedialOnLinkFailure=1
CallbackMode=0
CustomDialDll=
CustomDialFunc=
CustomRasDialDll=
ForceSecureCompartment=0
DisableIKENameEkuCheck=0
AuthenticateServer=0
ShareMsFilePrint=0
BindMsNetClient=0
SharedPhoneNumbers=0
GlobalDeviceSettings=0
PrerequisiteEntry=
PrerequisitePbk=
PreferredPort=@@PORT@@
PreferredDevice=WAN Miniport (PPPOE)
PreferredBps=0
PreferredHwFlow=0
PreferredProtocol=0
PreferredCompression=0
PreferredSpeaker=0
PreferredMdmProtocol=0
PreviewUserPw=1
PreviewDomain=0
PreviewPhoneNumber=0
ShowDialingProgress=1
ShowMonitorIconInTaskBar=1
CustomAuthKey=0
AuthRestrictions=552
IpPrioritizeRemote=1
IpInterfaceMetric=0
IpHeaderCompression=0
IpAddress=0.0.0.0
IpDnsAddress=0.0.0.0
IpDns2Address=0.0.0.0
IpWinsAddress=0.0.0.0
IpWins2Address=0.0.0.0
IpAssign=1
IpNameAssign=1
IpDnsFlags=0
IpNBTFlags=0
TcpWindowSize=0
UseFlags=3
IpSecFlags=0
IpDnsSuffix=
Ipv6Assign=1
Ipv6Address=::
Ipv6PrefixLength=0
Ipv6PrioritizeRemote=1
Ipv6InterfaceMetric=0
Ipv6NameAssign=1
Ipv6DnsAddress=::
Ipv6Dns2Address=::
Ipv6Prefix=0000000000000000
Ipv6InterfaceId=0000000000000000
DisableClassBasedDefaultRoute=0
DisableMobility=0
NetworkOutageTime=0
IDI=
IDR=
ImsConfig=0
IdiType=0
IdrType=0
ProvisionType=0
PreSharedKey=
CacheCredentials=1
NumCustomPolicy=0
NumEku=0
UseMachineRootCert=0
Disable_IKEv2_Fragmentation=0
PlumbIKEv2TSAsRoutes=0
NumServers=0
RouteVersion=1
NumRoutes=0
NumNrptRules=0
AutoTiggerCapable=0
NumAppIds=0
NumClassicAppIds=0
SecurityDescriptor=
ApnInfoProviderId=
ApnInfoUsername=
ApnInfoPassword=
ApnInfoAccessPoint=
ApnInfoAuthentication=1
ApnInfoCompression=0
DeviceComplianceEnabled=0
DeviceComplianceSsoEnabled=0
DeviceComplianceSsoEku=
DeviceComplianceSsoIssuer=
FlagsSet=0
Options=0
DisableDefaultDnsSuffixes=0
NumTrustedNetworks=0
NumDnsSearchSuffixes=0
PowershellCreatedProfile=0
ProxyFlags=0
ProxySettingsModified=0
ProvisioningAuthority=
AuthTypeOTP=0
GREKeyDefined=0
NumPerAppTrafficFilters=0
AlwaysOnCapable=0
DeviceTunnel=0
PrivateNetwork=0
ManagementApp=

NETCOMPONENTS=
ms_msclient=0
ms_server=0

MEDIA=rastapi
Port=@@PORT@@
Device=WAN Miniport (PPPOE)

DEVICE=PPPoE
PhoneNumber=
AreaCode=
CountryCode=0
CountryID=0
UseDialingRules=0
Comment=
FriendlyName=
LastSelectedPhone=0
PromoteAlternates=0
TryNextAlternateOnFail=1
'@

    $entry = $entry.Replace('@@NAME@@', $Name)
    $entry = $entry.Replace('@@USER@@', $UserName)
    $entry = $entry.Replace('@@PORT@@', $port)
    $entry = $entry.Replace('@@GUID@@', $guid)
    $entry = $entry.Replace('@@UID@@',  [string]$uid)
    $entry = $entry.Replace('@@LOW@@',  [string]$low)
    $entry = $entry.Replace('@@HIGH@@', [string]$high)

    # 用 .NET 追加，避免 Add-Content 在文件中间写入 BOM 破坏电话簿
    [System.IO.File]::AppendAllText($PbkPath, $entry, (New-Object System.Text.UTF8Encoding($false)))

    $after = @(Get-PppoeEntries)
    if ($after -notcontains $Name) { throw "写入后未能识别到新连接「$Name」" }
    return $port
}

# ---------------------------------------------------------------- 创建标记
# 记录「本工具创建过」的所有连接名，每行一个。
# 卸载/删除时据此决定删除哪些电话簿条目；用户原有的连接不在列表中，永不删除。
# 兼容旧格式：旧版本文件只有一行，读取时自然当作单元素列表。
function Get-CreatedMarkers {
    $list = @()
    if (Test-Path $MarkerPath) {
        try {
            foreach ($l in (Get-Content -LiteralPath $MarkerPath -Encoding UTF8)) {
                $n = ("" + $l).Trim()
                if ($n -and ($list -notcontains $n)) { $list += $n }
            }
        } catch {}
    }
    return $list
}

function Save-CreatedMarkers {
    param([string[]]$List)
    try {
        if (@($List).Count -eq 0) {
            if (Test-Path $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue }
            return
        }
        if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
        [System.IO.File]::WriteAllLines($MarkerPath, [string[]]$List, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

function Add-CreatedMarker {
    param([string]$Name)
    if (-not $Name) { return }
    $list = @(Get-CreatedMarkers)
    if ($list -contains $Name) { return }
    $list += $Name
    Save-CreatedMarkers -List $list
}

function Remove-CreatedMarker {
    param([string]$Name)
    if (-not $Name) { return }
    $list = @(Get-CreatedMarkers | Where-Object { $_ -ne $Name })
    Save-CreatedMarkers -List $list
}

function Clear-CreatedMarker {
    try { if (Test-Path $MarkerPath) { Remove-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue } } catch {}
}

# ---------------------------------------------------------------- 删除电话簿条目
# 仅用于删除本工具创建的连接；调用前必须已确认标记匹配。
function Remove-PppoeEntry {
    param([string]$Name)

    if (-not (Test-Path $PbkPath)) { throw "电话簿不存在" }

    $raw = [System.IO.File]::ReadAllText($PbkPath, [System.Text.Encoding]::UTF8)
    $nl  = if ($raw -match "`r`n") { "`r`n" } else { "`n" }

    $lines = [System.IO.File]::ReadAllLines($PbkPath, [System.Text.Encoding]::UTF8)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq ("[" + $Name + "]")) { $start = $i; break }
    }
    if ($start -lt 0) { return $false }

    $end = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[') { $end = $i; break }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $PbkPath -Destination ("$PbkPath.bak-$stamp") -Force

    $keep = @()
    if ($start -gt 0) { $keep += $lines[0..($start - 1)] }
    if ($end -lt $lines.Count) { $keep += $lines[$end..($lines.Count - 1)] }
    # 去掉尾部多余空行。
    # 注意: 不能写 $keep[0..($keep.Count-2)] —— 当只剩 1 个元素时
    # 该表达式会变成 $keep[0,-1]（两个元素），导致数量在 1/2 之间震荡而陷入死循环。
    while ($keep.Count -gt 0 -and -not $keep[$keep.Count - 1].Trim()) {
        if ($keep.Count -eq 1) { $keep = @(); break }
        $keep = $keep[0..($keep.Count - 2)]
    }
    if ($keep.Count -eq 0) { $keep = @() }

    $out = if ($keep.Count -gt 0) { (($keep -join $nl) + $nl) } else { '' }
    [System.IO.File]::WriteAllText($PbkPath, $out, (New-Object System.Text.UTF8Encoding($false)))

    # 确认已移除
    return (@(Get-PppoeEntries) -notcontains $Name)
}

# ---------------------------------------------------------------- 清除空白/残缺条目
# 电话簿里可能出现「名称为空」或「缺少 Type= 字段」的残缺段落，
# 这类条目在界面上表现为一条空白账号，无法使用，直接清除。
function Clear-BlankEntries {
    if (-not (Test-Path $PbkPath)) { return 0 }
    $raw = [System.IO.File]::ReadAllText($PbkPath, [System.Text.Encoding]::UTF8)
    if (-not $raw.Trim()) { return 0 }

    $nl    = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.IO.File]::ReadAllLines($PbkPath, [System.Text.Encoding]::UTF8)

    $drop = New-Object 'System.Collections.Generic.HashSet[int]'
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -match '^\[(.*)\]\s*$') {
            $name = $Matches[1].Trim()
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\[') { $j++ }
            $body = @()
            if ($j -gt ($i + 1)) { $body = $lines[($i + 1)..($j - 1)] }
            $hasType = @($body | Where-Object { $_ -match '^Type=\d' }).Count -gt 0
            if ((-not $name) -or (-not $hasType)) {
                for ($k = $i; $k -lt $j; $k++) { [void]$drop.Add($k) }
            }
            $i = $j
        } else {
            $i++
        }
    }
    if ($drop.Count -eq 0) { return 0 }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $PbkPath -Destination ("$PbkPath.bak-$stamp") -Force

    $keep = @()
    for ($k = 0; $k -lt $lines.Count; $k++) {
        if (-not $drop.Contains($k)) { $keep += $lines[$k] }
    }
    while ($keep.Count -gt 0 -and -not $keep[$keep.Count - 1].Trim()) {
        if ($keep.Count -eq 1) { $keep = @(); break }
        $keep = $keep[0..($keep.Count - 2)]
    }
    $out = if ($keep.Count -gt 0) { (($keep -join $nl) + $nl) } else { '' }
    [System.IO.File]::WriteAllText($PbkPath, $out, (New-Object System.Text.UTF8Encoding($false)))
    return $drop.Count
}

# ---------------------------------------------------------------- 列出全部段落（含无效）
# 与 Get-PppoeEntries 不同，这里会返回名称为空或缺 Type= 的残缺段落，
# 以便在删除界面里展示出来，让用户能看到并选择清除。
function Get-AllSections {
    $out = @()
    if (Test-Path $PbkPath) {
        $lines = [System.IO.File]::ReadAllLines($PbkPath, [System.Text.Encoding]::UTF8)
        $i = 0
        while ($i -lt $lines.Count) {
            if ($lines[$i] -match '^\[(.*)\]\s*$') {
                $name = $Matches[1].Trim()
                $j = $i + 1
                while ($j -lt $lines.Count -and $lines[$j] -notmatch '^\[') { $j++ }
                $body = @()
                if ($j -gt ($i + 1)) { $body = $lines[($i + 1)..($j - 1)] }
                $hasType = @($body | Where-Object { $_ -match '^Type=\d' }).Count -gt 0
                $out += [pscustomobject]@{
                    Name   = $name
                    Valid  = [bool]($name -and $hasType)
                    LineNo = $i
                }
                $i = $j
            } else {
                $i++
            }
        }
    }
    # 直接输出集合，由调用方用 @() 包裹
    return $out
}

# ---------------------------------------------------------------- 复核某段落是否确实无效
# 重新读取电话簿并定位该段落，连续多次结果一致才认定为无效，避免误删。
function Test-SectionInvalid {
    param([int]$Position, [string]$ExpectedName)
    $s = @(Get-AllSections)
    if ($Position -lt 0 -or $Position -ge $s.Count) { return $false }
    $x = $s[$Position]
    if ($x.Name -ne $ExpectedName) { return $false }   # 位置已变化，放弃
    return (-not $x.Valid)
}

# ---------------------------------------------------------------- 重命名已有连接
function Rename-PppoeEntry {
    param([string]$OldName, [string]$NewName)

    $NewName = ($NewName -replace '[\r\n\t]', '').Trim()
    if (-not $NewName) { throw "新名称不能为空" }
    if ($NewName -match '[\[\]]') { throw "名称不能包含方括号 [ ]" }
    if ($NewName -eq $OldName) { return $OldName }
    if (@(Get-PppoeEntries) -contains $NewName) { throw ("连接「" + $NewName + "」已存在") }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $PbkPath -Destination "$PbkPath.bak-$stamp" -Force

    $raw = [System.IO.File]::ReadAllText($PbkPath, [System.Text.Encoding]::UTF8)
    $pattern = '(?m)^\[' + [regex]::Escape($OldName) + '\]\s*$'
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern)
    if (-not $rx.IsMatch($raw)) { throw "电话簿中找不到连接「$OldName」" }
    # 替换串中的 $ 会被 .NET 正则当作变量引用，需转义
    $replacement = ('[' + $NewName + ']').Replace('$', '$$')
    $raw = $rx.Replace($raw, $replacement, 1)
    [System.IO.File]::WriteAllText($PbkPath, $raw, (New-Object System.Text.UTF8Encoding($false)))

    if (@(Get-PppoeEntries) -notcontains $NewName) { throw "重命名后未能识别到新名称" }

    # 若这条连接是本工具创建的，同步更新标记，否则卸载时会找不到目标
    if (@(Get-CreatedMarkers) -contains $OldName) {
        Remove-CreatedMarker $OldName
        Add-CreatedMarker $NewName
    }

    return $NewName
}

# ---------------------------------------------------------------- 写入连接凭据
function Set-RasCredentials {
    param([string]$EntryName, [string]$UserName, [string]$Password)

    if (-not ([System.Management.Automation.PSTypeName]'RasCredX').Type) {
        $code = @'
using System;
using System.Runtime.InteropServices;
public class RasCredX
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RASCREDENTIALS
    {
        public int dwSize;
        public int dwMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szUserName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string szPassword;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 16)]  public string szDomain;
    }
    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasSetCredentials(string lpszPhonebook, string lpszEntry, ref RASCREDENTIALS lpCredentials, bool fClearCredentials);
    [DllImport("rasapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int RasGetCredentials(string lpszPhonebook, string lpszEntry, ref RASCREDENTIALS lpCredentials);
}
'@
        try { Add-Type -TypeDefinition $code -Language CSharp -ErrorAction Stop } catch { }
    }

    $c = New-Object RasCredX+RASCREDENTIALS
    $c.dwSize     = [Runtime.InteropServices.Marshal]::SizeOf($c)
    $c.dwMask     = 0x1 -bor 0x2 -bor 0x4
    $c.szUserName = $UserName
    $c.szPassword = $Password
    $c.szDomain   = ""

    return [RasCredX]::RasSetCredentials($PbkPath, $EntryName, [ref]$c, $false)
}

# ---------------------------------------------------------------- 校验连接凭据
# 回读确认密码确实写入（Windows 只返回 16 个星号，不回显明文）
function Test-RasCredentials {
    param([string]$EntryName, [string]$UserName)
    try {
        $v = New-Object RasCredX+RASCREDENTIALS
        $v.dwSize = [Runtime.InteropServices.Marshal]::SizeOf($v)
        $rc = [RasCredX]::RasGetCredentials($PbkPath, $EntryName, [ref]$v)
        if ($rc -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = ("RasGetCredentials 返回 " + $rc) } }
        if ($v.szUserName -ne $UserName) {
            return [pscustomobject]@{ Ok = $false; Reason = ("用户名不一致，回读为 [" + $v.szUserName + "]") }
        }
        if ($v.szPassword -eq ('*' * 16)) {
            return [pscustomobject]@{ Ok = $true; Reason = "密码已保存" }
        }
        return [pscustomobject]@{ Ok = $false; Reason = "密码回读为空，未真正保存" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = ("校验异常: " + $_.Exception.Message) }
    }
}

# ---------------------------------------------------------------- 测试拨号
function Invoke-TestDial {
    param([string]$EntryName, [string]$UserName, [string]$Password)
    $out = & rasdial $EntryName $UserName $Password 2>&1
    $code = $LASTEXITCODE
    $txt = ($out -join ' ').Trim()
    $num = 0
    # 兼容中英文系统：中文 "远程访问错误 628"，英文 "Remote Access error 628"
    $m = [regex]::Match($txt, '(?:error|错误)\s*[:：]?\s*(\d+)', 'IgnoreCase')
    if ($m.Success) { $num = [int]$m.Groups[1].Value }
    # 已连接时 rasdial 直接返回 0，不会验证账号密码，需单独标记
    $already = ($txt -match '已连接|Connected')
    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $num; Text = $txt; AlreadyConnected = $already }
}

# ================================================================ 检测其他自动拨号任务
# 排除本工具自己的任务，以及系统自带任务（\Microsoft\Windows\ 下），
# 其余凡是动作里含 rasdial / autodial / 拨号 的任务，都视为可能冲突。
function Find-OtherAutoDialTasks {
    $found = @()
    try {
        $all = @(Get-ScheduledTask -ErrorAction Stop)
    } catch {
        return $found
    }
    foreach ($t in $all) {
        if ($t.TaskName -eq $TaskName) { continue }
        if ($t.TaskPath -like '\Microsoft\Windows\*') { continue }
        $hit = $false
        $desc = ''
        foreach ($a in $t.Actions) {
            $txt = ("" + $a.Execute + " " + $a.Arguments)
            if ($txt -match '(?i)rasdial|autodial|拨号') {
                $hit = $true
                $desc = $txt.Trim()
                break
            }
        }
        if (-not $hit -and $t.TaskName -match '(?i)autodial|拨号') {
            $hit = $true
            if ($t.Actions.Count -gt 0) { $desc = ("" + $t.Actions[0].Execute + " " + $t.Actions[0].Arguments).Trim() }
        }
        if ($hit) {
            $found += [pscustomobject]@{
                TaskName = $t.TaskName
                TaskPath = $t.TaskPath
                Action   = $desc
                State    = $t.State
            }
        }
    }
    return $found
}

# ================================================================ 功能 1：安装 / 修复
function Install-Project {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 安装 / 修复" -ForegroundColor Cyan
    Write-Host "    （任意输入处输入 b 返回主菜单）" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan

    # 已部署过时，优先走「只更新账号密码」，从根上避免重复部署
    if (Test-Installed) {
        $cur0 = Get-CurrentConfig
        Write-Host " 检测到本工具已部署过。" -ForegroundColor Yellow
        if ($cur0) {
            Write-Host ("   当前连接: " + $cur0.EntryName)
            Write-Host ("   当前账号: " + $cur0.UserName)
        }
        Write-Host ""
        Write-Host "   [1] 只更新账号密码（推荐，不会新建任何计划任务）"
        Write-Host "   [2] 重新部署（覆盖现有任务，仍然只有一个）"
        Write-Host "   [0] 取消"
        Write-Host ""
        $m = Read-Input " 请选择"
        if ($m -ne '1' -and $m -ne '2') { Write-Host " 已取消。"; return }
        if ($m -eq '1') {
            Write-Host ""
            Update-Credentials
            return
        }
        Write-Host ""
        Write-Host " 将重新部署，现有任务会被覆盖（不会产生第二个）。" -ForegroundColor Yellow
    }

    # 检查本机是否已有其他自动拨号任务，避免两个任务同时拨号互相干扰
    $others = @(Find-OtherAutoDialTasks)
    if ($others.Count -gt 0) {
        Write-Host ""
        Write-Host " 检测到本机存在其他自动拨号相关的计划任务:" -ForegroundColor Yellow
        foreach ($o in $others) {
            Write-Host ("   - " + $o.TaskName + "   [" + $o.State + "]")
            if ($o.Action) { Write-Host ("     动作: " + $o.Action) -ForegroundColor DarkGray }
        }
        Write-Host ""
        Write-Host " 这些任务可能与本工具同时拨号，导致宽带连接异常。" -ForegroundColor Yellow
        $go2 = Read-Input " 是否删除以上任务并继续安装？(y/N)"
        if ($go2 -ne 'y') {
            Write-Host ""
            Write-Host " 已取消安装。请先手动处理上述任务后重试。" -ForegroundColor Red
            return
        }
        foreach ($o in $others) {
            try {
                Unregister-ScheduledTask -TaskName $o.TaskName -TaskPath $o.TaskPath -Confirm:$false -ErrorAction Stop
                Write-Host (" 已删除任务「" + $o.TaskName + "」") -ForegroundColor Green
            } catch {
                Write-Host (" 删除任务「" + $o.TaskName + "」失败: " + $_.Exception.Message) -ForegroundColor Red
            }
        }
        Write-Host ""
    }

    Write-Host ""
    Write-Host " [1/4] 检查宽带连接..." -ForegroundColor Yellow
    # 先清除电话簿中的空白/残缺条目，避免出现在列表里
    try {
        $blank = Clear-BlankEntries
        if ($blank -gt 0) { Write-Host ("   已清除电话簿中的空白条目（" + $blank + " 行）") -ForegroundColor DarkGray }
    } catch {}
    $entries = @(Get-PppoeEntries)
    $entry = $null
    $needCreate = $false

    if ($entries.Count -eq 0) {
        Write-Host "   系统中没有 PPPoE 宽带连接，将自动创建。" -ForegroundColor Yellow
        $needCreate = $true
        $defName = Get-UniqueEntryName $DefaultEntryName
        $name = Read-Input ("   新连接名称（回车默认 " + $defName + "）")
        if (-not $name) { $name = $defName }
        $entry = $name
    } else {
        Write-Host "   已找到以下宽带连接:" -ForegroundColor Green
        for ($i = 0; $i -lt $entries.Count; $i++) { Write-Host ("     [" + ($i + 1) + "] " + $entries[$i]) }
        Write-Host "     [0] 新建一个连接"
        Write-Host ""
        $sel = Read-Input ("   请选择 [0-" + $entries.Count + "]（回车默认 1）") -AllowZero
        if (-not $sel) { $sel = '1' }
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx)) { Write-Host "   输入无效。"; return }
        if ($idx -eq 0) {
            $needCreate = $true
            $defName = Get-UniqueEntryName $DefaultEntryName
            $name = Read-Input ("   新连接名称（回车默认 " + $defName + "）")
            if (-not $name) { $name = $defName }
            $entry = $name
        } elseif ($idx -ge 1 -and $idx -le $entries.Count) {
            $entry = $entries[$idx - 1]
            Write-Host ""
            $rn = Read-Input ("   是否给该连接改名？当前名称「" + $entry + "」，直接回车跳过 (y/N)")
            if ($rn -eq 'y') {
                $newName = Read-Input "   新名称"
                if ($newName) {
                    try {
                        $entry = Rename-PppoeEntry -OldName $entry -NewName $newName
                        Write-Host ("   已改名为「" + $entry + "」") -ForegroundColor Green
                    } catch {
                        Write-Host ("   改名失败: " + $_.Exception.Message) -ForegroundColor Red
                        Write-Host ("   将继续使用原名「" + $entry + "」") -ForegroundColor Yellow
                    }
                }
            }
        } else {
            Write-Host "   序号超出范围。"; return
        }
    }

    Write-Host ""
    Write-Host " [2/4] 输入宽带账号密码" -ForegroundColor Yellow
    $user = Read-Input "   宽带账号"
    if (-not $user) { Write-Host "   账号不能为空。"; return }
    $pass = Read-Password "   宽带密码"
    if (-not $pass) { Write-Host "   密码不能为空。"; return }

    Write-Host ""
    Write-Host " [3/4] 准备连接与凭据" -ForegroundColor Yellow

    if ($needCreate) {
        try {
            $port = New-PppoeEntry -Name $entry -UserName $user
            Write-Host ("   已创建连接「" + $entry + "」，端口 " + $port) -ForegroundColor Green
            # 打上「本工具创建」标记，卸载时据此删除；用户原有连接不会被打标记
            Add-CreatedMarker $entry
        } catch {
            Write-Host ("   创建连接失败: " + $_.Exception.Message) -ForegroundColor Red
            return
        }
    } else {
        Write-Host ("   使用现有连接「" + $entry + "」") -ForegroundColor Green
        # 该连接若不在标记列表中，说明是用户自己的，卸载时不会删除
        if (@(Get-CreatedMarkers) -notcontains $entry) {
            Write-Host "   该连接由你自行创建，卸载时不会被删除。" -ForegroundColor DarkGray
        }
    }

    $rc = Set-RasCredentials -EntryName $entry -UserName $user -Password $pass
    $vf = Test-RasCredentials -EntryName $entry -UserName $user
    if ($rc -eq 0 -and $vf.Ok) {
        Write-Host "   账号密码已保存到该连接（手动拨号不必再输密码）" -ForegroundColor Green
    } elseif ($rc -eq 0) {
        # 回读为空在部分系统上是 API 限制，不代表一定没保存，措辞保持中性
        Write-Host "   凭据回读未返回内容，无法确认是否已保存（部分系统存在此限制）。" -ForegroundColor DarkGray
        Write-Host "   这不影响自动拨号；仅影响手动拨号时是否需要输入密码。" -ForegroundColor DarkGray
        Write-Host "   如需确认：断开连接后点任务栏「连接」，不弹密码框即表示已保存。" -ForegroundColor DarkGray
    } else {
        Write-Host ("   凭据写入返回码 " + $rc + "，未能保存到连接。") -ForegroundColor Yellow
        Write-Host "   这不影响自动拨号；手动拨号时会被要求输入密码。" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host " [4/4] 部署守护脚本与计划任务" -ForegroundColor Yellow

    try {
        Write-GuardScript -EntryName $entry -UserName $user -Password $pass
        Write-Host ("   守护脚本: " + $GuardPath) -ForegroundColor Green
    } catch {
        Write-Host ("   写入守护脚本失败: " + $_.Exception.Message) -ForegroundColor Red
        return
    }

    try {
        $exe  = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $arg  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $GuardPath + '"'
        $action = New-ScheduledTaskAction -Execute $exe -Argument $arg

        $tBoot  = New-ScheduledTaskTrigger -AtStartup
        $tLogon = New-ScheduledTaskTrigger -AtLogOn

        $cSession = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $tUnlock = New-CimInstance -CimClass $cSession -ClientOnly
        $tUnlock.Enabled = $true
        $tUnlock.StateChange = 8

        $logName = 'Microsoft-Windows-NetworkProfile/Operational'
        $sub = '<QueryList><Query Id="0" Path="' + $logName + '"><Select Path="' + $logName + '">' +
               "*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10001]]" +
               '</Select></Query></QueryList>'
        $cEvent = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $tEvent = New-CimInstance -CimClass $cEvent -ClientOnly
        $tEvent.Enabled = $true
        $tEvent.Subscription = $sub
        $tEvent.Delay = 'PT10S'

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -RestartCount 3 `
                        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

        $userId    = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -Action $action `
            -Trigger @($tBoot, $tLogon, $tUnlock, $tEvent) `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
        Write-Host ("   计划任务: " + $TaskName) -ForegroundColor Green
    } catch {
        Write-Host ("   创建任务失败: " + $_.Exception.Message) -ForegroundColor Red
        return
    }

    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ""
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 安装完成                                   弥琉 · QQ 458423691" -ForegroundColor Green
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    if ($t) {
        Write-Host (" 任务状态 : " + $t.State)
        Write-Host (" 触发器   : " + @($t.Triggers).Count + " 个（开机/登录/解锁/断线）")
        Write-Host (" 运行身份 : " + $t.Principal.UserId + " / " + $t.Principal.LogonType + " / " + $t.Principal.RunLevel)
        Write-Host (" 连接     : " + $entry)
        Write-Host (" 账号     : " + $user)
        Write-Host (" 日志     : " + $LogPath)

        # 逐项校验，避免"看起来装好了其实缺件"
        $problems = @()
        if (@($t.Triggers).Count -ne 4) { $problems += ("触发器数量应为 4，实际 " + @($t.Triggers).Count) }
        if ($t.Principal.LogonType -ne 'S4U') { $problems += ("运行身份应为 S4U，实际 " + $t.Principal.LogonType) }
        if (-not (Test-Path $GuardPath)) { $problems += "守护脚本未落盘" }
        # 确认本机只有这一个自动拨号任务，避免重复拨号
        $dup = @(Find-OtherAutoDialTasks)
        if ($dup.Count -gt 0) { $problems += ("仍存在 " + $dup.Count + " 个其他自动拨号任务，可能重复拨号") }
        if ($problems.Count -gt 0) {
            Write-Host ""
            Write-Host " 警告: 以下项目未达预期" -ForegroundColor Yellow
            $problems | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Yellow }
        } else {
            Write-Host ""
            Write-Host " 自检通过：触发器 4 个 / S4U 身份 / 守护脚本就位" -ForegroundColor Green
        }
    }

    Write-Host ""
    $test = Read-Input " 现在拨号测试一次？(y/N)"
    if ($test -eq 'y') {
        Write-Host " 正在拨号..."
        $r = Invoke-TestDial -EntryName $entry -UserName $user -Password $pass
        # 623 = 拨号服务尚未加载新电话簿，等待后重试一次
        if (-not $r.Ok -and $r.Code -eq 623) {
            Write-Host " 拨号服务尚未加载新连接，等待 3 秒重试..."
            Start-Sleep -Seconds 3
            $r = Invoke-TestDial -EntryName $entry -UserName $user -Password $pass
        }
        if ($r.Ok -and $r.AlreadyConnected) {
            Write-Host " 该连接当前已处于连接状态，本次测试未真正验证账号密码。" -ForegroundColor Yellow
            Write-Host " 如需完整验证，请先断开该连接再测试。" -ForegroundColor DarkGray
        } elseif ($r.Ok) {
            Write-Host " 拨号成功，账号密码有效。" -ForegroundColor Green
            $st = & rasdial 2>&1
            $st | ForEach-Object { if ("$_".Trim()) { Write-Host ("   " + $_) } }
        } else {
            Write-Host (" 拨号失败，RAS 错误码 " + $r.Code) -ForegroundColor Red
            Write-Host ("   " + $r.Text)
            Write-Host ""
            Write-Host " 排查建议:" -ForegroundColor Yellow
            Write-Host "   623 -> 拨号服务未重新加载电话簿（刚新建的连接常见）"
            Write-Host "          重启电脑后即可，或稍等几秒再试"
            Write-Host "   628 -> 账号密码错误，或运营商侧拒绝"
            Write-Host "   691 -> 认证被拒，账号密码不正确或欠费停机"
            Write-Host "   651 -> 网卡/PPPoE 端口问题（多为端口索引不匹配）"
            Write-Host "   678 -> 线路无响应（光猫未就绪或未桥接）"
            Write-Host "   769 -> 指定的目标不可达（网卡未连接网线）"
        }
    }
}

# ================================================================ 功能 2：改账号密码
function Update-Credentials {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 修改宽带账号密码" -ForegroundColor Cyan
    Write-Host "    （任意输入处输入 b 返回主菜单）" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan

    if (-not (Test-Installed)) {
        Write-Host " 尚未安装，请先执行选项 1。" -ForegroundColor Red
        return
    }

    $cur = Get-CurrentConfig
    if (-not $cur) {
        Write-Host " 守护脚本缺失，读不到当前配置。" -ForegroundColor Red
        Write-Host " 请先用选项 [1] 修复安装，再修改账号密码。" -ForegroundColor Yellow
        return
    }
    Write-Host (" 当前连接 : " + $cur.EntryName)
    Write-Host (" 当前账号 : " + $cur.UserName)
    Write-Host ""

    $entry = Read-Input (" 新连接名（回车沿用 " + $cur.EntryName + "）")
    if (-not $entry) { $entry = $cur.EntryName }

    # 连接必须真实存在，否则凭据写不进去，守护脚本会指向不存在的连接
    if (@(Get-PppoeEntries) -notcontains $entry) {
        Write-Host ""
        Write-Host (" 电话簿中不存在连接「" + $entry + "」，无法修改。") -ForegroundColor Red
        Write-Host " 请确认名称是否输入正确，或用菜单 [1] 安装时新建该连接。" -ForegroundColor Yellow
        return
    }

    $user = Read-Input (" 新账号（回车沿用 " + $cur.UserName + "）")
    if (-not $user) { $user = $cur.UserName }
    $pass = Read-Password " 新密码（回车沿用原密码）"
    if (-not $pass) { $pass = $cur.Password }

    $rc = Set-RasCredentials -EntryName $entry -UserName $user -Password $pass
    $vf = Test-RasCredentials -EntryName $entry -UserName $user
    if ($rc -eq 0 -and $vf.Ok) {
        Write-Host " 连接凭据已同步并校验通过。" -ForegroundColor Green
    } elseif ($rc -eq 0) {
        Write-Host " 凭据已提交，但回读未返回内容（部分系统存在此限制）。" -ForegroundColor DarkGray
        Write-Host " 自动拨号不受影响；手动拨号可能仍需输入密码。" -ForegroundColor DarkGray
    } else {
        Write-Host (" 凭据写入返回码 " + $rc + "，未保存到连接。") -ForegroundColor Yellow
        Write-Host " 自动拨号不受影响；手动拨号会被要求输入密码。" -ForegroundColor DarkGray
    }

    try {
        Write-GuardScript -EntryName $entry -UserName $user -Password $pass
        Write-Host ""
        Write-Host " 已更新守护脚本。" -ForegroundColor Green
        Write-Host ("   连接 : " + $entry)
        Write-Host ("   账号 : " + $user)
        Write-Host " 下次触发时生效，当前连接不受影响。" -ForegroundColor DarkGray
    } catch {
        Write-Host (" 写入失败: " + $_.Exception.Message) -ForegroundColor Red
    }
}

# ================================================================ 功能 3：卸载
function Uninstall-Project {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 一键卸载" -ForegroundColor Cyan
    Write-Host "    （任意输入处输入 b 返回主菜单）" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan

    if (-not (Test-Installed)) {
        Write-Host " 未检测到任何安装痕迹，无需卸载。" -ForegroundColor Yellow
        return
    }

    # 顺带清除电话簿中的空白/残缺条目
    try {
        $blank = Clear-BlankEntries
        if ($blank -gt 0) { Write-Host (" 已清除电话簿中的空白条目（" + $blank + " 行）") -ForegroundColor DarkGray }
    } catch {}

    $st = Get-InstallState
    # 必须在删除安装目录之前读取标记（可能记录了多条连接）
    $marks = @(Get-CreatedMarkers)
    $existingAll = @(Get-PppoeEntries)
    $mkList = @($marks | Where-Object { $existingAll -contains $_ })

    # 检查这些连接是否正在使用
    $mkInUse = @()
    foreach ($n in $mkList) {
        try {
            $ad = Get-NetAdapter -Name $n -ErrorAction SilentlyContinue
            if ($ad -and $ad.Status -eq 'Up') { $mkInUse += $n }
        } catch {}
    }

    Write-Host " 检测到的安装痕迹:" -ForegroundColor Yellow
    Write-Host ("   计划任务 : " + $(if ($st.Task) { '存在' } else { '不存在' }))
    Write-Host ("   安装目录 : " + $(if ($st.Dir)  { $InstallDir } else { '不存在' }))
    Write-Host ("   守护脚本 : " + $(if ($st.Script) { '存在' } else { '不存在（目录可能被误删）' }))
    if ($mkList.Count -gt 0) {
        Write-Host "   宽带连接 : 以下由本工具创建，将一并删除" -ForegroundColor Yellow
        foreach ($n in $mkList) {
            $suffix = if ($mkInUse -contains $n) { '  ← 当前正在使用' } else { '' }
            Write-Host ("              - " + $n + $suffix) -ForegroundColor Yellow
        }
    } else {
        Write-Host "   宽带连接 : 无本工具创建的连接，不会删除任何连接"
    }
    Write-Host ""
    if (-not $st.Complete) {
        Write-Host " 注意: 安装状态不完整，将清理所有已存在的部分。" -ForegroundColor Yellow
    }

    # 正在使用的连接不代为断开：若它承载远程会话，断开会让用户当场失联
    if ($mkInUse.Count -gt 0) {
        Write-Host " 以下连接当前正在使用中，无法删除:" -ForegroundColor Red
        $mkInUse | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
        Write-Host ""
        Write-Host " 请先手动断开，再重新执行卸载：" -ForegroundColor Yellow
        Write-Host "   方式一: 点任务栏右下角网络图标 -> 选中该连接 -> 断开" -ForegroundColor Yellow
        Write-Host "   方式二: 设置 -> 网络和 Internet -> 拨号 -> 选中该连接 -> 断开" -ForegroundColor Yellow
        Write-Host ""
        Write-Host " 本次未做任何改动。" -ForegroundColor DarkGray
        return
    }

    if ($mkList.Count -gt 0) {
        if ($mkList.Count -ge $existingAll.Count) {
            Write-Host " 警告: 将删除系统中所有宽带连接，删除后本机将无法拨号上网！" -ForegroundColor Red
        }
        Write-Host " 将删除上述宽带连接。你原有的其他连接一律不动。"
    } else {
        Write-Host " 不会删除任何宽带连接。"
    }
    Write-Host ""
    $go = Read-Input " 确认卸载？(y/N)"
    if ($go -ne 'y') { Write-Host " 已取消。"; return }

    # 删除本工具创建的全部宽带连接（标记列表中且电话簿中确实存在的）
    # 前面已确认这些连接未在使用中，这里不再代为断开
    if ($mkList.Count -gt 0) {
        foreach ($n in $mkList) {
            try {
                $removed = Remove-PppoeEntry -Name $n
                if ($removed) {
                    Write-Host (" 已删除宽带连接「" + $n + "」") -ForegroundColor Green
                } else {
                    Write-Host (" 电话簿中未找到「" + $n + "」，可能已被手动删除") -ForegroundColor Yellow
                }
            } catch {
                Write-Host (" 删除宽带连接失败「" + $n + "」: " + $_.Exception.Message) -ForegroundColor Red
            }
        }
        Clear-CreatedMarker
    }

    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $env:USERPROFILE ("Desktop\自动拨号宽带-备份-" + $stamp + ".xml")
    try {
        Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-File -FilePath $backup -Encoding utf8
        Write-Host (" 任务已备份: " + $backup) -ForegroundColor Green
    } catch {
        Write-Host (" 备份失败（继续）: " + $_.Exception.Message) -ForegroundColor Yellow
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host " 计划任务已删除。" -ForegroundColor Green
    } catch {
        Write-Host (" 删除任务失败: " + $_.Exception.Message) -ForegroundColor Red
    }

    if (Test-Path $InstallDir) {
        $gone = $false
        for ($try = 1; $try -le 3; $try++) {
            try {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
                $gone = $true
                break
            } catch {
                Start-Sleep -Seconds 1
            }
        }
        if ($gone -and -not (Test-Path $InstallDir)) {
            Write-Host " 安装目录已删除（含守护脚本、日志、状态、标记文件）。" -ForegroundColor Green
        } else {
            Write-Host (" 删除目录失败，可能被占用。重启后再执行一次卸载，或手动删除: " + $InstallDir) -ForegroundColor Yellow
        }
    } else {
        Write-Host " 安装目录已不存在。" -ForegroundColor Green
    }

    # 清理本工具产生的其他附属文件（电话簿备份、临时释放的安装脚本）
    $n = Clear-ToolArtifacts
    if ($n -gt 0) {
        Write-Host (" 已清理附属文件 " + $n + " 个（电话簿备份 / 临时安装脚本）。") -ForegroundColor Green
    }

    # 最终核对：确认没有残留
    Write-Host ""
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 残留检查" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    $left = @()
    if ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { $left += ("计划任务 " + $TaskName) }
    if (Test-Path $InstallDir) { $left += ("目录 " + $InstallDir) }
    $pbkDir = Split-Path -Parent $PbkPath
    if (Test-Path $pbkDir) {
        $bk = @(Get-ChildItem -LiteralPath $pbkDir -Filter 'rasphone.pbk.bak-*' -File -ErrorAction SilentlyContinue)
        if ($bk.Count -gt 0) { $left += ("电话簿备份 " + $bk.Count + " 个") }
    }
    if (Test-Path (Join-Path $env:TEMP 'AutoDialSetup.ps1')) { $left += "临时安装脚本" }

    if ($left.Count -eq 0) {
        Write-Host " 未发现残留，清理完成。" -ForegroundColor Green
    } else {
        Write-Host " 以下项目未能清除，建议重启后重新卸载或手动处理:" -ForegroundColor Yellow
        $left | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host " 卸载完成。                        弥琉 · QQ 458423691" -ForegroundColor Green
}

# ================================================================ 清理本工具产生的附属文件
function Clear-ToolArtifacts {
    $cleaned = 0

    # 1. 电话簿备份（本工具在新建/改名/删除连接时生成，命名规则固定）
    $pbkDir = Split-Path -Parent $PbkPath
    if (Test-Path $pbkDir) {
        Get-ChildItem -LiteralPath $pbkDir -Filter 'rasphone.pbk.bak-*' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $cleaned++ } catch {}
            }
    }

    # 2. 安装器临时释放的脚本
    $tmpPs1 = Join-Path $env:TEMP 'AutoDialSetup.ps1'
    if (Test-Path $tmpPs1) {
        try { Remove-Item -LiteralPath $tmpPs1 -Force -ErrorAction Stop; $cleaned++ } catch {}
    }

    return $cleaned
}

# ================================================================ 删除指定宽带连接
function Remove-ConnectionInteractive {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 删除指定宽带连接" -ForegroundColor Cyan
    Write-Host "    （任意输入处输入 b 返回主菜单）" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan

    $sections = @(Get-AllSections)
    if ($sections.Count -eq 0) {
        Write-Host " 系统中没有宽带连接。" -ForegroundColor Yellow
        return
    }

    $marks = @(Get-CreatedMarkers)
    Write-Host " 现有宽带连接:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $s = $sections[$i]
        $disp = if ($s.Name) { $s.Name } else { '(无名称)' }
        if (-not $s.Valid) {
            Write-Host ("   [" + ($i + 1) + "] " + $disp + "   （空白条目，选中后将被清除）") -ForegroundColor DarkYellow
        } elseif ($marks -contains $s.Name) {
            Write-Host ("   [" + ($i + 1) + "] " + $disp + "   （本工具创建）")
        } else {
            Write-Host ("   [" + ($i + 1) + "] " + $disp)
        }
    }
    Write-Host ""
    Write-Host " 可输入多个序号，用逗号分隔，例如 1,3" -ForegroundColor DarkGray
    Write-Host " 直接回车 = 取消，不做任何删除" -ForegroundColor DarkGray
    Write-Host ""

    $sel = Read-Input " 请选择要删除的连接"
    if (-not $sel) { Write-Host " 已取消。"; return }

    $pickedIdx = @()
    foreach ($t in ($sel -split '[,，\s]+')) {
        if (-not $t.Trim()) { continue }
        $idx = 0
        if ([int]::TryParse($t.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $sections.Count) {
            $pickedIdx += ($idx - 1)
        }
    }
    $pickedIdx = @($pickedIdx | Select-Object -Unique)
    if ($pickedIdx.Count -eq 0) { Write-Host " 未选择有效序号，已取消。"; return }

    # ---------- 先分离出空白条目 ----------
    $blankIdx = @($pickedIdx | Where-Object { -not $sections[$_].Valid })
    $validIdx = @($pickedIdx | Where-Object { $sections[$_].Valid })

    if ($blankIdx.Count -gt 0) {
        Write-Host ""
        Write-Host " 你选中的以下条目是空白条目（无效），将被直接清除:" -ForegroundColor Yellow
        foreach ($bi in $blankIdx) {
            $disp = if ($sections[$bi].Name) { $sections[$bi].Name } else { '(无名称)' }
            Write-Host ("   - " + $disp) -ForegroundColor DarkYellow
        }
        Write-Host ""
        # 连续三次复核，全部确认无效才删除，避免误判
        $confirmed = @()
        foreach ($bi in $blankIdx) {
            $okCount = 0
            for ($c = 1; $c -le 3; $c++) {
                if (Test-SectionInvalid -Position $bi -ExpectedName $sections[$bi].Name) { $okCount++ }
                Start-Sleep -Milliseconds 150
            }
            if ($okCount -ge 3) {
                $confirmed += $bi
            } else {
                $disp = if ($sections[$bi].Name) { $sections[$bi].Name } else { '(无名称)' }
                Write-Host (" 「" + $disp + "」复核未通过（状态不稳定），已跳过，未删除。") -ForegroundColor Yellow
            }
        }
        foreach ($bi in $confirmed) {
            $nm = $sections[$bi].Name
            $disp = if ($nm) { $nm } else { '(无名称)' }
            try {
                $r = Remove-PppoeEntry -Name $nm
                if ($r) { Write-Host (" 已清除空白条目「" + $disp + "」") -ForegroundColor Green }
                else { Write-Host (" 清除空白条目「" + $disp + "」失败：未找到该段落") -ForegroundColor Yellow }
            } catch {
                Write-Host (" 清除空白条目「" + $disp + "」失败: " + $_.Exception.Message) -ForegroundColor Red
            }
        }
    }

    if ($validIdx.Count -eq 0) {
        Write-Host ""
        Write-Host " 没有需要删除的正常连接。" -ForegroundColor DarkGray
        return
    }

    $targets = @($validIdx | ForEach-Object { $sections[$_].Name })
    $validTotal = @($sections | Where-Object { $_.Valid }).Count

    # 正在使用中的连接不允许删除，也不代为断开。
    # 若该连接正承载远程会话，贸然断开会让用户当场失联。
    $inUse = @()
    foreach ($name in $targets) {
        try {
            $ad = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
            if ($ad -and $ad.Status -eq 'Up') { $inUse += $name }
        } catch {}
    }
    if ($inUse.Count -gt 0) {
        Write-Host ""
        Write-Host " 以下连接正在使用中，不能删除:" -ForegroundColor Red
        $inUse | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
        Write-Host ""
        Write-Host " 请先手动断开，再回来执行删除：" -ForegroundColor Yellow
        Write-Host "   方式一: 点任务栏右下角网络图标 -> 选中该连接 -> 断开" -ForegroundColor Yellow
        Write-Host "   方式二: 设置 -> 网络和 Internet -> 拨号 -> 选中该连接 -> 断开" -ForegroundColor Yellow
        Write-Host ""
        Write-Host " 本次未做任何改动。" -ForegroundColor DarkGray
        return
    }

    Write-Host ""
    Write-Host " 即将永久删除以下连接:" -ForegroundColor Red
    $targets | ForEach-Object { Write-Host ("   - " + $_) -ForegroundColor Red }
    Write-Host ""
    if ($targets.Count -ge $validTotal) {
        Write-Host " 警告: 这是系统中最后一条宽带连接！" -ForegroundColor Red
        Write-Host " 删除后本机将没有任何宽带连接，无法拨号上网。" -ForegroundColor Red
        Write-Host " 如需重新上网，必须重新创建连接并输入账号密码。" -ForegroundColor Red
        Write-Host ""
    }
    Write-Host " 此操作会从电话簿中移除该连接，账号密码一并清除。" -ForegroundColor Yellow
    Write-Host " 电话簿会自动备份到同目录（.bak-时间戳）。" -ForegroundColor DarkGray
    Write-Host ""
    $go = Read-Input " 确认删除？输入大写 YES 继续"
    if ($go -ne 'YES') { Write-Host " 已取消。"; return }

    foreach ($name in $targets) {
        try {
            $ok = Remove-PppoeEntry -Name $name
            if ($ok) {
                Write-Host (" 已删除「" + $name + "」") -ForegroundColor Green
                if ($marks -contains $name) { Remove-CreatedMarker $name }
            } else {
                Write-Host (" 未找到「" + $name + "」") -ForegroundColor Yellow
            }
        } catch {
            Write-Host (" 删除「" + $name + "」失败: " + $_.Exception.Message) -ForegroundColor Red
        }
    }
}

# ================================================================ 仅新增宽带账号
# 只创建/更新宽带连接并保存凭据，不部署任何计划任务或守护脚本。
function Add-AccountOnly {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 仅新增宽带账号（不安装自动拨号）" -ForegroundColor Cyan
    Write-Host "    （任意输入处输入 b 返回主菜单）" -ForegroundColor DarkGray
    Write-Host "                                    by 弥琉  QQ 458423691" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 本选项只创建/更新宽带连接并保存账号密码。" -ForegroundColor DarkGray
    Write-Host " 不会安装计划任务，不会产生任何自动拨号行为。" -ForegroundColor DarkGray
    Write-Host ""

    if (Test-Installed) {
        Write-Host " 提示: 本机已安装自动拨号，本选项不会修改现有配置。" -ForegroundColor Yellow
        Write-Host " 如需更换自动拨号使用的账号，请用菜单 [2]。"
        Write-Host ""
    }

    # 清理空白条目后再列出现有连接
    try { [void](Clear-BlankEntries) } catch {}

    $entries = @(Get-PppoeEntries)
    Write-Host " 现有宽带连接:" -ForegroundColor Yellow
    if ($entries.Count -eq 0) {
        Write-Host "   （无）" -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $entries.Count; $i++) { Write-Host ("   [" + ($i + 1) + "] " + $entries[$i]) }
    }
    Write-Host "   [0] 新建一个连接"
    Write-Host ""
    $sel = Read-Input (" 请选择 [0-" + $entries.Count + "]（回车默认 0）") -AllowZero
    if (-not $sel) { $sel = '0' }
    $idx = -1
    if (-not [int]::TryParse($sel, [ref]$idx)) { Write-Host " 输入无效。"; return }
    if ($idx -lt 0 -or $idx -gt $entries.Count) { Write-Host " 序号超出范围。"; return }

    $needCreate = ($idx -eq 0)
    if ($needCreate) {
        $defName = Get-UniqueEntryName $DefaultEntryName
        $name = Read-Input (" 新连接名称（回车默认 " + $defName + "）")
        if (-not $name) { $name = $defName }
        $entry = $name
    } else {
        $entry = $entries[$idx - 1]
    }

    Write-Host ""
    $user = Read-Input " 宽带账号"
    if (-not $user) { Write-Host " 账号不能为空。"; return }
    $pass = Read-Password " 宽带密码"
    if (-not $pass) { Write-Host " 密码不能为空。"; return }

    Write-Host ""
    if ($needCreate) {
        try {
            $port = New-PppoeEntry -Name $entry -UserName $user
            Write-Host (" 已创建连接「" + $entry + "」，端口 " + $port) -ForegroundColor Green
            # 本工具创建的连接一律登记，卸载时一并删除
            Add-CreatedMarker $entry
        } catch {
            Write-Host (" 创建连接失败: " + $_.Exception.Message) -ForegroundColor Red
            return
        }
    } else {
        Write-Host (" 使用现有连接「" + $entry + "」") -ForegroundColor Green
        if (@(Get-CreatedMarkers) -notcontains $entry) {
            Write-Host " 该连接由你自行创建，卸载时不会被删除。" -ForegroundColor DarkGray
        }
    }

    $rc = Set-RasCredentials -EntryName $entry -UserName $user -Password $pass
    $vf = Test-RasCredentials -EntryName $entry -UserName $user
    if ($rc -eq 0 -and $vf.Ok) {
        Write-Host " 账号密码已保存到该连接。" -ForegroundColor Green
    } elseif ($rc -eq 0) {
        Write-Host " 凭据已提交，但回读未返回内容（部分系统存在此限制）。" -ForegroundColor DarkGray
        Write-Host " 手动拨号时可能仍需输入密码。" -ForegroundColor DarkGray
    } else {
        Write-Host (" 凭据写入返回码 " + $rc + "，未能保存。") -ForegroundColor Yellow
        Write-Host " 手动拨号时会被要求输入密码。" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host " 账号已添加                        弥琉 · QQ 458423691" -ForegroundColor Green
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host (" 连接 : " + $entry)
    Write-Host (" 账号 : " + $user)
    Write-Host ""
    Write-Host " 该连接仅供手动拨号使用，未安装任何自动拨号配置。" -ForegroundColor DarkGray
    if (@(Get-CreatedMarkers) -contains $entry) {
        Write-Host " 此连接已登记为本工具创建，卸载时会一并删除。" -ForegroundColor DarkGray
    } else {
        Write-Host " 提示: 此连接由你自行创建，卸载时不会被删除。" -ForegroundColor DarkGray
    }
}

# ================================================================ 查看当前状态
function Show-Status {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 当前状态"
    Write-Host "                                    by 弥琉  QQ 458423691" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan

    Write-Host " 计划任务:" -ForegroundColor Yellow
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        Write-Host ("   状态     : " + $t.State)
        Write-Host ("   触发器   : " + @($t.Triggers).Count + " 个")
        Write-Host ("   运行身份 : " + $t.Principal.UserId + " / " + $t.Principal.LogonType + " / " + $t.Principal.RunLevel)
        $i = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($i) {
            Write-Host ("   上次运行 : " + $i.LastRunTime)
            $r = if ($i.LastTaskResult -eq 0) { "0（成功）" } else { [string]$i.LastTaskResult }
            Write-Host ("   上次结果 : " + $r)
        }
    } else {
        Write-Host "   未安装" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host " 宽带连接:" -ForegroundColor Yellow
    $cur = Get-CurrentConfig
    if ($cur) {
        Write-Host ("   连接 : " + $cur.EntryName)
        Write-Host ("   账号 : " + $cur.UserName)
        $marks = @(Get-CreatedMarkers)
        if ($marks.Count -gt 0) { Write-Host ("   标记 : " + ($marks -join ', ') + "（由本工具创建）") }
        try {
            $ad = Get-NetAdapter -Name $cur.EntryName -ErrorAction SilentlyContinue
            Write-Host ("   状态 : " + $(if ($ad -and $ad.Status -eq 'Up') { '已连接' } else { '未连接' }))
        } catch {}
    } else {
        Write-Host "   未安装" -ForegroundColor DarkGray
    }
    Write-Host ""

    Write-Host " 运行日志（最近 8 行）:" -ForegroundColor Yellow
    if (Test-Path $LogPath) {
        $tail = @(Get-Content -LiteralPath $LogPath -Encoding UTF8 -Tail 8 -ErrorAction SilentlyContinue)
        if ($tail.Count -eq 0) { Write-Host "   （空）" -ForegroundColor DarkGray }
        else { $tail | ForEach-Object { Write-Host ("   " + $_) -ForegroundColor DarkGray } }
    } else {
        Write-Host "   （暂无日志，说明尚未触发过）" -ForegroundColor DarkGray
    }
}

# ================================================================ 菜单
while ($true) {
    $st = Get-InstallState
    if ($st.Complete) { $status = "已安装" }
    elseif ($st.Task -or $st.Dir) { $status = "安装不完整（建议用 [1] 修复）" }
    else { $status = "未安装" }

    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host "  宽带自动拨号 · 部署工具" -ForegroundColor Cyan
    Write-Host "                                    by 弥琉  QQ 458423691" -ForegroundColor DarkGray
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host ("  当前状态: " + $status) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   [1] 安装 / 修复（全自动，只需输入账号密码）"
    Write-Host "   [2] 修改宽带账号密码"
    Write-Host "   [3] 一键卸载（清除本工具创建的全部内容）"
    Write-Host "   [4] 删除指定宽带连接（手动选择，谨慎使用）"
    Write-Host "   [5] 仅新增宽带账号（不安装自动拨号）"
    Write-Host "   [6] 查看当前状态（诊断用）"
    Write-Host "   [0] 退出"
    Write-Host ""
    $choice = Read-Host " 请输入选项编号"

    # 子流程中任意输入处输入 b 会抛出返回信号，在这里统一捕获并回到主菜单
    try {
        switch ($choice) {
            '1' { Install-Project }
            '2' { Update-Credentials }
            '3' { Uninstall-Project }
            '4' { Remove-ConnectionInteractive }
            '5' { Add-AccountOnly }
            '6' { Show-Status }
            '0' { Write-Host "`n 已退出。"; break }
            default { Write-Host " 无效选项，请输入 0-6。" -ForegroundColor Yellow }
        }
    } catch {
        if ($_.Exception.Message -eq $script:BackSignal) {
            Write-Host ""
            Write-Host " 已返回主菜单。" -ForegroundColor DarkGray
        } else {
            Write-Host ""
            Write-Host (" 操作中断: " + $_.Exception.Message) -ForegroundColor Red
        }
    }
    if ($choice -eq '0') { break }
}

if (-not $NoPause) { Read-Host "按回车关闭窗口" }

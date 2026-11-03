<#
.SYNOPSIS
    将 src/Install-AutoDial.ps1 打包为单文件 dist/宽带自动拨号.bat

.DESCRIPTION
    把 PowerShell 源码以 Base64 内嵌到批处理文件中，用户只需一个文件即可运行。
    生成过程保证：
      · 批处理部分为纯 ASCII（不受代码页影响）
      · 行尾为 CRLF（批处理的标签跳转对行尾敏感）
      · 载荷与源码字节完全一致

.PARAMETER Source
    源码路径，默认 src/Install-AutoDial.ps1

.PARAMETER Output
    输出路径，默认 dist/宽带自动拨号.bat

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File build\Build-SingleFile.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 param 默认值阶段可能为空，这里在函数体内解析
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Source) { $Source = Join-Path $here '..\src\Install-AutoDial.ps1' }
if (-not $Output) { $Output = Join-Path $here '..\dist\宽带自动拨号.bat' }

function Write-Step([string]$Msg) { Write-Host ("[BUILD] " + $Msg) -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host ("        " + $Msg) -ForegroundColor Green }
function Write-Bad([string]$Msg)  { Write-Host ("        " + $Msg) -ForegroundColor Red }

# ---- 1. 检查输入 ----
if (-not (Test-Path $Source)) { Write-Bad "找不到源码: $Source"; exit 1 }
$headerPath = Join-Path $PSScriptRoot 'bat_header.txt'
if (-not (Test-Path $headerPath)) { Write-Bad "找不到批处理头: $headerPath"; exit 1 }

$srcBytes = [System.IO.File]::ReadAllBytes($Source)
Write-Step ("源码: " + $Source + "  (" + $srcBytes.Length + " 字节)")

# 源码必须是 UTF-8 带 BOM，否则 PowerShell 5.1 会把中文读成乱码
if (-not ($srcBytes.Length -ge 3 -and $srcBytes[0] -eq 0xEF -and $srcBytes[1] -eq 0xBB -and $srcBytes[2] -eq 0xBF)) {
    Write-Bad "源码缺少 UTF-8 BOM，中文会乱码。请另存为「UTF-8 带 BOM」。"
    exit 1
}
Write-Ok "编码检查通过（UTF-8 带 BOM）"

# 语法检查
$parseErr = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$null, [ref]$parseErr)
if ($parseErr -and $parseErr.Count -gt 0) {
    Write-Bad ("源码语法错误 " + $parseErr.Count + " 处：")
    $parseErr | ForEach-Object { Write-Host ("          " + $_.Message + " @行 " + $_.Extent.StartLineNumber) }
    exit 1
}
Write-Ok "语法检查通过"

# ---- 2. 生成载荷 ----
$b64 = [Convert]::ToBase64String($srcBytes)
$chunkSize = 120
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $b64.Length - $i)
    [void]$sb.AppendLine('::' + $b64.Substring($i, $len))
}
Write-Step ("载荷: " + $b64.Length + " 字符 / " + $sb.ToString().Split("`n").Count + " 行")

# ---- 3. 拼装并写盘（CRLF + ASCII）----
$headerText = [System.IO.File]::ReadAllText($headerPath, [System.Text.Encoding]::UTF8)
$headerText = $headerText -replace "`r`n", "`n"
$headerText = $headerText -replace "`n", "`r`n"
if (-not $headerText.EndsWith("`r`n")) { $headerText += "`r`n" }

$payload = $sb.ToString() -replace "`r`n", "`n"
$payload = $payload -replace "`n", "`r`n"

$outDir = Split-Path -Parent $Output
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($Output, ($headerText + $payload), (New-Object System.Text.ASCIIEncoding))
Write-Step ("输出: " + $Output + "  (" + (Get-Item $Output).Length + " 字节)")

# ---- 4. 自检 ----
$outBytes = [System.IO.File]::ReadAllBytes($Output)
$nonAscii = @($outBytes | Where-Object { $_ -gt 127 }).Count
if ($nonAscii -gt 0) { Write-Bad ("含 " + $nonAscii + " 个非 ASCII 字节"); exit 1 }
Write-Ok "纯 ASCII 检查通过"

$lines = [System.IO.File]::ReadAllLines($Output, [System.Text.Encoding]::ASCII)
$idx = [Array]::IndexOf($lines, '::#PAYLOAD#')
if ($idx -lt 0) { Write-Bad "载荷标记行缺失"; exit 1 }

$parts = @()
for ($k = $idx + 1; $k -lt $lines.Count; $k++) {
    $s = $lines[$k]
    if ($s.Length -gt 2) { $parts += $s.Substring(2) }
}
$decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($parts -join ''))).TrimStart([char]0xFEFF)
$tmp = [System.IO.Path]::GetTempFileName()
[System.IO.File]::WriteAllText($tmp, $decoded, (New-Object System.Text.UTF8Encoding($true)))
$back = [System.IO.File]::ReadAllBytes($tmp)
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ([Convert]::ToBase64String($srcBytes) -ne [Convert]::ToBase64String($back)) {
    Write-Bad "提取结果与源码不一致"
    exit 1
}
Write-Ok "往返一致性检查通过"

Write-Host ""
Write-Host ("构建完成，可以分发: " + $Output) -ForegroundColor Green

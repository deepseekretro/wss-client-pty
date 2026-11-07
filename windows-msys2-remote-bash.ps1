<#
.SYNOPSIS
  Windows 一键链路：PowerShell 装 MSYS2 -> MSYS2 里装 python3 -> python3 跑 remote-bash agent。
  不改动 Linux 版部署脚本；与 scripts/frpc-msys2-setup.sh 配合（后者是 frp 隧道，可选）。

.DESCRIPTION
  1) 以管理员 PowerShell 运行本脚本：
       irm https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/windows-msys2-remote-bash.ps1 | iex
     带参数：(irm https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/windows-msys2-remote-bash.ps1) -Name win-pc -Token <设备token>
     或本地文件：powershell -ExecutionPolicy Bypass -File .\windows-msys2-remote-bash.ps1 -Name win-pc -Token <设备token>
     -Name   : remote-bash 里的设备名（默认本机主机名）
     -Token  : 设备 token（面板配对后给的；不给则 agent 首次运行会打印配对链接，需管理员在面板批准）
     -Url    : agent 入口，默认 wss://edge02.10w123.com/workbench/wss
     -Proxy  : 出站代理，如 http://127.0.0.1:3128（没有则留空）
  2) 自动：下载官方 MSYS2 安装器静默装到 C:\msys64（已装跳过）-> MSYS2 bash 里 pacman 装 python3
     -> 把同目录的 remote-bash-agent.py 拷进 MSYS2 -> 注册计划任务（登录自启）并立即起 agent。
  3) 说明：跑的是 MSYS2 的 python3（有 pty），remote-bash 的 tty 就是 MSYS2 bash；
     不是 Windows 原生 python（无 pty）。

.NOTES
  需要管理员权限（装 MSYS2、注册计划任务）。脚本可重复执行。
#>
param(
  [string]$Name = $env:COMPUTERNAME,
  [string]$Url = 'wss://edge02.10w123.com/workbench/wss',
  [string]$Token = '',
  [string]$Proxy = '',
  [string]$AgentPath = '',
  [string]$AgentUrl = 'https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/remote-bash-agent.py',
  [string]$Msys2Root = 'C:\msys64'
)

$ErrorActionPreference = 'Stop'

# irm | iex 一行跑时 $PSScriptRoot 为空：agent 改从 GitHub raw 下载
if (-not $AgentPath) {
  $AgentPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'remote-bash-agent.py' } else { Join-Path $env:TEMP 'remote-bash-agent.py' }
}

# --- 0. 管理员检查（只警告，装 MSYS2/计划任务时需要） ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Warning '建议以管理员身份运行（装 MSYS2 / 注册计划任务需要）。右键 PowerShell -> 以管理员身份运行。' }

if (-not $Name) { $Name = $env:COMPUTERNAME }
$BashExe = Join-Path $Msys2Root 'usr\bin\bash.exe'

function Run-MsysBash([string]$Cmd) {
  Write-Host "  [msys] $Cmd"
  & $BashExe -lc $Cmd
  if ($LASTEXITCODE -ne 0) { throw "MSYS2 命令失败（exit $LASTEXITCODE）：$Cmd" }
}

# --- 1. 装 MSYS2（没装才装） ---
if (-not (Test-Path $BashExe)) {
  Write-Host "[1/4] 下载 MSYS2 安装器 ..."
  $installer = Join-Path $env:TEMP 'msys2-x86_64-latest.exe'
  $url = 'https://repo.msys2.org/distrib/msys2-x86_64-latest.exe'
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
  Write-Host "静默安装到 $Msys2Root ..."
  # Qt 安装器参数：-install 起始安装，-root 指定目录，-force/-confirm/-refresh 免交互
  & $installer -install -root $Msys2Root -force -confirm -refresh -c install -o
  if (-not (Test-Path $BashExe)) { throw "MSYS2 安装后仍找不到 $BashExe" }
  # 首次运行初始化 keyring/base（新装的 MSYS2 要先跑一次 pacman）
  Run-MsysBash 'pacman -Sy --noconfirm --needed base'
} else {
  Write-Host "[1/4] MSYS2 已存在，跳过安装"
}

# --- 2. MSYS2 里装 python3（remote-bash agent 的运行时） ---
Write-Host "[2/4] pacman 安装 python3 ..."
Run-MsysBash 'pacman -Sy --noconfirm --needed python3'
Run-MsysBash 'python3 --version && python3 -c "import pty; print(\"pty OK\")"'
# 可选：websocket-client 不装也能跑（agent 有标准库兜底），装上更稳
Run-MsysBash 'pacman -Sy --noconfirm --needed python-websocket-client || true'

# --- 3. 把 agent 拷进 MSYS2 ---
Write-Host "[3/4] 部署 remote-bash-agent.py ..."
if (-not (Test-Path $AgentPath)) {
  if ($AgentUrl) {
    Write-Host "从 $AgentUrl 下载 agent ..."
    Invoke-WebRequest -Uri $AgentUrl -OutFile $AgentPath -UseBasicParsing
  } else {
    throw "找不到 agent：$AgentPath（请把 remote-bash-agent.py 放到本脚本同目录，或用 -AgentPath/-AgentUrl 指定）"
  }
}
Run-MsysBash "cp '$(($AgentPath -replace '\\','/'))' ~/remote-bash-agent.py && python3 -m py_compile ~/remote-bash-agent.py && echo agent-ok"

# 启动脚本（在 MSYS2 里跑 agent；shell 固定 /usr/bin/bash）
$envLine = "export REMOTE_BASH_URL='$Url'`nexport REMOTE_BASH_NAME='$Name'`n"
if ($Token)  { $envLine += "export REMOTE_BASH_TOKEN='$Token'`n" }
if ($Proxy)  { $envLine += "export REMOTE_BASH_PROXY='$Proxy'`n" }
$envLine += "export REMOTE_BASH_SHELL='/usr/bin/bash'`nexec python3 ~/remote-bash-agent.py --url `"$Url`" --name `"$Name`""
Set-Content -Path (Join-Path $Msys2Root 'home\remote-bash-run.sh') -Value ("#!/bin/bash`n" + $envLine) -Encoding Ascii
Run-MsysBash 'chmod +x ~/remote-bash-run.sh'

# --- 4. 计划任务（登录自启）+ 立即启动 ---
Write-Host "[4/4] 注册计划任务 RemoteBashAgent 并启动 ..."
$action  = New-ScheduledTaskAction -Execute $BashExe -Argument '-lc "/home/remote-bash-run.sh"'
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings= New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
try {
  Register-ScheduledTask -TaskName 'RemoteBashAgent' -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null
  Write-Host '计划任务 RemoteBashAgent 已注册（登录自启）'
} catch { Write-Warning "计划任务注册失败（非管理员？）：$($_.Exception.Message)；将只做本次启动" }

# 立即起（新窗口，日志看 MSYS2 家目录的 .remote-bash/*.daemon.log）
Start-Process -FilePath $BashExe -ArgumentList '-lc "/home/remote-bash-run.sh"' -WindowStyle Minimized
Write-Host "已启动。去 workbench 的 Remote Bash 看设备 [$Name] 是否上线；"
Write-Host "agent 数据在 MSYS2 家目录 ~/.remote-bash/；状态：Get-ScheduledTask RemoteBashAgent"

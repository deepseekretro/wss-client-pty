#!/bin/sh
# frpc-msys2-setup.sh — 在 MSYS2 bash 里运行：装 frpc.exe + MSYS2 自带 openssh 服务
#
# 这是 Linux 版 buildDeployScript() 之外的独立脚本，不改动原部署脚本。
# 用途：真 Windows 机器（MSYS2 环境）上，通过 frp 提供 SSH 隧道（tty 由 MSYS2 sshd 提供）。
#
# 运行前必填（从服务器 /opt/frp/frps.toml 取 token，或让管理员提供）：
#   export FRP_AUTH_TOKEN='...'          # 与 frps 的 auth.token 一致
# 可选：
#   export FRP_SERVER_ADDR=edge02.10w123.com   # 默认
#   export FRP_SERVER_PORT=443                  # 默认
#   export FRP_REMOTE_PORT=18002                # 服务器回流端口（18000-18100），默认 18002
#   export FRP_VERSION=0.72.0
#   export FRP_PROXYURL=''                      # 出站必须走代理时填，如 http://127.0.0.1:3128
#
# 要求：以管理员身份打开 MSYS2 bash（注册 Windows 服务需要管理员）。
# 说明：这里用的是 MSYS2 的 openssh（pacman 装的），不是 Windows 系统自带 OpenSSH，
#       两套服务独立。本脚本可重复执行。
set -u

FRP_SERVER_ADDR="${FRP_SERVER_ADDR:-edge02.10w123.com}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-443}"
FRP_REMOTE_PORT="${FRP_REMOTE_PORT:-18002}"
FRP_VERSION="${FRP_VERSION:-0.72.0}"
FRP_PROXYURL="${FRP_PROXYURL:-}"
FRP_AUTH_TOKEN="${FRP_AUTH_TOKEN:-}"

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) echo "!! 请在 MSYS2 bash 里运行（uname -s 应为 MSYS_NT...）"; exit 1 ;;
esac

if [ -z "$FRP_AUTH_TOKEN" ]; then
  echo "!! 未设置 FRP_AUTH_TOKEN：export FRP_AUTH_TOKEN='与 frps 一致的 token' 后再跑"
  exit 1
fi
case "$FRP_REMOTE_PORT" in ''|*[!0-9]*) echo "!! FRP_REMOTE_PORT 必须是数字"; exit 1 ;; esac
if [ "$FRP_REMOTE_PORT" -lt 18000 ] || [ "$FRP_REMOTE_PORT" -gt 18100 ]; then
  echo "!! FRP_REMOTE_PORT 必须在 18000-18100（frps allowPorts）"; exit 1
fi

FRPC_BIN=/opt/frp/frpc.exe
mkdir -p /opt/frp

echo "[1/5] 安装/更新 frpc.exe ${FRP_VERSION} ..."
if [ ! -x "$FRPC_BIN" ]; then
  case "$(uname -m)" in x86_64|amd64) ARCH2=amd64 ;; aarch64|arm64) ARCH2=arm64 ;; *) ARCH2="$(uname -m)" ;; esac
  URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_windows_${ARCH2}.zip"
  TMP="$(mktemp -d)"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$FRP_PROXYURL" ]; then curl -x "$FRP_PROXYURL" -fsSL --max-time 300 -o "$TMP/frp.zip" "$URL"; else curl -fsSL --max-time 300 -o "$TMP/frp.zip" "$URL"; fi
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$TMP/frp.zip" "$URL"
  else echo "!! 没有 curl/wget"; exit 1; fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$TMP/frp.zip" -d "$TMP" || { echo "!! 解压失败"; exit 1; }
  elif [ -x /usr/bin/python3 ]; then
    /usr/bin/python3 -m zipfile -e "$TMP/frp.zip" "$TMP" || { echo "!! 解压失败"; exit 1; }
  elif command -v powershell.exe >/dev/null 2>&1; then
    WPKG=$(cygpath -w "$TMP/frp.zip"); WTMP=$(cygpath -w "$TMP")
    powershell.exe -NoProfile -Command "Expand-Archive -Force '$WPKG' '$WTMP'" || { echo "!! 解压失败"; exit 1; }
  else echo "!! 没有 unzip/python3/powershell"; exit 1; fi
  install -m 755 "$TMP"/frp_*_windows_*/frpc.exe /opt/frp/frpc.exe || { echo "!! 安装失败"; exit 1; }
  rm -rf "$TMP"
else
  echo "已存在 $FRPC_BIN ($("$FRPC_BIN" --version 2>/dev/null))，跳过下载"
fi

echo "[2/5] 安装 MSYS2 openssh ..."
if [ ! -x /usr/sbin/sshd ] && ! command -v sshd >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed openssh || { echo "!! openssh 安装失败"; exit 1; }
fi
mkdir -p /run/sshd /var/empty
chmod 755 /run/sshd /var/empty
# ssh-host-config 生成主机密钥/服务并建 cyg_server 账号（MSYS2 openssh 自带）
if command -v ssh-host-config >/dev/null 2>&1; then
  ssh-host-config -y >/dev/null 2>&1 || echo "[!] ssh-host-config 未完全成功，继续手动配置"
fi
[ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -A >/dev/null 2>&1 || true
"$SSHD_BIN" -t 2>&1 || { echo "!! sshd 配置校验失败"; exit 1; }
SSHD_PORT=$("$SSHD_BIN" -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
[ -n "$SSHD_PORT" ] || SSHD_PORT=22
echo "sshd 端口: $SSHD_PORT"

echo "[3/5] 启动 MSYS2 sshd（Windows 服务，需管理员）..."
SSD_WIN=$(cygpath -w "$SSHD_BIN" 2>/dev/null || cygpath -w /usr/sbin/sshd 2>/dev/null || echo "")
if [ -n "$SSD_WIN" ]; then
  BINPATH=$(printf '%c%s -D%c' 34 "$SSD_WIN" 34)
  sc.exe create sshd binPath= "$BINPATH" start= auto >/dev/null 2>&1 || true
  net start sshd >/dev/null 2>&1 || echo "[!] net start sshd 未成功（非管理员？），改用进程兜底"
fi
if ! pgrep -x sshd >/dev/null 2>&1; then
  /usr/sbin/sshd >>/opt/frp/sshd.log 2>&1 || true
  sleep 1
fi
pgrep -x sshd >/dev/null 2>&1 && echo "sshd 已运行" || { echo "!! sshd 未运行，请看 /opt/frp/sshd.log"; tail -6 /opt/frp/sshd.log 2>/dev/null || true; }

echo "[4/5] 写 frpc.toml（localPort 按 sshd 实际端口 $SSHD_PORT）..."
WINLOG=$(cygpath -m /opt/frp/frpc.log)
cat > /opt/frp/frpc.toml <<EOF
serverAddr = "${FRP_SERVER_ADDR}"
serverPort = ${FRP_SERVER_PORT}
transport.protocol = "wss"
transport.tls.useSystemCa = true
auth.token = "${FRP_AUTH_TOKEN}"
log.to = "${WINLOG}"
log.level = "info"
log.maxDays = 3

[[proxies]]
name = "msys2-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${SSHD_PORT}
remotePort = ${FRP_REMOTE_PORT}
EOF
if [ -n "$FRP_PROXYURL" ]; then
  printf 'transport.proxyURL = "%s"\n' "$FRP_PROXYURL" >> /opt/frp/frpc.toml
fi
chmod 600 /opt/frp/frpc.toml 2>/dev/null || true
"$FRPC_BIN" verify -c /opt/frp/frpc.toml || { echo "!! frpc verify 失败"; exit 1; }
echo "frpc verify 通过"

echo "[5/5] 启动 frpc（Windows 服务，需管理员；失败走 nohup 兜底）..."
FRPC_WIN=$(cygpath -w /opt/frp/frpc.exe)
CFG_WIN=$(cygpath -w /opt/frp/frpc.toml)
BINPATH=$(printf '%c%s -c %s%c' 34 "$FRPC_WIN" "$CFG_WIN" 34)
sc.exe create frpc-messagehub binPath= "$BINPATH" start= auto >/dev/null 2>&1 || true
sc.exe start frpc-messagehub >/dev/null 2>&1 || true
sleep 2
if ! pgrep -f frpc >/dev/null 2>&1; then
  setsid nohup "$FRPC_BIN" -c /opt/frp/frpc.toml >>/opt/frp/frpc.log 2>&1 </dev/null &
  sleep 2
fi
echo "最近日志："; tail -6 /opt/frp/frpc.log 2>/dev/null || true
if pgrep -f frpc >/dev/null 2>&1; then
  echo "完成。服务器上 ssh -p ${FRP_REMOTE_PORT} root@127.0.0.1（经 frp 隧道到本机 MSYS2 sshd:${SSHD_PORT}）"
else
  echo "!! 失败：frpc 未存活"; exit 1
fi

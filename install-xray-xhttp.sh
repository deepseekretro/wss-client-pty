#!/usr/bin/env bash
#
# 一键安装 Xray（VLESS + XHTTP + REALITY），装完打印 vless:// 连接地址
#
#   bash install-xray-xhttp.sh                 # 默认 8443 端口，伪装 www.microsoft.com
#   PORT=443 NAME=mybox bash install-xray-xhttp.sh
#   PORT=8443 SNI=www.apple.com DEST=www.apple.com:443 bash install-xray-xhttp.sh
#
# 特性：
#   · 自动装 xray（官方 install-release.sh）
#   · 自动生成 UUID / x25519 密钥 / shortId
#   · VLESS + XHTTP(network=xhttp) + REALITY：不需要域名和证书，也不占用 80
#   · 有 systemd 就装服务；没有（docker/容器）就用看护脚本后台跑
#   · 最后打印 vless:// 链接 + 二维码（有 qrencode 时）
set -euo pipefail

PORT="${PORT:-8443}"
SNI="${SNI:-www.microsoft.com}"
DEST="${DEST:-$SNI:443}"
XPATH="${XPATH:-/xhttp}"
NAME="${NAME:-$(hostname 2>/dev/null || echo xhttp)}"
CFG_DIR="${CFG_DIR:-/usr/local/etc/xray}"
CFG="$CFG_DIR/config.json"
RUNNER=/usr/local/bin/xray-xhttp-run.sh
CTL=/usr/local/bin/xray-xhttp-ctl
SVC=xray

usage() {
  cat <<'EOF'
用法:
  bash install-xray-xhttp.sh [选项]

选项（也都能用同名大写环境变量）:
  --port   8443              监听端口
  --sni    www.microsoft.com REALITY 伪装的 SNI（要是个能正常访问的 TLS 站点）
  --dest   <sni>:443         伪装目标，默认 "<sni>:443"
  --path   /xhttp            XHTTP 路径
  --name   <主机名>          连接地址里的备注名
  --pubip  <IP>              手工指定公网 IP（自动探测失败时用）

例子:
  bash install-xray-xhttp.sh --port 443 --sni www.apple.com
  PORT=8443 SNI=www.tesla.com bash install-xray-xhttp.sh
EOF
}

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --sni) SNI="${2:-}"; [[ "$DEST_GIVEN" != 1 ]] && DEST="${SNI}:443"; shift 2 ;;
    --dest) DEST="${2:-}"; DEST_GIVEN=1; shift 2 ;;
    --path) XPATH="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    --pubip) PUBIP="${2:-}"; PUBIP_FIXED=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $(id -u) -eq 0 ]] || die "需要 root（容器里默认就是 root，普通机器请加 sudo）"

# ---------------------------------------------------------------- 1. 安装 xray
if ! command -v xray >/dev/null 2>&1; then
  say "安装 Xray（官方脚本）"
  command -v curl >/dev/null || die "需要 curl：apt-get install -y curl / apk add curl"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  say "已安装 Xray：$(xray version | head -1)"
fi
command -v xray >/dev/null || die "xray 安装失败"

# ---------------------------------------------------------------- 2. 生成参数
say "生成 UUID / 密钥 / shortId"
UUID="$(xray uuid)"

# 兼容新旧两种输出：Public key / Password (PublicKey)
KEYS="$(xray x25519)"
PRIV="$(printf '%s\n' "$KEYS" | sed -n 's/^Private[[:space:]]*[Kk]ey:[[:space:]]*//p')"
PUB="$(printf '%s\n' "$KEYS" | sed -n 's/^\(Public[[:space:]]*[Kk]ey\|Password[[:space:]]*(PublicKey)\):[[:space:]]*//p')"
[[ -n "$PRIV" && -n "$PUB" ]] || die "解析 x25519 密钥失败：
$KEYS"

# 8 字节 shortId（十六进制，偶数位）
if command -v openssl >/dev/null 2>&1; then
  SID="$(openssl rand -hex 8)"
else
  SID="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

# ---------------------------------------------------------------- 3. 写配置
say "写配置 $CFG"
mkdir -p "$CFG_DIR"
if [[ -f "$CFG" ]]; then
  BACKUP="$CFG.bak.$(date +%s)"
  cp "$CFG" "$BACKUP"
  say "已备份原配置到 $BACKUP"
fi

cat > "$CFG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$DEST",
          "xver": 0,
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIV",
          "shortIds": [ "$SID" ]
        },
        "xhttpSettings": {
          "path": "$XPATH",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ]
}
JSON

say "校验配置"
if ! xray -test -config "$CFG" >/tmp/xray-test.$$ 2>&1; then
  cat /tmp/xray-test.$$
  rm -f /tmp/xray-test.$$
  die "配置校验失败"
fi
rm -f /tmp/xray-test.$$

# ---------------------------------------------------------------- 4. 启动
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  say "启动 systemd 服务 $SVC"
  systemctl enable "$SVC" >/dev/null 2>&1 || true
  systemctl restart "$SVC"
  sleep 1
  systemctl is-active "$SVC" >/dev/null || die "服务没起来，看：journalctl -u $SVC -n 30 --no-pager"
  MODE=systemd
else
  say "未检测到 systemd（容器环境），用看护脚本后台运行"
  cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/sh
# xray 看护：退出 5 秒后重启
while :; do
  /usr/local/bin/xray run -config /usr/local/etc/xray/config.json
  echo "[$(date -Is 2>/dev/null || date)] xray 退出 rc=$?，5 秒后重启"
  sleep 5
done
RUNNER_EOF
  chmod +x "$RUNNER"

  cat > "$CTL" <<CTL_EOF
#!/bin/sh
PIDFILE=/run/xray-xhttp.pid
case "\${1:-status}" in
  start)
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then echo "已在运行"; exit 0; fi
    setsid nohup sh $RUNNER >>/var/log/xray-xhttp.log 2>&1 </dev/null &
    echo \$! > "\$PIDFILE"; sleep 1
    echo "已启动 (pid \$(cat "\$PIDFILE"))"
    ;;
  stop)  [ -f "\$PIDFILE" ] && kill -TERM -\$(cat "\$PIDFILE") 2>/dev/null; rm -f "\$PIDFILE"; echo 已停止 ;;
  restart) "\$0" stop; sleep 1; "\$0" start ;;
  status) [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null && echo "运行中 (pid \$(cat "\$PIDFILE"))" || echo 未运行; tail -n 5 /var/log/xray-xhttp.log 2>/dev/null ;;
  logs) exec tail -n 50 -f /var/log/xray-xhttp.log ;;
  *) echo "用法: \$0 {start|stop|restart|status|logs}"; exit 1 ;;
esac
CTL_EOF
  chmod +x "$CTL"

  if [[ -f /run/xray-xhttp.pid ]] && kill -0 "$(cat /run/xray-xhttp.pid)" 2>/dev/null; then
    "$CTL" restart >/dev/null
  else
    "$CTL" start
  fi
  sleep 1
  "$CTL" status || true
  MODE=docker
fi

# ---------------------------------------------------------------- 5. 输出连接地址
PUBIP="${PUBIP:-}"
if [[ -z "$PUBIP" ]]; then
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    PUBIP="$(curl -4 -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$PUBIP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    PUBIP=""
  done
fi
[[ -n "$PUBIP" ]] || PUBIP="<你的服务器公网IP>"

ENC_PATH="$(printf '%s' "$XPATH" | sed 's|/|%2F|g')"
TAG="$(printf '%s' "$NAME" | sed 's/[^A-Za-z0-9._-]/-/g')"
URI="vless://$UUID@$PUBIP:$PORT?encryption=none&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=xhttp&mode=auto&path=$ENC_PATH#$TAG"

echo
echo "────────────────────────────────────────────────────────────"
echo "✔ 安装完成（Xray $(xray version | head -1 | awk '{print $2}')，运行方式：$MODE）"
echo
echo "协议      : VLESS + XHTTP + REALITY"
echo "地址      : $PUBIP"
echo "端口      : $PORT"
echo "UUID      : $UUID"
echo "公钥(pbk) : $PUB"
echo "shortId   : $SID"
echo "SNI       : $SNI"
echo "path      : $XPATH"
echo
echo "连接地址（复制到 v2rayN / NekoBox / Shadowrocket / sing-box 等）："
echo
echo "$URI"
echo
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t ANSIUTF8 "$URI" || true
fi
echo "────────────────────────────────────────────────────────────"
echo "配置: $CFG"
if [[ "$MODE" = systemd ]]; then
  echo "管理: systemctl status|restart xray   ·   journalctl -u xray -f"
else
  echo "管理: $CTL status|logs|restart|stop"
  echo "说明: 容器里请确认该端口已发布出去，例如 docker run -p $PORT:$PORT"
fi
echo
echo "客户端要点：传输方式 xhttp、安全类型 reality、指纹 chrome，"
echo "不要开「允许不安全」；连不上先确认防火墙/安全组放行 $PORT/tcp。"

#!/usr/bin/env bash
#
# remote-bash-agent 一键安装（GitHub: deepseekretro/wss-client-pty）
#
#   curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- --name win10 --proxy http://127.0.0.1:3128
#
# 行为：
#   1. 下载 remote-bash-agent.py 到 /usr/local/bin/
#   2. 按参数生成 /etc/remote-bash-agent.env（名称/地址/token/代理/心跳）
#   3. 安装 systemd 服务 remote-bash-agent.service（失败自动重启，开机自启）
#   4. 立即启动
set -euo pipefail

NAME="${REMOTE_BASH_NAME:-}"
URL="${REMOTE_BASH_URL:-wss://edge02.10w123.com/workbench/wss}"
TOKEN="${REMOTE_BASH_TOKEN:-}"
PROXY="${REMOTE_BASH_PROXY:-}"
HEARTBEAT="${REMOTE_BASH_HEARTBEAT:-15}"
SHELL_CMD="${REMOTE_BASH_SHELL:-}"

BIN=/usr/local/bin/remote-bash-agent.py
ENVFILE=/etc/remote-bash-agent.env
UNIT=remote-bash-agent.service
RAW=https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main
# 多个下载源，raw.githubusercontent 不可用时自动回退
SOURCES=(
  "https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main"
  "https://cdn.jsdelivr.net/gh/deepseekretro/wss-client-pty@main"
  "https://github.com/deepseekretro/wss-client-pty/raw/main"
)

fetch() {
  # $1 = 仓库内相对路径, $2 = 本地输出
  local rel="$1" out="$2" src
  for src in "${SOURCES[@]}"; do
    if curl -fsSL "$src/$rel" -o "$out" 2>/dev/null && [ -s "$out" ]; then
      return 0
    fi
  done
  return 1
}

usage() {
  echo "用法:"
  echo "  $0 [--name 名称] [--url wss://...] [--token xxx] [--proxy http://127.0.0.1:3128] [--heartbeat 15] [--shell /bin/bash]"
  echo
  echo "也可用环境变量: REMOTE_BASH_NAME / REMOTE_BASH_URL / REMOTE_BASH_TOKEN / REMOTE_BASH_PROXY / REMOTE_BASH_HEARTBEAT / REMOTE_BASH_SHELL"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --heartbeat) HEARTBEAT="${2:-}"; shift 2 ;;
    --shell) SHELL_CMD="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

if [[ $(id -u) -ne 0 ]]; then
  echo "需要 root 权限（sudo 或 root 用户）" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "需要 python3" >&2
  exit 1
fi

echo "==> 下载 remote-bash-agent.py"
fetch remote-bash-agent.py "$BIN" || { echo "下载脚本失败（所有源均不可用）" >&2; exit 1; }
chmod +x "$BIN"
python3 -m py_compile "$BIN"

echo "==> 写环境配置 $ENVFILE"
cat > "$ENVFILE" <<EOF
REMOTE_BASH_NAME=${NAME}
REMOTE_BASH_URL=${URL}
REMOTE_BASH_TOKEN=${TOKEN}
REMOTE_BASH_PROXY=${PROXY}
REMOTE_BASH_HEARTBEAT=${HEARTBEAT}
REMOTE_BASH_SHELL=${SHELL_CMD}
EOF
chmod 600 "$ENVFILE"

echo "==> 安装 systemd 服务 $UNIT"
fetch remote-bash-agent.service "/etc/systemd/system/$UNIT" || { echo "下载 unit 失败" >&2; exit 1; }
systemctl daemon-reload

echo "==> 启用并启动"
systemctl enable --now "$UNIT" || true
sleep 2
systemctl status "$UNIT" --no-pager 2>&1 | head -12 || true

echo
echo "✔ 安装完成。管理："
echo "  systemctl status  $UNIT        # 查看状态"
echo "  journalctl -u $UNIT -f         # 实时日志"
echo "  systemctl edit    $UNIT        # 修改参数（或编辑 $ENVFILE 后 systemctl restart $UNIT）"
echo "  systemctl restart $UNIT        # 只重启客户端，不会打断/杀死 tty 里正在跑的任务"
echo "  彻底结束某会话: systemctl stop $UNIT && pkill -f 'remote-bash-agent.py --daemon --name 名称'"
echo "  名称: ${NAME:-<主机名>}  地址: $URL  心跳: ${HEARTBEAT}s${PROXY:+  代理: $PROXY}"
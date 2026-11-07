#!/bin/bash
# msys2-remote-bash-setup.sh — 在 MSYS2 bash 里运行：装 python3 + 提供 remote-bash
#
# 前提：MSYS2 已装好（本脚本不装 MSYS2；要装 MSYS2 用 windows-msys2-remote-bash.ps1）。
# 做什么：pacman 装 python3 -> 下载本仓库的 remote-bash-agent.py -> 在 tmux 会话 remote-bash 里启动 agent（tty = MSYS2 bash，关窗口不死）。
#
# 用法（MSYS2 bash 里，一行）：
#   curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/msys2-remote-bash-setup.sh | bash -s -- --name win-pc
# 带 token / 代理：
#   curl -fsSL .../msys2-remote-bash-setup.sh | bash -s -- --name win-pc --token <设备token> --proxy http://127.0.0.1:3128
# 也可以先下载再跑：bash msys2-remote-bash-setup.sh --name win-pc
# 环境变量等价：REMOTE_BASH_NAME / REMOTE_BASH_URL / REMOTE_BASH_TOKEN / REMOTE_BASH_PROXY
#
# 可重入（= 原地升级）：没给的参数沿用 ~/remote-bash-run.sh 里的旧值（名称/地址/token/代理），
# agent 每次都重新下载，启动前会停旧 client 并重启 daemon（修复在 daemon 里，只重启 client
# 不生效）；已有 ~/.remote-bash/<名称>.token 时无需重新配对。--keep-daemon 保留 tty 会话
# （daemon 仍是旧代码）。注意：从 remote-bash 自己的终端里重装会杀掉当前 tty，请先 detached 运行。
set -eu

NAME="${REMOTE_BASH_NAME:-}"
URL="${REMOTE_BASH_URL:-}"
TOKEN="${REMOTE_BASH_TOKEN:-}"
PROXY="${REMOTE_BASH_PROXY:-}"
AGENT_URL="${REMOTE_BASH_AGENT_URL:-https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/remote-bash-agent.py}"
FOREGROUND=0
KEEP_DAEMON="${REMOTE_BASH_KEEP_DAEMON:-0}"

# 沿用上次生成的 ~/remote-bash-run.sh 里的配置（优先级：命令行/环境变量 > run.sh > 默认值）
load_existing_run() {
  [ -r ~/remote-bash-run.sh ] || return 0
  local v
  v=$(sed -n "s/^export REMOTE_BASH_NAME='\(.*\)'$/\1/p" ~/remote-bash-run.sh | tail -1)
  [ -n "$NAME" ] || NAME="$v"
  v=$(sed -n "s/^export REMOTE_BASH_URL='\(.*\)'$/\1/p" ~/remote-bash-run.sh | tail -1)
  [ -n "$URL" ] || URL="$v"
  v=$(sed -n "s/^export REMOTE_BASH_TOKEN='\(.*\)'$/\1/p" ~/remote-bash-run.sh | tail -1)
  [ -n "$TOKEN" ] || TOKEN="$v"
  v=$(sed -n "s/^export REMOTE_BASH_PROXY='\(.*\)'$/\1/p" ~/remote-bash-run.sh | tail -1)
  [ -n "$PROXY" ] || PROXY="$v"
}
load_existing_run
NAME="${NAME:-${HOSTNAME:-win-pc}}"
URL="${URL:-wss://edge02.10w123.com/workbench/wss}"
SAFE_NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_')

while [ $# -gt 0 ]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --url)   URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --proxy) PROXY="$2"; shift 2 ;;
    --agent-url) AGENT_URL="$2"; shift 2 ;;
    --keep-daemon) KEEP_DAEMON=1; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done
SAFE_NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_')   # --name 可能改了名字，重新计算

case "$(uname -s)" in
  MSYS*|MINGW*|CYGWIN*) ;;
  *) echo "!! 请在 MSYS2 bash 里运行（uname -s 应为 MSYS_NT...）" >&2; exit 1 ;;
esac

# 注意：UCRT64/MINGW 的 python3 是 Windows 原生移植版，没有 termios/pty，跑不了 remote-bash 的 tty。
# 必须用 MSYS 的 /usr/bin/python3（POSIX 版）。PATH 把 /usr/bin 排前面，避免被 ucrt64/bin 的 python3 抢走。
export PATH="/usr/bin:$PATH"
hash -r 2>/dev/null || true
echo "[1/4] 安装 python3（MSYS 版，已装跳过）..."
if [ ! -x /usr/bin/python3 ]; then
  pacman -Sy --noconfirm --needed python3 || { echo "!! python3 安装失败"; exit 1; }
fi
PYTHON=/usr/bin/python3
"$PYTHON" --version
if ! "$PYTHON" -c "import pty" 2>/dev/null; then
  echo "!! $PYTHON 没有 termios（可能误用了 UCRT64 的 python）。请在 MSYS2 子系统 shell（不是 UCRT64/MINGW64）里重跑本脚本。" >&2
  exit 1
fi
echo "pty OK ($PYTHON)"
# websocket-client 可选：agent 有标准库兜底，装不上不拦
WS_OK=0
for PKG in python-websocket-client mingw-w64-x86_64-python-websocket-client mingw-w64-ucrt-x86_64-python-websocket-client; do
  if pacman -Sy --noconfirm --needed "$PKG" >/dev/null 2>&1; then WS_OK=1; break; fi
done
[ "$WS_OK" = "1" ] || "$PYTHON" -m pip install --user -q websocket-client >/dev/null 2>&1 && WS_OK=1 || true
[ "$WS_OK" = "1" ] && echo "websocket-client OK" || echo "[!] websocket-client 未装（标准库兜底，可跑）"

echo "[2/4] 部署 remote-bash-agent.py ..."
if [ "${REMOTE_BASH_UPDATE_AGENT:-1}" = "1" ] || [ ! -f ~/remote-bash-agent.py ]; then
  # 先落临时文件、校验通过再替换：下载失败不会把已装好的脚本写坏
  curl -fsSL "$AGENT_URL" -o ~/remote-bash-agent.py.tmp.$$ || wget -q -O ~/remote-bash-agent.py.tmp.$$ "$AGENT_URL" || { echo "!! agent 下载失败（已有版本未改动）"; rm -f ~/remote-bash-agent.py.tmp.$$; exit 1; }
  "$PYTHON" -m py_compile ~/remote-bash-agent.py.tmp.$$ || { echo "!! agent 校验失败（已有版本未改动）"; rm -f ~/remote-bash-agent.py.tmp.$$; exit 1; }
  mv -f ~/remote-bash-agent.py.tmp.$$ ~/remote-bash-agent.py
fi
"$PYTHON" -m py_compile ~/remote-bash-agent.py && echo "agent-ok ($(sed -n "s/^VERSION = '\([^']*\)'.*/\1/p" ~/remote-bash-agent.py | tail -1))"

echo "[3/4] 生成启动脚本 ~/remote-bash-run.sh ..."
cat > ~/remote-bash-run.sh <<EOF
#!/bin/bash
export REMOTE_BASH_URL='$URL'
export REMOTE_BASH_NAME='$NAME'
export REMOTE_BASH_TOKEN='$TOKEN'
export REMOTE_BASH_PROXY='$PROXY'
export REMOTE_BASH_SHELL='/usr/bin/bash'
exec /usr/bin/python3 ~/remote-bash-agent.py --url '$URL' --name '$NAME' --proxy '$PROXY'
EOF
chmod +x ~/remote-bash-run.sh

# tmux 常驻（关掉当前 MSYS2 窗口会话不死；attach 看日志）
# 停旧进程：tmux 里的 client + 本会话的 daemon。daemon 必须重启——关键修复在 daemon 里，
# 只换 client 代码的话远端还是旧行为（--keep-daemon 跳过这步，tty 会话保留但不升级）
stop_old_agent() {
  tmux kill-session -t remote-bash 2>/dev/null || true
  pkill -f "remote-bash-agent[.]py.*--name ${SAFE_NAME}([[:space:]]|$)" 2>/dev/null || true
  if [ "$KEEP_DAEMON" = "1" ]; then
    echo "    --keep-daemon：保留现有 daemon/tty（daemon 仍是旧代码）"
  else
    sleep 1
    rm -f ~/.remote-bash/${SAFE_NAME}.sock 2>/dev/null || true
  fi
}

if [ "$FOREGROUND" = "0" ]; then
echo "[4/4] tmux 启动 agent ..."
if ! command -v tmux >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed tmux 2>/dev/null || echo "[!] tmux 未装，将用 setsid 兜底"
fi
mkdir -p ~/.remote-bash
stop_old_agent
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s remote-bash "bash ~/remote-bash-run.sh"
  sleep 1
  tmux has-session -t remote-bash 2>/dev/null && echo "agent 已在 tmux 会话 remote-bash 里运行（tmux attach -t remote-bash 看日志，Ctrl+b d 脱离）" || echo "[!] tmux 会话未存活，请 tmux attach -t remote-bash 排查"
else
  setsid nohup bash ~/remote-bash-run.sh >> ~/.remote-bash/msys2-agent.log 2>&1 </dev/null &
  sleep 2
  pgrep -f remote-bash-agent.py >/dev/null 2>&1 && echo "agent 已在后台运行" || echo "[!] agent 未存活，请看 ~/.remote-bash/msys2-agent.log"
fi
echo "去 workbench 的 Remote Bash 看设备 [$NAME]"
fi

if [ "$FOREGROUND" = "1" ]; then
  echo "前台运行（Ctrl+C 停 client，daemon 里的 shell 不死）..."
  stop_old_agent
  exec bash ~/remote-bash-run.sh
fi

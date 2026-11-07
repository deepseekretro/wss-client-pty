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
set -eu

NAME="${REMOTE_BASH_NAME:-${HOSTNAME:-win-pc}}"
URL="${REMOTE_BASH_URL:-wss://edge02.10w123.com/workbench/wss}"
TOKEN="${REMOTE_BASH_TOKEN:-}"
PROXY="${REMOTE_BASH_PROXY:-}"
AGENT_URL="${REMOTE_BASH_AGENT_URL:-https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/remote-bash-agent.py}"
FOREGROUND=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --url)   URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --proxy) PROXY="$2"; shift 2 ;;
    --agent-url) AGENT_URL="$2"; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

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
if [ ! -f ~/remote-bash-agent.py ] || [ "${REMOTE_BASH_UPDATE_AGENT:-1}" = "1" ]; then
  curl -fsSL "$AGENT_URL" -o ~/remote-bash-agent.py || wget -q -O ~/remote-bash-agent.py "$AGENT_URL" || { echo "!! agent 下载失败"; exit 1; }
fi
"$PYTHON" -m py_compile ~/remote-bash-agent.py && echo "agent-ok"

echo "[3/4] 生成启动脚本 ~/remote-bash-run.sh ..."
cat > ~/remote-bash-run.sh <<EOF
#!/bin/bash
export REMOTE_BASH_URL='$URL'
export REMOTE_BASH_NAME='$NAME'
export REMOTE_BASH_TOKEN='$TOKEN'
export REMOTE_BASH_PROXY='$PROXY'
export REMOTE_BASH_SHELL='/usr/bin/bash'
exec /usr/bin/python3 ~/remote-bash-agent.py --url '$URL' --name '$NAME'
EOF
chmod +x ~/remote-bash-run.sh

# tmux 常驻（关掉当前 MSYS2 窗口会话不死；attach 看日志）
if [ "$FOREGROUND" = "0" ]; then
echo "[4/4] tmux 启动 agent ..."
if ! command -v tmux >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed tmux 2>/dev/null || echo "[!] tmux 未装，将用 setsid 兜底"
fi
mkdir -p ~/.remote-bash
if command -v tmux >/dev/null 2>&1; then
  tmux kill-session -t remote-bash 2>/dev/null || true
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
  exec bash ~/remote-bash-run.sh
fi

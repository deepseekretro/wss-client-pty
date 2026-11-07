#!/bin/bash
# msys2-remote-bash-setup.sh — 在 MSYS2 bash 里运行：装 python3 + 提供 remote-bash
#
# 前提：MSYS2 已装好（本脚本不装 MSYS2；要装 MSYS2 用 windows-msys2-remote-bash.ps1）。
# 做什么：pacman 装 python3 -> 下载本仓库的 remote-bash-agent.py -> 启动 agent（tty = MSYS2 bash）
#         -> 尽量注册 Windows 计划任务实现登录自启（需要管理员，失败则只做本次后台启动）。
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

echo "[1/4] 安装 python3（已装跳过）..."
if ! command -v python3 >/dev/null 2>&1; then
  pacman -Sy --noconfirm --needed python3 || { echo "!! python3 安装失败"; exit 1; }
fi
python3 --version
python3 -c "import pty; print('pty OK')"
# websocket-client 可选：agent 有标准库兜底，装不上不拦
WS_OK=0
for PKG in python-websocket-client mingw-w64-x86_64-python-websocket-client mingw-w64-ucrt-x86_64-python-websocket-client; do
  if pacman -Sy --noconfirm --needed "$PKG" >/dev/null 2>&1; then WS_OK=1; break; fi
done
[ "$WS_OK" = "1" ] || python3 -m pip install --user -q websocket-client >/dev/null 2>&1 && WS_OK=1 || true
[ "$WS_OK" = "1" ] && echo "websocket-client OK" || echo "[!] websocket-client 未装（标准库兜底，可跑）"

echo "[2/4] 部署 remote-bash-agent.py ..."
if [ ! -f ~/remote-bash-agent.py ] || [ "${REMOTE_BASH_UPDATE_AGENT:-1}" = "1" ]; then
  curl -fsSL "$AGENT_URL" -o ~/remote-bash-agent.py || wget -q -O ~/remote-bash-agent.py "$AGENT_URL" || { echo "!! agent 下载失败"; exit 1; }
fi
python3 -m py_compile ~/remote-bash-agent.py && echo "agent-ok"

echo "[3/4] 生成启动脚本 ~/remote-bash-run.sh ..."
cat > ~/remote-bash-run.sh <<EOF
#!/bin/bash
export REMOTE_BASH_URL='$URL'
export REMOTE_BASH_NAME='$NAME'
export REMOTE_BASH_TOKEN='$TOKEN'
export REMOTE_BASH_PROXY='$PROXY'
export REMOTE_BASH_SHELL='/usr/bin/bash'
exec python3 ~/remote-bash-agent.py --url '$URL' --name '$NAME'
EOF
chmod +x ~/remote-bash-run.sh

# 尽量注册登录自启（需要管理员；schatasks 在 MSYS2 里叫 schtasks.exe）
echo "[4/4] 注册自启 + 启动 ..."
RUN_WIN=$(cygpath -w ~/remote-bash-run.sh 2>/dev/null || echo "")
BASH_WIN=$(cygpath -w /usr/bin/bash.exe 2>/dev/null || cygpath -w /usr/bin/bash 2>/dev/null || echo "")
if command -v schtasks.exe >/dev/null 2>&1 && [ -n "$BASH_WIN" ]; then
  schtasks.exe /Create /TN RemoteBashAgent /SC LOGON /RL HIGHEST \
    /TR "\"$BASH_WIN\" -lc /home/remote-bash-run.sh" /F >/dev/null 2>&1 \
    && echo "计划任务 RemoteBashAgent 已注册（登录自启）" \
    || echo "[!] 计划任务注册失败（非管理员？），只做本次后台启动"
fi

if [ "$FOREGROUND" = "1" ]; then
  echo "前台运行（Ctrl+C 停 client，daemon 里的 shell 不死）..."
  exec bash ~/remote-bash-run.sh
else
  mkdir -p ~/.remote-bash
  setsid nohup bash ~/remote-bash-run.sh >> ~/.remote-bash/msys2-agent.log 2>&1 </dev/null &
  sleep 2
  pgrep -f remote-bash-agent.py >/dev/null 2>&1 && echo "agent 已在后台运行" || echo "[!] agent 未存活，请看 ~/.remote-bash/msys2-agent.log"
  echo "去 workbench 的 Remote Bash 看设备 [$NAME]；日志：~/.remote-bash/msys2-agent.log"
fi

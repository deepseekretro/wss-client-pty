#!/usr/bin/env bash
#
# remote-bash-agent 一键安装（GitHub: deepseekretro/wss-client-pty）
#
#   systemd 机器：
#     curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- --name win10
#   代理环境：
#     ... | bash -s -- --name win10 --proxy http://127.0.0.1:3128
#   docker / 容器（没有 systemd）：
#     ... | bash -s -- --name web01 --docker
#   作为容器主进程（前台运行，日志直接进 docker logs）：
#     ... | bash -s -- --name web01 --foreground
#
# 行为（可重入：重复执行 = 原地升级）：
#   1. 下载 remote-bash-agent.py 到 /usr/local/bin/（先落临时文件、校验通过后再替换，
#      下载失败不会把已装好的脚本写坏）
#   2. 按参数生成 /etc/remote-bash-agent.env（名称/地址/token/代理/心跳）。
#      **没显式给的参数会沿用上一次写入的值**，重跑不加参数不会把名称/token/代理清掉；
#      优先级：命令行 > 环境变量 > 已有 env 文件 > 默认值（地址/心跳/主机名）
#   3. 停掉旧客户端，并**重启 daemon**：pty 写入修复等关键代码在 daemon 进程里，
#      只重启客户端的话旧 daemon 还在跑旧代码，升级不生效（--keep-daemon 可保留 tty 会话，
#      但 daemon 里的代码也不会跟着升级，谨慎使用）
#   4. 按部署模式启动：
#        systemd    → 安装 remote-bash-agent.service（失败重启、开机自启），用 restart
#                     确保已在跑的服务也换成新代码（enable --now 对已激活的服务是空操作）
#        docker     → 装一个 5 秒重启的看护进程 + remote-bash-agent-ctl 管理脚本
#        foreground → 直接在前台 exec（当成容器主进程）
#   5. 没有 token 时先在前台跑设备注册，打印浏览器链接；已有 token 文件则跳过
set -euo pipefail

NAME="${REMOTE_BASH_NAME:-}"
URL="${REMOTE_BASH_URL:-}"
TOKEN="${REMOTE_BASH_TOKEN:-}"
PROXY="${REMOTE_BASH_PROXY:-}"
HEARTBEAT="${REMOTE_BASH_HEARTBEAT:-}"
SHELL_CMD="${REMOTE_BASH_SHELL:-}"
DEPLOY="${REMOTE_BASH_DEPLOY:-}"          # systemd | docker | foreground
LOGFILE="${REMOTE_BASH_LOG:-/var/log/remote-bash-agent.log}"
KEEP_DAEMON="${REMOTE_BASH_KEEP_DAEMON:-0}"

BIN=/usr/local/bin/remote-bash-agent.py
BIN_NEW="$BIN.new"
ENVFILE=/etc/remote-bash-agent.env
UNIT=remote-bash-agent.service
UNIT_PATH="/etc/systemd/system/$UNIT"
RUNNER=/usr/local/bin/remote-bash-agent-run.sh
CTL=/usr/local/bin/remote-bash-agent-ctl
PIDFILE="${REMOTE_BASH_PIDFILE:-/run/remote-bash-agent.pid}"

# 多个下载源，raw.githubusercontent 不可用时自动回退
SOURCES=(
  "https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main"
  "https://cdn.jsdelivr.net/gh/deepseekretro/wss-client-pty@main"
  "https://github.com/deepseekretro/wss-client-pty/raw/main"
)

fetch() {
  # $1 = 仓库内相对路径, $2 = 本地输出；先落临时文件，成功才原子替换，避免下载失败写坏已有文件
  local rel="$1" out="$2" src tmp
  tmp="${out}.tmp.$$"
  for src in "${SOURCES[@]}"; do
    if curl -fsSL "$src/$rel" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
      mv -f "$tmp" "$out"
      return 0
    fi
  done
  rm -f "$tmp"
  return 1
}

# agent 按名字把 daemon socket/token 放在 ~/.remote-bash/ 下，名字里的非法字符会被替换
safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

usage() {
  echo "用法:"
  echo "  $0 [--name 名称] [--url wss://...] [--token xxx] [--proxy http://127.0.0.1:3128]"
  echo "     [--heartbeat 15] [--shell /bin/bash] [--docker | --foreground] [--log /var/log/xxx.log]"
  echo "     [--keep-daemon]   # 重装时保留现有 daemon/tty 会话（daemon 里的代码不会升级）"
  echo
  echo "部署模式（自动判断，也可显式指定）:"
  echo "  默认     有 systemd 就用 systemd，没有就自动退化成 docker 模式"
  echo "  --docker 不装 systemd：后台看护进程 + remote-bash-agent-ctl 管理（适合容器里常驻）"
  echo "  --foreground 直接前台运行，不做守护（适合作为容器主进程/Dockerfile CMD）"
  echo
  echo "可重入：重复执行本脚本 = 原地升级。没给的参数沿用 /etc/remote-bash-agent.env 里的旧值，"
  echo "已有 token 文件时跳过设备注册；升级会重启客户端和 daemon（tty 会话重建）。"
  echo
  echo "也可用环境变量: REMOTE_BASH_NAME / REMOTE_BASH_URL / REMOTE_BASH_TOKEN / REMOTE_BASH_PROXY"
  echo "                REMOTE_BASH_HEARTBEAT / REMOTE_BASH_SHELL / REMOTE_BASH_DEPLOY / REMOTE_BASH_LOG"
  echo "                REMOTE_BASH_KEEP_DAEMON=1（同 --keep-daemon）"
  echo
  echo "docker 例子:"
  echo "  curl -fsSL .../install.sh | bash -s -- --name web01 --docker"
  echo "  docker run -d --name rb --restart=unless-stopped -e REMOTE_BASH_TOKEN=xxx myimage"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --proxy) PROXY="${2:-}"; shift 2 ;;
    --heartbeat) HEARTBEAT="${2:-}"; shift 2 ;;
    --shell) SHELL_CMD="${2:-}"; shift 2 ;;
    --docker|--no-systemd|--container) DEPLOY=docker; shift ;;
    --foreground|--fg) DEPLOY=foreground; shift ;;
    --keep-daemon) KEEP_DAEMON=1; shift ;;
    --log) LOGFILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1"; usage; exit 1 ;;
  esac
done

if [[ $(id -u) -ne 0 ]]; then
  echo "需要 root 权限（sudo 或 root 用户）" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "需要 python3（镜像里请先 apt-get install -y python3 或 apk add python3）" >&2
  exit 1
fi

if ! command -v curl >/dev/null; then
  echo "需要 curl（镜像里请先 apt-get install -y curl 或 apk add curl）" >&2
  exit 1
fi

# ---------------------------------------------------------------- 沿用已有安装的配置（可重入的关键）
# 优先级：命令行/环境变量（上面已填）> 已有 env 文件 > 默认值。
# 这样升级时不加参数重跑，不会把上次的名称/地址/token/代理清掉。
load_existing_env() {
  [[ -r "$ENVFILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      REMOTE_BASH_NAME) [[ -z "$NAME" ]] && NAME="$v" ;;
      REMOTE_BASH_URL) [[ -z "$URL" ]] && URL="$v" ;;
      REMOTE_BASH_TOKEN) [[ -z "$TOKEN" ]] && TOKEN="$v" ;;
      REMOTE_BASH_PROXY) [[ -z "$PROXY" ]] && PROXY="$v" ;;
      REMOTE_BASH_HEARTBEAT) [[ -z "$HEARTBEAT" ]] && HEARTBEAT="$v" ;;
      REMOTE_BASH_SHELL) [[ -z "$SHELL_CMD" ]] && SHELL_CMD="$v" ;;
    esac
  done < "$ENVFILE"
}
load_existing_env

URL="${URL:-wss://edge02.10w123.com/workbench/wss}"
HEARTBEAT="${HEARTBEAT:-15}"
NAME="${NAME:-$(hostname)}"
SAFE_NAME="$(safe_name "$NAME")"

# ---------------------------------------------------------------- 部署模式判断
SYSTEMD_READY=0
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_READY=1
fi

if [[ -z "$DEPLOY" ]]; then
  if [[ $SYSTEMD_READY -eq 1 ]]; then
    DEPLOY=systemd
  else
    DEPLOY=docker
    echo "==> 未检测到运行中的 systemd（容器环境？），自动使用 docker 模式"
    echo "    需要 systemd 服务的话请在有 systemd 的机器上重跑本脚本。"
  fi
fi

if [[ "$DEPLOY" == "systemd" && $SYSTEMD_READY -ne 1 ]]; then
  echo "systemd 未运行（容器里常见），请改用 --docker 或 --foreground" >&2
  exit 1
fi

# ---------------------------------------------------------------- 下载 & 校验（失败就地退出，老安装不动）
echo "==> 下载 remote-bash-agent.py"
fetch remote-bash-agent.py "$BIN_NEW" || { echo "下载脚本失败（所有源均不可用），已有安装未改动" >&2; exit 1; }
python3 -m py_compile "$BIN_NEW" || { echo "下载到的脚本校验失败，已有安装未改动" >&2; rm -f "$BIN_NEW"; exit 1; }
AGENT_VERSION="$(sed -n "s/^VERSION = '\([^']*\)'.*/\1/p" "$BIN_NEW" | tail -1)"
echo "    agent 版本: ${AGENT_VERSION:-?}（面板里显示的即此版本）"

if [[ "$DEPLOY" == "systemd" ]]; then
  fetch remote-bash-agent.service "${UNIT_PATH}.new" || { echo "下载 unit 失败，已有安装未改动" >&2; rm -f "$BIN_NEW"; exit 1; }
fi

# ---------------------------------------------------------------- 停旧客户端 + 重启 daemon
stop_existing_client() {
  if [[ "$DEPLOY" == "systemd" ]]; then
    systemctl stop "$UNIT" >/dev/null 2>&1 || true
  elif [[ "$DEPLOY" == "docker" && -x "$CTL" ]]; then
    "$CTL" stop >/dev/null 2>&1 || true
  fi
  pkill -f "remote-bash-agent-run.sh" 2>/dev/null || true
}

# 只按会话名杀本机的 agent 进程（客户端 + daemon），不碰其他名字/其他机器。
# 必须杀 daemon：关键修复（pty 写入）在 daemon 进程里，只换客户端代码不生效。
kill_agent_for_name() {
  local pat="remote-bash-agent\.py.*--name ${SAFE_NAME}([[:space:]]|$)"
  pkill -f "$pat" 2>/dev/null || true
  sleep 1
  pkill -9 -f "$pat" 2>/dev/null || true
  if [[ "$KEEP_DAEMON" == "1" ]]; then
    echo "    --keep-daemon：保留现有 daemon/tty（daemon 仍是旧代码，pty 修复要等 daemon 重启后才生效）"
  else
    # daemon 被杀后 socket 文件会残留，顺手清掉（ensure_daemon 本来也会处理）
    rm -f "${HOME:-/root}/.remote-bash/${SAFE_NAME}.sock"
  fi
}

# ---------------------------------------------------------------- 设备注册
pair_now() {
  [[ -n "$TOKEN" ]] && return 0
  # 已配过对（agent 把 token 存在 ~/.remote-bash/<name>.token）：重装升级直接跳过，
  # 不然每次重跑都要重新等管理员点允许（token 失效时 agent 自己会重新配对）
  if [[ -s "${HOME:-/root}/.remote-bash/${SAFE_NAME}.token" ]]; then
    echo "==> 已有设备 token（${HOME:-/root}/.remote-bash/${SAFE_NAME}.token），跳过注册"
    return 0
  fi
  echo "==> 设备注册（前台拿 token）"
  echo "    稍后会打印一个链接，用浏览器打开并点「允许」即可，无需手工填 token。"
  local rc=0
  set +e
  python3 "$BIN" --pair "${DEPLOY_ARGS[@]}" </dev/null
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo
    echo "⚠ 这次没完成注册（超时/被拒/网络不通），稍后会自动重试。"
    if [[ "$DEPLOY" == "systemd" ]]; then
      echo "  注册链接在日志里：journalctl -u $UNIT -n 20 --no-pager | grep rb_pair"
    else
      echo "  注册链接在日志里：grep rb_pair $LOGFILE"
    fi
    echo "  也可以随时手工重来：python3 $BIN --pair ${DEPLOY_ARGS[*]}"
  fi
}

# ---------------------------------------------------------------- systemd
install_systemd() {
  echo "==> 安装 systemd 服务 $UNIT"
  mv -f "${UNIT_PATH}.new" "$UNIT_PATH"
  systemctl daemon-reload

  pair_now

  echo "==> 启用并重启（restart 确保已在跑的服务也换成新代码）"
  systemctl enable "$UNIT" >/dev/null 2>&1 || true
  systemctl restart "$UNIT" || true
  sleep 2
  systemctl status "$UNIT" --no-pager 2>&1 | head -12 || true

  echo
  echo "✔ 安装完成（systemd）。管理："
  echo "  systemctl status  $UNIT        # 查看状态"
  echo "  journalctl -u $UNIT -f         # 实时日志"
  echo "  systemctl edit    $UNIT        # 修改参数（或编辑 $ENVFILE 后 systemctl restart $UNIT）"
  echo "  重新注册/换 token: python3 $BIN --pair ${DEPLOY_ARGS[*]}"
  echo "  systemctl restart $UNIT        # 重启客户端（daemon 也会一并重建，tty 会话重开）"
  echo "  彻底结束某会话: systemctl stop $UNIT && pkill -f 'remote-bash-agent.py --daemon --name 名称'"
  echo "  名称: ${NAME}  地址: $URL  心跳: ${HEARTBEAT}s${PROXY:+  代理: $PROXY}  agent: ${AGENT_VERSION:-?}"
  echo "  升级：直接重跑本脚本（不加参数也会沿用上面的配置）"
}

# ---------------------------------------------------------------- docker（无 systemd）
write_runner_and_ctl() {
  # 1) 看护进程：客户端退出 5 秒后重启；daemon 独立进程，不受影响
  cat > "$RUNNER" <<'RUNNER_EOF'
#!/bin/sh
# remote-bash-agent 看护进程（无 systemd 环境：容器 / 精简镜像）
# 只重启「客户端」，daemon（持有 tty）是独立进程，不会被连带杀掉。
ENVFILE=/etc/remote-bash-agent.env
BIN=/usr/local/bin/remote-bash-agent.py
REMOTE_BASH_CLIENTPID=${REMOTE_BASH_CLIENTPID:-/run/remote-bash-agent.client.pid}

if [ -r "$ENVFILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENVFILE"
  set +a
fi

: "${REMOTE_BASH_URL:=wss://edge02.10w123.com/workbench/wss}"
: "${REMOTE_BASH_HEARTBEAT:=15}"

while :; do
  set -- --url "$REMOTE_BASH_URL" --heartbeat "$REMOTE_BASH_HEARTBEAT"
  [ -n "${REMOTE_BASH_NAME:-}" ] && set -- "$@" --name "$REMOTE_BASH_NAME"
  [ -n "${REMOTE_BASH_PROXY:-}" ] && set -- "$@" --proxy "$REMOTE_BASH_PROXY"
  [ -n "${REMOTE_BASH_SHELL:-}" ] && set -- "$@" --shell "$REMOTE_BASH_SHELL"

  python3 "$BIN" "$@" &
  child=$!
  echo "$child" > "$REMOTE_BASH_CLIENTPID"
  wait "$child"
  rc=$?
  echo "[$(date -Is 2>/dev/null || date)] 客户端退出 rc=$rc，5 秒后重启"
  sleep 5
done
RUNNER_EOF
  chmod +x "$RUNNER"

  # 2) 管理脚本
  cat > "$CTL" <<CTL_EOF
#!/bin/sh
# remote-bash-agent 管理（容器 / 无 systemd 环境）
RUNNER=$RUNNER
LOG=$LOGFILE
PIDFILE=$PIDFILE
CLIENTPID=${REMOTE_BASH_CLIENTPID:-/run/remote-bash-agent.client.pid}

running() {
  [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null
}

case "\${1:-status}" in
  start)
    if running; then echo "已在运行 (pid \$(cat "\$PIDFILE"))"; exit 0; fi
    mkdir -p "\$(dirname "\$PIDFILE")" "\$(dirname "\$LOG")" 2>/dev/null
    setsid nohup sh "\$RUNNER" >>"\$LOG" 2>&1 </dev/null &
    echo \$! > "\$PIDFILE"
    sleep 1
    if running; then
      echo "已启动 (pid \$(cat "\$PIDFILE"))，日志：\$LOG"
    else
      echo "启动失败，查看：tail -n 50 \$LOG" >&2
      exit 1
    fi
    ;;
  stop)
    # 先杀客户端子进程，再杀看护进程（看护进程是 setsid 的组长，整组收尾）。
    # daemon 是 start_new_session 独立进程，不在这个组里，tty 会保留。
    if [ -f "\$CLIENTPID" ]; then
      kill -TERM "\$(cat "\$CLIENTPID")" 2>/dev/null || true
    fi
    if running; then
      pid="\$(cat "\$PIDFILE")"
      kill -TERM -"\$pid" 2>/dev/null || kill -TERM "\$pid" 2>/dev/null
    fi
    sleep 1
    if [ -f "\$CLIENTPID" ]; then
      kill -KILL "\$(cat "\$CLIENTPID")" 2>/dev/null || true
    fi
    if running; then
      kill -KILL -"\$(cat "\$PIDFILE")" 2>/dev/null || true
    fi
    pkill -f "\$RUNNER" 2>/dev/null || true
    rm -f "\$PIDFILE" "\$CLIENTPID"
    echo "已停止客户端（daemon / tty 保留，重新 start 会接回同一会话）"
    ;;
  restart)
    "\$0" stop
    sleep 1
    "\$0" start
    ;;
  status)
    if running; then
      echo "运行中 (pid \$(cat "\$PIDFILE"))"
      ps -o pid,rss,args -p "\$(cat "\$PIDFILE")" 2>/dev/null || true
    else
      echo "未运行"
    fi
    echo "--- 客户端进程 ---"
    ps -eo pid,args | grep "[r]emote-bash-agent.py" || echo "(无)"
    echo "--- 最近日志 ---"
    tail -n 8 "\$LOG" 2>/dev/null || echo "(无日志)"
    ;;
  logs)
    exec tail -n 50 -f "\$LOG"
    ;;
  *)
    echo "用法: \$0 {start|stop|restart|status|logs}"
    exit 1
    ;;
esac
CTL_EOF
  chmod +x "$CTL"
}

install_docker() {
  echo "==> 安装容器模式（无 systemd）"
  write_runner_and_ctl

  pair_now

  echo "==> 启动看护进程（走 ctl，和手动管理同一条路）"
  "$CTL" start || true
  echo "--- 最近日志 ---"
  tail -n 8 "$LOGFILE" 2>/dev/null || true

  echo
  echo "✔ 安装完成（容器模式，无 systemd）。管理："
  echo "  $CTL status        # 状态 + 最近日志"
  echo "  $CTL logs          # tail -f 日志（$LOGFILE）"
  echo "  $CTL restart       # 只重启客户端，不会打断/杀死 tty 里正在跑的任务"
  echo "  $CTL stop          # 停客户端（daemon/tty 保留）"
  echo "  彻底结束某会话: $CTL stop && pkill -f 'remote-bash-agent.py --daemon --name 名称'"
  echo "  重新注册/换 token: python3 $BIN --pair ${DEPLOY_ARGS[*]}"
  echo "  名称: ${NAME}  地址: $URL  心跳: ${HEARTBEAT}s${PROXY:+  代理: $PROXY}  agent: ${AGENT_VERSION:-?}"
  echo "  升级：直接重跑本脚本（不加参数也会沿用上面的配置；daemon 会一并重建）"
  echo
  echo "docker 提示："
  echo "  · 容器重启后 /etc/remote-bash-agent.env 和 ~/.remote-bash/<名称>.token 都会丢；"
  echo "    想保留登录态，把这些路径挂成卷，或用 -e REMOTE_BASH_TOKEN=xxx 传入。"
  echo "  · 想让它当容器主进程（日志进 docker logs、由 restart 策略兜底），"
  echo "    改用:  --foreground"
}

# ---------------------------------------------------------------- 前台（容器主进程）
install_foreground() {
  echo "==> 前台运行（容器主进程模式；退出后由容器的 restart 策略负责重启）"
  echo "    没有 token 时，下面的日志里会打印设备注册链接。"
  echo
  exec python3 "$BIN" "${DEPLOY_ARGS[@]}"
}

# ---------------------------------------------------------------- 主流程：下载校验 → 停旧 → 换新 → 写配置 → 启动
case "$DEPLOY" in
  systemd|docker|foreground) ;;
  *) echo "未知部署模式: $DEPLOY" >&2; exit 1 ;;
esac

if [[ "$DEPLOY" == "docker" ]]; then
  write_runner_and_ctl
fi

stop_existing_client
kill_agent_for_name

mv -f "$BIN_NEW" "$BIN"
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

# 组装客户端参数（数组，避免名称/代理里带空格时被拆开）
DEPLOY_ARGS=(--url "$URL" --heartbeat "$HEARTBEAT")
if [[ -n "$NAME" ]]; then DEPLOY_ARGS+=(--name "$NAME"); fi
if [[ -n "$PROXY" ]]; then DEPLOY_ARGS+=(--proxy "$PROXY"); fi
if [[ -n "$SHELL_CMD" ]]; then DEPLOY_ARGS+=(--shell "$SHELL_CMD"); fi

case "$DEPLOY" in
  systemd) install_systemd ;;
  docker) install_docker ;;
  foreground) install_foreground ;;
esac

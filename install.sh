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
# 行为：
#   1. 下载 remote-bash-agent.py 到 /usr/local/bin/
#   2. 按参数生成 /etc/remote-bash-agent.env（名称/地址/token/代理/心跳）
#   3. 按部署模式启动：
#        systemd    → 安装 remote-bash-agent.service（失败重启、开机自启）
#        docker     → 装一个 5 秒重启的看护进程 + remote-bash-agent-ctl 管理脚本
#        foreground → 直接在前台 exec（当成容器主进程）
#   4. 没有 token 时先在前台跑设备注册，打印浏览器链接
set -euo pipefail

NAME="${REMOTE_BASH_NAME:-}"
URL="${REMOTE_BASH_URL:-wss://edge02.10w123.com/workbench/wss}"
TOKEN="${REMOTE_BASH_TOKEN:-}"
PROXY="${REMOTE_BASH_PROXY:-}"
HEARTBEAT="${REMOTE_BASH_HEARTBEAT:-15}"
SHELL_CMD="${REMOTE_BASH_SHELL:-}"
DEPLOY="${REMOTE_BASH_DEPLOY:-}"          # systemd | docker | foreground
LOGFILE="${REMOTE_BASH_LOG:-/var/log/remote-bash-agent.log}"

BIN=/usr/local/bin/remote-bash-agent.py
ENVFILE=/etc/remote-bash-agent.env
UNIT=remote-bash-agent.service
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
  echo "  $0 [--name 名称] [--url wss://...] [--token xxx] [--proxy http://127.0.0.1:3128]"
  echo "     [--heartbeat 15] [--shell /bin/bash] [--docker | --foreground] [--log /var/log/xxx.log]"
  echo
  echo "部署模式（自动判断，也可显式指定）:"
  echo "  默认     有 systemd 就用 systemd，没有就自动退化成 docker 模式"
  echo "  --docker 不装 systemd：后台看护进程 + remote-bash-agent-ctl 管理（适合容器里常驻）"
  echo "  --foreground 直接前台运行，不做守护（适合作为容器主进程/Dockerfile CMD）"
  echo
  echo "也可用环境变量: REMOTE_BASH_NAME / REMOTE_BASH_URL / REMOTE_BASH_TOKEN / REMOTE_BASH_PROXY"
  echo "                REMOTE_BASH_HEARTBEAT / REMOTE_BASH_SHELL / REMOTE_BASH_DEPLOY / REMOTE_BASH_LOG"
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

# ---------------------------------------------------------------- 下载 & 配置
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

# 组装客户端参数（数组，避免名称/代理里带空格时被拆开）
DEPLOY_ARGS=(--url "$URL" --heartbeat "$HEARTBEAT")
if [[ -n "$NAME" ]]; then DEPLOY_ARGS+=(--name "$NAME"); fi
if [[ -n "$PROXY" ]]; then DEPLOY_ARGS+=(--proxy "$PROXY"); fi
if [[ -n "$SHELL_CMD" ]]; then DEPLOY_ARGS+=(--shell "$SHELL_CMD"); fi

# ---------------------------------------------------------------- 设备注册
pair_now() {
  [[ -n "$TOKEN" ]] && return 0
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
  fetch remote-bash-agent.service "/etc/systemd/system/$UNIT" || { echo "下载 unit 失败" >&2; exit 1; }
  systemctl daemon-reload

  pair_now

  echo "==> 启用并启动"
  systemctl enable --now "$UNIT" || true
  sleep 2
  systemctl status "$UNIT" --no-pager 2>&1 | head -12 || true

  echo
  echo "✔ 安装完成（systemd）。管理："
  echo "  systemctl status  $UNIT        # 查看状态"
  echo "  journalctl -u $UNIT -f         # 实时日志"
  echo "  systemctl edit    $UNIT        # 修改参数（或编辑 $ENVFILE 后 systemctl restart $UNIT）"
  echo "  重新注册/换 token: python3 $BIN --pair ${DEPLOY_ARGS[*]}"
  echo "  systemctl restart $UNIT        # 只重启客户端，不会打断/杀死 tty 里正在跑的任务"
  echo "  彻底结束某会话: systemctl stop $UNIT && pkill -f 'remote-bash-agent.py --daemon --name 名称'"
  echo "  名称: ${NAME:-<主机名>}  地址: $URL  心跳: ${HEARTBEAT}s${PROXY:+  代理: $PROXY}"
}

# ---------------------------------------------------------------- docker（无 systemd）
install_docker() {
  echo "==> 安装容器模式（无 systemd）"

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

  # 幂等：重装时先停掉已在跑的看护进程（daemon 不杀，tty 会话照旧保留）
  if [[ -x "$CTL" ]]; then "$CTL" stop >/dev/null 2>&1 || true; fi
  pkill -f "remote-bash-agent-run.sh" 2>/dev/null || true
  sleep 1

  pair_now

  echo "==> 启动看护进程"
  mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
  setsid nohup sh "$RUNNER" >>"$LOGFILE" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  sleep 2
  if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    echo "    已在后台运行 (pid $(cat "$PIDFILE"))"
  else
    echo "⚠ 启动失败，查看：tail -n 50 $LOGFILE" >&2
  fi
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
  echo "  名称: ${NAME:-<主机名>}  地址: $URL  心跳: ${HEARTBEAT}s${PROXY:+  代理: $PROXY}"
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

case "$DEPLOY" in
  systemd) install_systemd ;;
  docker) install_docker ;;
  foreground) install_foreground ;;
  *) echo "未知部署模式: $DEPLOY" >&2; exit 1 ;;
esac

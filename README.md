# wss-client-pty

把**任意一台机器(Windows / macOS / Linux)的 tty 终端**挂到 message-hub workbench 的远程终端面板，浏览器里就能列出并控制它——类似远程 shell / 反向终端。

```
┌──────────────┐   wss(15s心跳)   ┌──────────────────┐   unix socket   ┌────────────┐
│  浏览器前端    │ ───────────────▶ │  server (node)    │ ───────────────▶ │ 本机 daemon │──▶ shell(tty)
│  remote bash  │ ◀─────────────── │  /workbench/wss   │ ◀─────────────── │  常驻持有   │
└──────────────┘                  └──────────────────┘                  └────────────┘
      客户端脚本 = 连 wss 的前端 + 连本地 daemon 的桥（本仓库）
```

- **daemon 架构**：常驻 daemon 进程持有 shell(tty)。客户端(agent)只是桥——**agent 退出 / 崩溃 / 重启，shell 会话仍在继续**，下次启动自动接回同一个会话，正在跑的命令不会中断。
- **15 秒心跳**默认，保持长连接不被代理 / NAT 掐断（`--heartbeat` 可调）。
- **HTTP 代理**支持（`--proxy http://127.0.0.1:3128`，走 CONNECT 隧道），且会注入持久 shell 环境：daemon 拉起的 shell 及其子进程（git/curl/pip/npm）自动走该代理，`NO_PROXY=localhost,127.0.0.1,::1` 避免本机流量被劫持。（已运行的旧 daemon 需重启服务重建：`systemctl restart remote-bash-agent`）
- **断线重连**：指数退避 + 抖动（2s → 30s，`RECONNECT_MAX`），连上后自动重置；断线期间 tty 输出暂存在内存（上限 1MB）后补发。
- **daemon 崩了会自愈**：agent 发现本地 daemon 消失会自动重新拉起（无需人工介入，`systemctl restart` 都不用）。
- **大输出不丢数据**：daemon 给每个 client 维护独立发送队列 + select 写就绪 + 反压（积压时暂停读 pty，由 pty 让 shell 自然阻塞），实测 `seq 1 300000`（≈2.3MB）**零丢块**、吞吐约 1–2MB/s。
- **可选 token 鉴权**（服务端 `REMOTE_BASH_TOKEN`，客户端 `--token`；浏览器侧用 `REMOTE_BASH_VIEWER_TOKEN`）。
- **同名去重**：同一台机器同名重连会替换旧连接（并让旧进程退出），不会再出现"幽灵卡片"。
- 零依赖：标准库 `socket + ssl` 手写 WebSocket 帧，任何机器有 python3 就能跑；装了 `websocket-client` 则走库。

## 快速开始（远端机器）

```bash
# 方式一：下载脚本直接跑
curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/remote-bash-agent.py -o remote-bash-agent.py
python3 remote-bash-agent.py --name win10 --url wss://edge02.10w123.com/workbench/wss

# 方式二：经本机 HTTP 代理连出
python3 remote-bash-agent.py --name mac-air --proxy http://127.0.0.1:3128
```

然后浏览器打开 workbench → 顶部 **remote bash** → 左侧出现这台机器 → 点击即可控制其 tty。

## 一键安装（systemd 机器 / docker 容器都能用）

脚本会自己判断环境：**有运行中的 systemd 就装 systemd 服务，没有（容器/精简镜像）就自动切到容器模式**，
也可以用 `--docker` / `--foreground` 显式指定。

```bash
# 普通主机：装成 systemd 服务，开机自启，崩溃/被杀 5 秒后自动拉起（client 重启会接回原 shell 会话）
curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- \
  --name win10 --url wss://edge02.10w123.com/workbench/wss --proxy http://127.0.0.1:3128

# docker / 容器里常驻（无 systemd）：后台看护进程 + remote-bash-agent-ctl 管理
curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- --name web01 --docker

# 容器主进程（前台跑，日志直接进 docker logs，重启交给容器的 restart 策略）
curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- --name web01 --foreground

# 也可以全用环境变量
REMOTE_BASH_NAME=win10 REMOTE_BASH_PROXY=http://127.0.0.1:3128 \
  curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash
```

### 有 systemd 的机器

```bash
systemctl status  remote-bash-agent     # 状态
journalctl -u remote-bash-agent -f      # 日志
systemctl restart remote-bash-agent     # 重启（只重启客户端，tty 里的任务不受影响）
```

### docker / 容器（没有 systemd）

`--docker` 会装一个看护脚本（客户端退出 5 秒后重启）和管理命令，不会去碰 systemd：

```bash
remote-bash-agent-ctl status    # 运行状态 + 最近日志
remote-bash-agent-ctl logs      # tail -f /var/log/remote-bash-agent.log
remote-bash-agent-ctl restart   # 只重启客户端，daemon/tty 不受影响
remote-bash-agent-ctl stop      # 停客户端（daemon 保留，start 后接回同一会话）
```

`--foreground` 则直接在前台 `exec` 客户端，适合写进 Dockerfile 的 `CMD`：

```dockerfile
FROM python:3-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh \
    | bash -s -- --name web01 --foreground
```

或者更省事，直接用一次性的容器跑安装 + 前台运行：

```bash
docker run -d --name rb-agent --restart=unless-stopped \
  -e REMOTE_BASH_TOKEN=你的token \
  -v rb-agent-state:/root/.remote-bash \
  python:3-slim \
  bash -c "apt-get update && apt-get install -y curl ca-certificates && \
           curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | \
           bash -s -- --name web01 --foreground"
```

容器里要注意两点：

- `/etc/remote-bash-agent.env` 和 `~/.remote-bash/<名称>.token` 都在容器可写层里，**容器重建就丢**。
  想保留登录态就挂卷（`-v rb-agent-state:/root/.remote-bash`），或者直接用 `-e REMOTE_BASH_TOKEN=xxx` 传 token。
- 没有 token 时首次运行会打印设备注册链接。`--docker` 模式会在前台先打印链接再转后台；
  `--foreground` 模式下链接打在容器日志里，`docker logs -f rb-agent | grep rb_pair` 看。

## 完整参数

| 参数 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--name` | `REMOTE_BASH_NAME` | 主机名 | 客户端显示名 = 会话名，daemon 按它持久化 |
| `--url` | `REMOTE_BASH_URL` | `wss://edge02.10w123.com/workbench/wss` | workbench WebSocket 地址 |
| `--token` | `REMOTE_BASH_TOKEN` | 空 | 可选鉴权口令（服务端必须相同） |
| `--proxy` | `REMOTE_BASH_PROXY` / `http_proxy` | 空 | HTTP 代理（CONNECT 隧道）；同时注入持久 shell 环境（`http_proxy`/`https_proxy`/`NO_PROXY`），shell 内 git/curl/pip 自动走代理 |
| `--heartbeat` | `REMOTE_BASH_HEARTBEAT` | 15 | 心跳间隔秒 |
| `--scrollback` | `REMOTE_BASH_SCROLLBACK` | 4096 | 回放缓冲大小（KB）。daemon 保留最近这么多输出，断连重连后补发；4MB 约可回看几万行 |
| `--shell` | `REMOTE_BASH_SHELL` | `$SHELL`/`/bin/bash` | 远端 shell（Windows 可 `--shell powershell`） |
| `--docker` | `REMOTE_BASH_DEPLOY=docker` | 自动 | 容器模式：不装 systemd，用 `remote-bash-agent-ctl` 管理（客户端退出 5 秒后自动重启） |
| `--foreground` | `REMOTE_BASH_DEPLOY=foreground` | 自动 | 前台运行，不做守护（适合作为容器主进程 / Dockerfile CMD） |
| `--log` | `REMOTE_BASH_LOG` | `/var/log/remote-bash-agent.log` | 容器模式下的日志文件路径 |
| `--daemon` | — | — | 只跑常驻 daemon（持有 tty） |
| `--no-daemon` | — | — | 不自动拉起 daemon（连接已存在的） |

## 数据与状态

- 会话状态目录：`~/.remote-bash/`（daemon 的 unix socket + 日志，环境变量 `REMOTE_BASH_STATE` 可改）
- **daemon 是唯一持有 tty 的进程**。要彻底结束某个会话：`systemctl stop remote-bash-agent`（容器里是 `remote-bash-agent-ctl stop`）后还需杀掉对应 daemon：`pkill -f "remote-bash-agent.py --daemon --name <名称>"`（或删掉 `~/.remote-bash/<名称>.sock`）

## 重启客户端不影响 tty（关键）

`systemctl restart remote-bash-agent` **只重启"客户端(桥)"进程，不会碰 daemon 和它持有的 shell**：

- unit 里配置了 `KillMode=process`（否则 systemd 默认会把整个 cgroup 一起杀掉，daemon 和 tty 会跟着死）
- 重启后新客户端连回同一个 daemon，屏幕内容由回放补齐，`vim` / `make` / `sleep` 之类正在跑的任务继续
- 已实测：重启前后 daemon PID 不变，shell 里 `for i in $(seq 1 60); do echo TICK_$i; sleep 1; done` 在重启期间持续输出

> 注意：**`systemctl stop` 同样不会杀死 tty**（这是故意的）。要彻底结束一个会话，需要 `systemctl stop remote-bash-agent` 之后手动杀掉对应 daemon（见下方"daemon 是唯一持有 tty 的进程"）。

## 会话恢复原理

1. agent 启动时连接本地 daemon 的 unix socket（没有 daemon 就自动拉起）。
2. daemon 里 `pty.fork()` 出来的 shell 进程与 agent 完全独立。
3. agent 崩溃 / 系统重启 agent 服务 → shell 不受影响（daemon 仍在）。
4. agent 再次启动 → 重新连回同一 daemon → 接回 shell 会话，继续输入输出。
5. **屏幕内容回放**：daemon 保留最近 `--scrollback`（默认 4MB）输出，新 agent 连上来按 256KB 分块补发；agent 注册成功后同样分块把历史发给服务端；服务端为新 attach 的 viewer 分块回放。所以断连重连、甚至 agent 进程重启后，浏览器打开 remote bash 仍能看到断线前的屏幕（几万行），不会只剩“已连接”。
   - 想回看更多：客户端加 `--scrollback 8192`（8MB）或设 `REMOTE_BASH_SCROLLBACK`；服务端可用 `REMOTE_BASH_SCROLLBACK`（默认 4096KB）和 `REMOTE_BASH_MAX_SCROLLBACK`（默认 32768KB，即客户端最多能申请到 32MB）限制上限。
   - 浏览器端 xterm 默认保留 5 万行滚动历史，可用 `localStorage.rb_scrollback = 200000` 调整。
   - 改了 `--scrollback` 需要重建 daemon 才生效：`systemctl stop remote-bash-agent && pkill -f 'remote-bash-agent.py --daemon --name <名称>'`，再 `systemctl start remote-bash-agent`。
6. **稳定客户端 id**：id 由 `名称 + 主机名` 哈希得出，重连后不变，浏览器面板可自动接回原客户端（不用重新点卡片）。

## 安装后怎么注册（不用手工拷 token）

安装脚本跑完会直接打印一个链接（像 `tailscale up` 那样）：

```
==================================================================
  设备还没注册。用浏览器打开下面链接，点「允许」即可（像 tailscale 一样）：
    https://edge02.10w123.com/workbench/?rb_pair=6SDD-8FFU
  配对码 6SDD-8FFU   有效期 600 秒
==================================================================
```

1. 在浏览器打开这个链接（已经登录过 workbench 就不用再输密码）；
2. 弹窗里核对 名称/主机/系统/IP，点 **允许接入**；
3. 客户端自己拿到 token，存到 `~/.remote-bash/<名称>.token`（0600），随后正常上线。

想重新注册（换了机器名、token 被吊销）：

```bash
sudo remote-bash-agent.py --pair --name 名称
```

几点说明：

- 服务端把每个设备的 token 存成 sha256（`data/remote-bash-devices.json`，0600），可用
  `GET /api/remote/devices` 查看、`DELETE /api/remote/devices/<id>` 吊销；吊销后客户端会在 60s 内自动重新发起配对。
- 老的客户端脚本（不会配对）也不会被一刀切：它被拒时会登记成一条待批准记录，管理员在弹窗里点允许后按 `名称+主机名` 放行（列表里显示 `tokenless`）。升级到新版后就会走 token。
- 不想启用门禁：服务端设 `REMOTE_BASH_REQUIRE_TOKEN=0`（默认开启）。也仍支持 `REMOTE_BASH_TOKEN` 静态口令兜底。
- 配对码 10 分钟过期；`/api/remote/pair/start` 与 `/api/remote/pair/poll` 在 nginx 上免 Basic Auth（靠一次性码 + pollSecret），而 `approve/deny` 必须登录通过。

## 两个入口的分工（安全相关）

服务端有两个 WebSocket 入口，**角色是强制校验的**，走错入口会被 1008 关闭：

| 入口 | 谁用 | 鉴权 |
|---|---|---|
| `wss://<host>/workbench/wss` | 远端客户端（agent） | nginx 免 Basic Auth；可选 `REMOTE_BASH_TOKEN`（agent 用 `--token`，服务端同名环境变量） |
| `wss://<host>/workbench/viewer-ws` | 浏览器（viewer） | 由 nginx `auth_basic` 保护（同一站点已登录即可自动带上凭据），另可选 `REMOTE_BASH_VIEWER_TOKEN` |

这样即使公网地址泄漏，也不能拿它当 viewer 直接接管别人的 tty。客户端列表里会显示每台 agent 的 `version`，据此可判断哪台还在跑旧脚本。

## 协议简述

- **wss 端**（与 server `remote-bash.js` 一致）：JSON 文本帧。`hello(agent, name, host, os, arch, heartbeat, token?)` → 服务端回 `hello{ok, id, name}`；`data(base64)` 双向传 tty；`input`/`resize`/`ping`/`pong`；服务端在“同名重连替换旧连接”时发 `{type:'replaced'}`，被替换的 agent 主动退出（避免来回抢连接）。
- **本地 unix socket**：长度前缀帧 `[1B type][4B len][payload]`；`0x01` 数据、`0x02` resize、`0x03` hello。

## License

MIT
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

## 一键安装为 systemd 服务（失败自动重启）

```bash
# 装成 systemd 服务，开机自启，进程崩溃/被杀 5 秒后自动拉起（client 重启会接回原 shell 会话）
curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash -s -- \
  --name win10 --url wss://edge02.10w123.com/workbench/wss --proxy http://127.0.0.1:3128

# 也可以全用环境变量
REMOTE_BASH_NAME=win10 REMOTE_BASH_PROXY=http://127.0.0.1:3128 \
  curl -fsSL https://raw.githubusercontent.com/deepseekretro/wss-client-pty/main/install.sh | bash
```

管理：

```bash
systemctl status  remote-bash-agent     # 状态
journalctl -u remote-bash-agent -f      # 日志
systemctl restart remote-bash-agent     # 重启
```

## 完整参数

| 参数 | 环境变量 | 默认 | 说明 |
|---|---|---|---|
| `--name` | `REMOTE_BASH_NAME` | 主机名 | 客户端显示名 = 会话名，daemon 按它持久化 |
| `--url` | `REMOTE_BASH_URL` | `wss://edge02.10w123.com/workbench/wss` | workbench WebSocket 地址 |
| `--token` | `REMOTE_BASH_TOKEN` | 空 | 可选鉴权口令（服务端必须相同） |
| `--proxy` | `REMOTE_BASH_PROXY` / `http_proxy` | 空 | HTTP 代理（CONNECT 隧道）；同时注入持久 shell 环境（`http_proxy`/`https_proxy`/`NO_PROXY`），shell 内 git/curl/pip 自动走代理 |
| `--heartbeat` | `REMOTE_BASH_HEARTBEAT` | 15 | 心跳间隔秒 |
| `--shell` | `REMOTE_BASH_SHELL` | `$SHELL`/`/bin/bash` | 远端 shell（Windows 可 `--shell powershell`） |
| `--daemon` | — | — | 只跑常驻 daemon（持有 tty） |
| `--no-daemon` | — | — | 不自动拉起 daemon（连接已存在的） |

## 数据与状态

- 会话状态目录：`~/.remote-bash/`（daemon 的 unix socket + 日志，环境变量 `REMOTE_BASH_STATE` 可改）
- **daemon 是唯一持有 tty 的进程**。要彻底结束某个会话：`systemctl stop remote-bash-agent` 后还需杀掉对应 daemon：`pkill -f "remote-bash-agent.py --daemon --name <名称>"`（或删掉 `~/.remote-bash/<名称>.sock`）

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
5. **屏幕内容回放**：daemon 保留最近 256KB 输出，新 agent 连上来先补发；agent 注册成功后会把历史发给服务端；服务端为新 attach 的 viewer 回放。所以断连重连、甚至 agent 进程重启后，浏览器打开 remote bash 仍能看到断线前的屏幕，不会只剩“已连接”。
6. **稳定客户端 id**：id 由 `名称 + 主机名` 哈希得出，重连后不变，浏览器面板可自动接回原客户端（不用重新点卡片）。

## 协议简述

- **wss 端**（与 server `remote-bash.js` 一致）：JSON 文本帧。`hello(agent, name, host, os, arch, heartbeat, token?)` → 服务端回 `hello{ok, id, name}`；`data(base64)` 双向传 tty；`input`/`resize`/`ping`/`pong`；服务端在“同名重连替换旧连接”时发 `{type:'replaced'}`，被替换的 agent 主动退出（避免来回抢连接）。
- **本地 unix socket**：长度前缀帧 `[1B type][4B len][payload]`；`0x01` 数据、`0x02` resize、`0x03` hello。

## License

MIT
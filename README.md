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
- **HTTP 代理**支持（`--proxy http://127.0.0.1:3128`，走 CONNECT 隧道）。
- **断线重连**：指数退避自动重连；断线期间 tty 输出暂存在内存（上限 1MB）后补发。
- **可选 token 鉴权**（服务端 `REMOTE_BASH_TOKEN`，客户端 `--token`）。
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
| `--proxy` | `REMOTE_BASH_PROXY` / `http_proxy` | 空 | HTTP 代理（CONNECT 隧道） |
| `--heartbeat` | `REMOTE_BASH_HEARTBEAT` | 15 | 心跳间隔秒 |
| `--shell` | `REMOTE_BASH_SHELL` | `$SHELL`/`/bin/bash` | 远端 shell（Windows 可 `--shell powershell`） |
| `--daemon` | — | — | 只跑常驻 daemon（持有 tty） |
| `--no-daemon` | — | — | 不自动拉起 daemon（连接已存在的） |

## 数据与状态

- 会话状态目录：`~/.remote-bash/`（daemon 的 unix socket + 日志，环境变量 `REMOTE_BASH_STATE` 可改）
- **daemon 是唯一持有 tty 的进程**。要彻底结束某个会话：`systemctl stop remote-bash-agent` 后还需杀掉对应 daemon：`pkill -f "remote-bash-agent.py --daemon --name <名称>"`（或删掉 `~/.remote-bash/<名称>.sock`）

## 会话恢复原理

1. agent 启动时连接本地 daemon 的 unix socket（没有 daemon 就自动拉起）。
2. daemon 里 `pty.fork()` 出来的 shell 进程与 agent 完全独立。
3. agent 崩溃 / 系统重启 agent 服务 → shell 不受影响（daemon 仍在）。
4. agent 再次启动 → 重新连回同一 daemon → 接回 shell 会话，继续输入输出。

## 协议简述

- **wss 端**（与 server `remote-bash.js` 一致）：JSON 文本帧。`hello(agent)` → 服务端回 `hello{ok}`；`data(base64)` 双向传 tty；`input`/`resize`/`ping`/`pong`。
- **本地 unix socket**：长度前缀帧 `[1B type][4B len][payload]`；`0x01` 数据、`0x02` resize、`0x03` hello。

## License

MIT
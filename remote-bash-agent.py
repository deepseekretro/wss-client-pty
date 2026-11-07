#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
remote-bash-agent.py — 把本机 tty 挂到 message-hub workbench 的 WebSocket 服务上，
让浏览器端（顶部导航「remote bash」）能列出并控制本机终端。

特性:
  * daemon 架构: 常驻 daemon 持有 tty(shell) 进程；client 只是前端。
    退出/重启 client 不影响 shell —— 下次启动自动重连同一会话，命令继续跑。
  * 15 秒心跳保活（可 --heartbeat 调整）。
  * 断线自动指数退避重连，断线期间的 tty 输出暂存在内存（最多 1MB）后补发。
  * 支持经 HTTP 代理连接（--proxy，如 http://127.0.0.1:3128）。
  * 可选鉴权 token（--token，服务端 REMOTE_BASH_TOKEN）。

用法:
    # 前台（自动拉起/连接 daemon）
    python3 remote-bash-agent.py --name win10 --url wss://edge02.10w123.com/workbench/wss
    # 经本机 HTTP 代理
    python3 remote-bash-agent.py --name win10 --proxy http://127.0.0.1:3128
    # 只跑 daemon（常驻持有 tty，供多个 client 连接）
    python3 remote-bash-agent.py --daemon --name win10

协议: 与 server 端 remote-bash.js 一致的 JSON 文本帧；tty 数据 base64。
daemon 本地通信: unix socket + 长度前缀帧（type 0x01 数据 / 0x02 resize）。

系统需求: python3.7+。Linux/macOS 用 pty(推荐)；Windows 降级为进程内管道。
"""

import argparse
import base64
import json
import os
import platform
import random
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time

try:
    import pty
    import fcntl
    import termios
    _HAS_PTY = True
except ImportError:  # Windows
    _HAS_PTY = False

try:
    import websocket  # websocket-client (可选)
except ImportError:
    websocket = None

RECONNECT_BASE = 2.0
RECONNECT_MAX = 30.0
BUFFER_LIMIT = 1024 * 1024  # 断线暂存上限 1MB
# 最近输出回放缓冲默认大小（KB，可用 --scrollback / REMOTE_BASH_SCROLLBACK 调整）
def _env_int(name, default):
    try:
        v = int(str(os.environ.get(name, '')).strip())
        return v if v > 0 else default
    except (TypeError, ValueError):
        return default


SCROLLBACK_KB = _env_int('REMOTE_BASH_SCROLLBACK', 4096)   # 默认 4MB
SCROLLBACK_LIMIT = SCROLLBACK_KB * 1024
# daemon -> client 的初始回放分块（避免一次性几 MB 的帧）
REPLAY_CHUNK = 256 * 1024
REPLAY_ALIGN_MAX = 1024
HANDSHAKE_TIMEOUT = 15      # WebSocket 握手超时（秒）
def _local_user():
    try:
        import getpass
        return getpass.getuser() or ''
    except Exception:
        return ''

VERSION = '1.6.2'            # 客户端版本（服务端列表里可看出谁还是旧脚本）
DEFAULT_HEARTBEAT = 15      # 秒
# daemon -> client 发送队列水位：超过后暂停读 pty（pty 满则 shell 阻塞，不丢数据）
CLIENT_HIGH_WATER = 512 * 1024
# 单个 client 积压硬上限：只可能是卡死的客户端，断开它（重连会靠回放重新对齐）
CLIENT_OUTBUF_LIMIT = 8 * 1024 * 1024

# ---------- 本地 daemon 帧协议 ----------
FRAME_DATA = 0x01   # payload: 裸 tty 字节
FRAME_RESIZE = 0x02  # payload: struct '<HH' (cols, rows)
FRAME_HELLO = 0x03  # client -> daemon: payload: 名称（UTF-8）

# ---------- DEC 私有模式跟踪与补发 ----------
# 这些模式只活在输出流里，xterm 是边收边记的。重连只回放 scrollback 尾部，应用启动时
# 那句 ESC[?2004h（bracketed paste）早被挤出去 —— 浏览器新 xterm 于是以为应用没开
# bracketed paste，粘贴多行文本就把换行当裸 CR 发（每行一次回车，远端 pi 里就是被逐行
# 提交，而不是折叠成 [paste #N]）。所以这里跟踪模式，client 接入时先补发再回放。
# 备用屏/同步刷新类不补发：补发 1049h 会让「重连能看到历史回放」变成只剩一屏。
MODE_TAIL_MAX = 64
MODE_RESTORE_SKIP = frozenset((3, 6, 47, 66, 1047, 1048, 1049, 2026))
MODE_RE = re.compile(rb'\x1b\[\?([0-9]{1,4}(?:;[0-9]{1,4})*)([hl])')


def scan_modes(state, chunk):
    """更新 state['modes']（幂等；转义序列被读断也能靠尾部缓存接上）。"""
    if not chunk:
        return
    text = state['tail'] + chunk
    for m in MODE_RE.finditer(text):
        on = m.group(2) == b'h'
        for part in m.group(1).split(b';'):
            try:
                n = int(part)
            except ValueError:
                continue
            if n <= 0:
                continue
            if on:
                state['modes'].add(n)
            else:
                state['modes'].discard(n)
    state['tail'] = text[-MODE_TAIL_MAX:]


def mode_restore_seq(state):
    """生成「把当前模式补一遍」的字节串；没有可补的返回 b''。"""
    nums = sorted(n for n in state['modes'] if n not in MODE_RESTORE_SKIP)
    if not nums:
        return b''
    return ('\x1b[?%sh' % ';'.join(str(n) for n in nums)).encode()


# --------------------------------------------------------------------------
# daemon：常驻持有 tty 的独立进程
# --------------------------------------------------------------------------
class TtyDaemon:
    """持有 pty shell + 监听 unix socket；client 通过 socket 读写 tty。"""

    def __init__(self, sock_path, shell_cmd, log_file=None, scrollback_limit=None):
        self.sock_path = sock_path
        self.shell_cmd = shell_cmd
        self.log_file = log_file
        self.master = None
        self.pid = None
        self.clients = []       # [(sock, read_buf, write_buf)]
        self.server = None
        self._buf = b''
        self.scrollback = bytearray()   # 最近输出，用于新 client 连接时回放（保持屏幕内容）
        self.scrollback_limit = scrollback_limit or SCROLLBACK_LIMIT
        self.mode_state = {'modes': set(), 'tail': b''}  # 见 scan_modes

    # ---- pty ----
    def _spawn_shell(self):
        if not _HAS_PTY:
            raise RuntimeError('daemon 需要 pty 支持（Linux/macOS）')
        pid, master = pty.fork()
        if pid == 0:
            env = os.environ.copy()
            # systemd system 服务不设置 HOME/USER/LOGNAME，补全基础变量，
            # 否则 shell 里用到 $HOME 的脚本（如 Pi Installer）报
            # "HOME: parameter not set"。
            try:
                import pwd
                pw = pwd.getpwuid(os.getuid())
                env.setdefault('HOME', pw.pw_dir)
                env.setdefault('USER', pw.pw_name)
                env.setdefault('LOGNAME', pw.pw_name)
            except Exception:
                env.setdefault('HOME', os.path.expanduser('~') or '/')
            env.setdefault('SHELL', self.shell_cmd)
            env['TERM'] = env.get('TERM', 'xterm-256color')
            env['LANG'] = env.get('LANG', 'C.UTF-8')
            os.execvpe(self.shell_cmd, [self.shell_cmd], env)
        self.pid, self.master = pid, master
        fl = fcntl.fcntl(self.master, fcntl.F_GETFL)
        fcntl.fcntl(self.master, fcntl.F_SETFL, fl | os.O_NONBLOCK)
        self._set_winsize(100, 30)

    def _set_winsize(self, cols, rows):
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                        struct.pack('HHHH', rows, cols, 0, 0))
        except Exception:
            pass

    # ---- unix socket ----
    def _start_socket(self):
        try:
            if os.path.exists(self.sock_path):
                os.unlink(self.sock_path)
        except OSError:
            pass
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.sock_path)
        self.server.listen(8)
        self.server.setblocking(False)
        # 只有当前用户能连 daemon（daemon 持有的是登录 shell）
        try:
            os.chmod(self.sock_path, 0o600)
        except OSError:
            pass

    # ---- 帧编解码 ----
    @staticmethod
    def encode_frame(ftype, payload=b''):
        return struct.pack('>BI', ftype, len(payload)) + payload

    @staticmethod
    def recv_frame(sock, buf):
        """从 buf 里解一帧；不足返回 None。返回 (ftype, payload, rest_buf)"""
        if len(buf) < 5:
            return None
        ftype, plen = struct.unpack('>BI', buf[:5])
        if len(buf) < 5 + plen:
            return None
        payload = buf[5:5 + plen]
        return ftype, payload, buf[5 + plen:]

    # ---- 主循环 ----
    def run(self):
        self._spawn_shell()
        self._start_socket()
        self._log(f'daemon 启动: shell={self.shell_cmd} pid={self.pid} sock={self.sock_path}')

        while True:
            # 反压：有 client 严重积压时暂停读 master（pty 满后 shell 自然阻塞，不丢数据）
            backlog = max((len(p[2]) for p in self.clients), default=0)
            watch_read = [self.server] if backlog > CLIENT_HIGH_WATER else [self.server, self.master]
            watch_read += [p[0] for p in self.clients]
            watch_write = [p[0] for p in self.clients if p[2]]
            try:
                ready, writable, _ = select.select(watch_read, watch_write, [], 1.0)
            except (OSError, ValueError):
                break

            for fd in ready:
                if fd is self.server:
                    self._accept()
                elif fd is self.master:
                    self._pump_master()
                else:
                    self._read_client(fd)

            # 写就绪：把积压的帧尽量发出去（非阻塞，发不完下一轮继续）
            for fd in writable:
                self._flush_client(fd)

            # 兼容旧客户端（不发 FRAME_HELLO）：连上 0.5s 还没打招呼也回放
            now_ts = time.time()
            for pair in list(self.clients):
                if pair[3] and now_ts - pair[3] > 0.5:
                    pair[3] = 0
                    self._queue_replay(pair)
                    self._flush_client(pair[0])

            # master 读不到 & 子进程已退出 -> daemon 结束
            if not self._shell_alive():
                self._log('shell 已退出，daemon 退出')
                return

    def _accept(self):
        try:
            conn, _ = self.server.accept()
        except OSError:
            return
        conn.setblocking(False)
        # 新 client 接入：先不回放，等它发 FRAME_HELLO 再补发。
        # 这样 is_daemon_alive() 那种「连上就关」的探活不会让 daemon 白推几 MB。
        # pair[3]：还没打招呼时的接入时间戳（0 表示已打过招呼），用于兼容旧客户端
        self.clients.append([conn, b'', b'', time.time()])
        self._flush_client(conn)

    def _pump_master(self):
        try:
            data = os.read(self.master, 65536)
        except BlockingIOError:
            return
        except OSError:
            data = b''
        if not data:
            return
        # 记录 DEC 私有模式（bracketed paste / 鼠标 …），新 client 接入时要补发
        scan_modes(self.mode_state, data)
        # 累积最近输出供回放（环形，上限 SCROLLBACK_LIMIT）
        self.scrollback += data
        over = len(self.scrollback) - self.scrollback_limit
        if over > 0:
            # 裁剪点对齐到最近的 ESC：硬切会把转义序列切成两半，回放时那半截没有
            # ESC 开头，xterm 只会把 `2;176;196;124m` 之类按字面打印出来
            idx = self.scrollback.rfind(b'\x1b', max(0, over - REPLAY_ALIGN_MAX), over)
            if idx != -1:
                over = idx
            del self.scrollback[:over]
        frame = self.encode_frame(FRAME_DATA, data)
        for pair in list(self.clients):
            if len(pair[2]) > CLIENT_OUTBUF_LIMIT:
                # 积压超限：客户端卡死/极慢，断开它（重连后靠回放重新对齐，不会静默丢块）
                self._drop_client(pair[0])
                continue
            pair[2] += frame
            self._flush_client(pair[0])

    def _read_client(self, fd):
        pair = next((p for p in self.clients if p[0] is fd), None)
        if pair is None:
            return
        try:
            chunk = fd.recv(65536)
        except BlockingIOError:
            return
        except OSError:
            chunk = b''
        if not chunk:
            self._drop_client(fd)
            return
        pair[1] += chunk
        while True:
            got = self.recv_frame(fd, pair[1])
            if got is None:
                break
            ftype, payload, pair[1] = got
            if ftype == FRAME_DATA and payload:
                self._write_master(payload)
            elif ftype == FRAME_RESIZE and len(payload) >= 4:
                cols, rows = struct.unpack('<HH', payload[:4])
                self._set_winsize(cols, rows)
            elif ftype == FRAME_HELLO:
                self._log(f'client 接入: {payload.decode("utf-8", "replace")}')
                pair[3] = 0
                self._queue_replay(pair)


    def _queue_replay(self, pair):
        """回放前先补发应用当前的 DEC 私有模式，再按 REPLAY_CHUNK 分块回放内容。"""
        restore = mode_restore_seq(self.mode_state)
        if restore:
            pair[2] += self.encode_frame(FRAME_DATA, restore)
        if not self.scrollback:
            return
        data = bytes(self.scrollback)
        for i in range(0, len(data), REPLAY_CHUNK):
            pair[2] += self.encode_frame(FRAME_DATA, data[i:i + REPLAY_CHUNK])

    def _flush_client(self, fd):
        """非阻塞发送：发出多少算多少，剩下的留在队列里，等 select 写就绪继续。"""
        pair = next((p for p in self.clients if p[0] is fd), None)
        if pair is None or not pair[2]:
            return
        try:
            n = fd.send(pair[2])
            if n:
                pair[2] = pair[2][n:]
        except BlockingIOError:
            pass
        except OSError:
            self._drop_client(fd)

    def _write_master(self, data):
        if self.master is None:
            return
        # master 是非阻塞 fd：os.write 可能只写进一部分（pty 缓冲满时返回
        # 短写），只写一次会把超长单行命令/粘贴的后半截静默丢掉
        # （表现为远端只收到一半）。必须循环写完剩余部分。
        view = memoryview(data)
        off = 0
        while off < len(view):
            try:
                n = os.write(self.master, view[off:])
            except BlockingIOError:
                # 缓冲满：等可写再继续（shell 读走后自然腾空）
                try:
                    select.select([], [self.master], [], 5)
                except (OSError, ValueError):
                    break
                continue
            except InterruptedError:
                continue
            except OSError:
                break
            if n <= 0:
                break
            off += n

    def _shell_alive(self):
        if self.pid is None:
            return False
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid == 0
        except ChildProcessError:
            return False

    def _drop_client(self, fd):
        self.clients = [p for p in self.clients if p[0] is not fd]
        try:
            fd.close()
        except OSError:
            pass

    def _log(self, msg):
        line = f'[{time.strftime("%Y-%m-%d %H:%M:%S")}] {msg}'
        if self.log_file:
            try:
                with open(self.log_file, 'a') as f:
                    f.write(line + '\n')
            except OSError:
                pass
        else:
            print(line, flush=True)


# --------------------------------------------------------------------------
# client 侧连接 daemon 的封装（与 PtyTty 接口一致，供 Reactor 复用）
# --------------------------------------------------------------------------
class DaemonTty:
    """通过 unix socket 连接 daemon，读写远端 tty。"""

    def __init__(self, sock_path, name='client'):
        self.sock_path = sock_path
        self.name = name
        self.sock = None
        self._buf = b''

    def open(self):
        last_err = None
        for _ in range(3):
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.settimeout(5)
                self.sock.connect(self.sock_path)
                # 主动打招呼：daemon 收到后才回放历史（否则探活连接也会被灌几 MB）
                hello = (self.name or 'client').encode('utf-8')[:64]
                try:
                    self.sock.sendall(
                        struct.pack('>BI', FRAME_HELLO, len(hello)) + hello
                    )
                except OSError:
                    pass
                self.sock.setblocking(True)
                return True
            except OSError as e:
                last_err = e
                try:
                    if self.sock:
                        self.sock.close()
                except OSError:
                    pass
                self.sock = None
                time.sleep(0.3)
        raise last_err if last_err else OSError('连接 daemon 失败')

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None

    def is_alive(self):
        return self.sock is not None

    def read(self):
        """非阻塞读：消化所有已缓冲的完整帧并拼成一块返回；无完整帧返回 b''。
        daemon 一次可能广播多帧，必须全部取出，避免残留丢帧。"""
        if self.sock is None:
            return b''
        try:
            self.sock.setblocking(False)
        except OSError:
            pass
        try:
            chunk = self.sock.recv(65536)
            if chunk:
                self._buf += chunk
            elif not chunk:
                # EOF：daemon 已断开
                self.close()
                return b''
        except (socket.timeout, BlockingIOError):
            pass
        except OSError:
            self.close()
            return b''
        # 解析所有已缓冲的完整帧（DATA 拼接，其它类型丢弃）
        out = []
        while True:
            if len(self._buf) < 5:
                break
            ftype, plen = struct.unpack('>BI', self._buf[:5])
            if len(self._buf) < 5 + plen:
                break
            payload = self._buf[5:5 + plen]
            self._buf = self._buf[5 + plen:]
            if ftype == FRAME_DATA:
                out.append(payload)
        return b''.join(out)

    def write(self, data):
        if self.sock is None:
            return
        try:
            self.sock.sendall(TtyDaemon.encode_frame(FRAME_DATA, data))
        except OSError:
            pass

    def set_winsize(self, cols, rows):
        if self.sock is None:
            return
        try:
            self.sock.sendall(TtyDaemon.encode_frame(
                FRAME_RESIZE, struct.pack('<HH', cols, rows)))
        except OSError:
            pass


# --------------------------------------------------------------------------
# WebSocket 客户端（复用已验证的实现：websocket-client 或手写帧）
# --------------------------------------------------------------------------
def _parse_proxy_url(proxy):
    if not proxy:
        return None
    from urllib.parse import urlparse
    p = proxy if '://' in proxy else 'http://' + proxy
    u = urlparse(p)
    if u.scheme not in ('http', 'https'):
        raise ValueError(f'代理 scheme 仅支持 http/https: {u.scheme}')
    return (u.hostname or '127.0.0.1', u.port or 3128)


def open_tcp(host, port, proxy=None):
    """建立到目标的 TCP（可能经 HTTP CONNECT 代理），返回 socket"""
    pxy = _parse_proxy_url(proxy)
    if not pxy:
        return socket.create_connection((host, port), timeout=30)

    phost, pport = pxy
    sock = socket.create_connection((phost, pport), timeout=30)
    sock.settimeout(30)
    target = f'{host}:{port}'
    sock.sendall(
        f'CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Connection: keep-alive\r\n\r\n'.encode()
    )
    buf = b''
    while b'\r\n\r\n' not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            sock.close()
            raise ConnectionError(f'代理 {phost}:{pport} 在 CONNECT 阶段断开')
        buf += chunk
    status = buf.split(b'\r\n', 1)[0].decode(errors='replace')
    if ' 200 ' not in status:
        sock.close()
        raise ConnectionError(f'代理 CONNECT 失败: {status}')
    sock.settimeout(None)
    return sock


def http_json(url, payload=None, method='POST', headers=None, proxy=None, timeout=30):
    """极简 JSON HTTP 客户端（支持 http/https + 代理隧道，自签证书也接受）"""
    from urllib.parse import urlparse
    u = urlparse(url)
    secure = u.scheme == 'https'
    port = u.port or (443 if secure else 80)
    sock = open_tcp(u.hostname, port, proxy)
    sock.settimeout(timeout)
    try:
        if secure:
            import ssl
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(sock, server_hostname=u.hostname)
            sock.settimeout(timeout)
        body = json.dumps(payload or {}).encode()
        path = (u.path or '/') + (('?' + u.query) if u.query else '')
        req = (
            f'{method} {path} HTTP/1.1\r\n'
            f'Host: {u.netloc}\r\n'
            'Content-Type: application/json\r\n'
            f'Content-Length: {len(body)}\r\n'
            'Connection: close\r\n'
        )
        for k, v in (headers or {}).items():
            req += f'{k}: {v}\r\n'
        req += '\r\n'
        sock.sendall(req.encode() + body)
        buf = b''
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        try:
            sock.close()
        except OSError:
            pass
    head, _, rest = buf.partition(b'\r\n\r\n')
    status = head.split(b'\r\n', 1)[0].decode(errors='replace')
    try:
        obj = json.loads(rest.decode('utf-8', 'replace') or '{}')
    except ValueError:
        obj = {}
    code = 0
    parts = status.split()
    if len(parts) >= 2 and parts[1].isdigit():
        code = int(parts[1])
    return code, obj


class WsClient:
    """
    零依赖最小 WebSocket 客户端：优先用 websocket-client（若已安装），
    否则用标准库 socket + ssl 手写帧（Windows 也适用）。

    proxy: 可选 HTTP 代理（如 http://127.0.0.1:3128）。
           - 手写路径：走 HTTP CONNECT 隧道，再在隧道里做 TLS（wss）。
           - websocket-client 路径：用其 http_proxy_host / http_proxy_port。
    """

    def __init__(self, url, token=None, proxy=None):
        self.url = url
        self.token = token
        self.proxy = proxy
        self.raw = None  # 底层 socket
        self.ws = None   # websocket-client 实例（若有）
        self._read_buf = b''

    def _parse_proxy(self):
        if not self.proxy:
            return None
        from urllib.parse import urlparse
        p = self.proxy if '://' in self.proxy else 'http://' + self.proxy
        u = urlparse(p)
        if u.scheme not in ('http', 'https'):
            raise ValueError(f'代理 scheme 仅支持 http/https: {u.scheme}')
        return (u.hostname or '127.0.0.1', u.port or 3128)

    def _open_tcp(self, host, port):
        return open_tcp(host, port, self.proxy)

    # ---- 连接 ----------------
    def connect(self):
        from urllib.parse import urlparse
        u = urlparse(self.url)
        if u.scheme not in ('ws', 'wss'):
            raise ValueError(f'不支持的 URL scheme: {u.scheme}（需要 ws:// 或 wss://）')
        host = u.hostname or 'localhost'
        port = u.port or (443 if u.scheme == 'wss' else 80)
        path = (u.path or '/') + (('?' + u.query) if u.query else '')
        proxy = self._parse_proxy()

        if websocket is not None:
            header = []
            if self.token:
                header.append(f'Authorization: Bearer {self.token}')
            kwargs = {'timeout': 30, 'header': header or None}
            if proxy:
                kwargs['http_proxy_host'] = proxy[0]
                kwargs['http_proxy_port'] = proxy[1]
            self.ws = websocket.create_connection(self.url, **kwargs)
            self.raw = None
            return

        # --- 手写实现 ---
        import ssl
        sock = self._open_tcp(host, port)
        # 握手阶段必须有超时：服务端不回包时不至于永久卡死（会在外层退避重试）
        sock.settimeout(HANDSHAKE_TIMEOUT)
        if u.scheme == 'wss':
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE  # 自签证书也接受
            sock = ctx.wrap_socket(sock, server_hostname=host)
            sock.settimeout(HANDSHAKE_TIMEOUT)

        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f'GET {path} HTTP/1.1\r\n'
            f'Host: {host}:{port}\r\n'
            'Upgrade: websocket\r\n'
            'Connection: Upgrade\r\n'
            f'Sec-WebSocket-Key: {key}\r\n'
            'Sec-WebSocket-Version: 13\r\n'
        )
        if self.token:
            req += f'Authorization: Bearer {self.token}\r\n'
        req += '\r\n'
        sock.sendall(req.encode())

        # 读响应头
        buf = b''
        while b'\r\n\r\n' not in buf:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError('WebSocket 握手失败：连接被关闭')
            buf += chunk
        head, _, rest = buf.partition(b'\r\n\r\n')
        status = head.split(b'\r\n', 1)[0].decode(errors='replace')
        if ' 101 ' not in status:
            raise ConnectionError(f'WebSocket 握手失败: {status}')
        self._read_buf = rest
        self.raw = sock
        # 握手完成：之后的读写超时由 recv_text 自己控制
        self.raw.settimeout(None)

    # ---- 发送 ----------------
    def send_text(self, text):
        payload = text.encode('utf-8')
        if self.ws is not None:
            self.ws.send(payload)
            return True
        if self.raw is None:
            return False
        try:
            self.raw.sendall(self._frame(payload, opcode=0x1))
            return True
        except OSError:
            return False

    def send(self, obj):
        return self.send_text(json.dumps(obj, ensure_ascii=False))

    def send_binary(self, payload):
        """发二进制帧：终端输出走这里，省掉 base64 的三成体积和两次编解码"""
        if self.ws is not None:
            try:
                self.ws.send(payload, opcode=0x2)
                return True
            except Exception:
                return False
        if self.raw is None:
            return False
        try:
            self.raw.sendall(self._frame(payload, opcode=0x2))
            return True
        except OSError:
            return False

    # ---- 接收 ----------------
    def poll(self, timeout=0.0):
        """底层 socket 是否可读（用于非阻塞轮询，避免 settimeout(0) 抛 BlockingIOError）"""
        sock = self.ws.sock if self.ws is not None else self.raw
        if sock is None:
            return False
        try:
            r, _, _ = select.select([sock], [], [], max(0.0, float(timeout or 0)))
            return bool(r)
        except (OSError, ValueError):
            return False

    def recv_text(self, timeout=15):
        """等待并读取一条文本消息；超时抛 TimeoutError，断线抛 ConnectionError。
        timeout=0 表示只轮询不等待。"""
        if not self.poll(timeout):
            raise TimeoutError
        if self.ws is not None:
            # 文本帧 = 控制消息（str）；二进制帧 = 终端输入（bytes，原样返回）
            while True:
                try:
                    frame = self.ws.recv_data(control_frame=True)
                except Exception as e:
                    raise ConnectionError(str(e))
                opcode, payload = frame
                if opcode == 0x1:
                    return payload.decode('utf-8', errors='replace')
                if opcode == 0x2:
                    return payload
                # ping/pong 等：继续读下一条

        if self.raw is None:
            raise ConnectionError('未连接')
        self.raw.settimeout(15)
        try:
            return self._recv_raw()
        except socket.timeout:
            raise TimeoutError
        finally:
            try:
                self.raw.settimeout(None)
            except Exception:
                pass

    def _read_exact(self, n):
        while len(self._read_buf) < n:
            chunk = self.raw.recv(65536)
            if not chunk:
                raise ConnectionError('连接被关闭')
            self._read_buf += chunk
        out = self._read_buf[:n]
        self._read_buf = self._read_buf[n:]
        return out

    def _frame(self, payload, opcode=0x1):
        """构造客户端帧（必须掩码）"""
        b0 = 0x80 | opcode
        mask = os.urandom(4)
        ln = len(payload)
        if ln < 126:
            hdr = bytes([b0, 0x80 | ln])
        elif ln < 65536:
            hdr = bytes([b0, 0x80 | 126]) + ln.to_bytes(2, 'big')
        else:
            hdr = bytes([b0, 0x80 | 127]) + ln.to_bytes(8, 'big')
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return hdr + mask + masked

    def _recv_raw(self):
        """读一帧，处理分片与 ping/pong，返回字符串（text 帧）"""
        while True:
            head = self._read_exact(2)
            if len(head) < 2:
                raise ConnectionError('连接被关闭')
            b0, b1 = head
            fin = (b0 >> 7) & 1
            opcode = b0 & 0x0F
            masked = (b1 >> 7) & 1
            ln = b1 & 0x7F
            if ln == 126:
                ln = int.from_bytes(self._read_exact(2), 'big')
            elif ln == 127:
                ln = int.from_bytes(self._read_exact(8), 'big')
            mask_key = self._read_exact(4) if masked else None
            payload = self._read_exact(ln) if ln else b''
            if mask_key:
                payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

            if opcode == 0x9:  # ping -> pong
                self.raw.sendall(self._frame(payload, opcode=0xA))
                continue
            if opcode == 0x8:  # close
                raise ConnectionError('对端关闭连接')
            if opcode == 0x1:  # text（控制消息）
                if fin:
                    return payload.decode('utf-8', errors='replace')
                self._frag = payload
                self._frag_bin = False
                continue
            if opcode == 0x2:  # binary（终端输入）
                if fin:
                    return payload
                self._frag = payload
                self._frag_bin = True
                continue
            if opcode == 0x0 and hasattr(self, '_frag'):  # continuation
                self._frag += payload
                if fin:
                    data = self._frag
                    is_bin = getattr(self, '_frag_bin', False)
                    del self._frag
                    return data if is_bin else data.decode('utf-8', errors='replace')
                continue

    # ---- 关闭 ----------------
    def close(self):
        if self.ws is not None:
            try:
                self.ws.close()
            except Exception:
                pass
        if self.raw is not None:
            try:
                self.raw.close()
            except Exception:
                pass
        self.ws = None
        self.raw = None


# --------------------------------------------------------------------------
# 事件循环：tty(daemon) <-> wss 双向 + 心跳
# --------------------------------------------------------------------------
class AgentLoop:
    def __init__(self, tty_, url, token, proxy, name, host, os_name, arch, heartbeat, shell='',
                 scrollback_limit=None):
        self.tty = tty_
        self.url = url
        self.token = token
        self.proxy = proxy
        self.name = name
        self.host = host
        self.os_name = os_name
        self.arch = arch
        self.heartbeat = heartbeat
        self.shell = shell
        self.ws = None
        self.pending = b''
        self.history = bytearray()   # 最近 tty 输出，重连后先补发给服务端回放
        self.scrollback_limit = scrollback_limit or SCROLLBACK_LIMIT
        self.registered = False
        self.peer_bin = False   # 服务端是否也支持二进制帧（hello 应答里回执）
        self.ok_count = 0            # 注册成功次数（用于判断是否真的连上 past）
        self.last_beat = 0.0

    def run(self):
        code = 0
        backoff = RECONNECT_BASE
        while True:
            # daemon 崩了/被杀了：重建后再连，否则会永远连不上 tty（只会空转重连）
            if not self.tty.is_alive():
                try:
                    self.tty.close()
                    if not ensure_daemon(self.name, self.shell, self.proxy,
                                         scrollback_kb=max(16, self.scrollback_limit // 1024)):
                        raise OSError('ensure_daemon 失败')
                    self.tty.open()
                    print('[remote-bash] 本地 daemon 已重建，会话恢复')
                except Exception as e:
                    print(f'[remote-bash] 重建 daemon 失败: {e}', file=sys.stderr)
                    time.sleep(backoff)
                    backoff = min(backoff * 2, RECONNECT_MAX)
                    continue

            ok_before = self.ok_count
            try:
                self.ws = WsClient(self.url, self.token, self.proxy)
                self.ws.connect()
                print(f'[remote-bash] 已连接 {self.url}')
                self.ws.send({
                    'type': 'hello', 'role': 'agent',
                    'name': self.name, 'host': self.host, 'user': _local_user(),
                    'os': self.os_name, 'arch': self.arch,
                    'heartbeat': self.heartbeat,
                    'version': VERSION,
                    'scrollback_kb': max(16, self.scrollback_limit // 1024),
                    'bin': 1,
                    'token': self.token or None,
                })
                self.last_beat = time.time()
                self._loop_once_many()
            except KeyboardInterrupt:
                break
            except SystemExit as e:
                c = getattr(e, 'code', 0)
                code = c if isinstance(c, int) else (0 if c is None else 1)
                break
            except Exception as e:
                print(f'[remote-bash] 错误: {e}', file=sys.stderr)
            finally:
                if self.ws:
                    try:
                        self.ws.close()
                    except Exception:
                        pass
                    self.ws = None
                self.registered = False

            # 指数退避 + 抖动：服务端重启时避免所有客户端同时重连/补发历史
            if self.ok_count > ok_before:
                backoff = RECONNECT_BASE
            print('[remote-bash] 连接已断开，重连中...')
            time.sleep(backoff * (0.8 + 0.4 * random.random()))
            backoff = min(backoff * 2, RECONNECT_MAX)
        return code

    def _loop_once_many(self):
        """持续运行：tty 输出 -> wss；wss 消息 -> tty；心跳"""
        while True:
            # 1. 排空 tty：一次最多读 16 块（约 1MB），避免每轮只读一块被 ws 轮询限速
            got_data = False
            for _ in range(16):
                out = self.tty.read()
                if not out:
                    break
                got_data = True
                self.history += out
                over = len(self.history) - self.scrollback_limit
                if over > 0:
                    del self.history[:over]
                self.pending += out
                if len(self.pending) > BUFFER_LIMIT:
                    self.pending = self.pending[-BUFFER_LIMIT:]
                if self.registered:
                    self._flush()
                    if self.pending:   # 发送失败 -> 断线，交给外层重连
                        return

            # 2. wss 消息：有 tty 数据时非阻塞轮询，空闲时才短超时等待
            try:
                raw = self.ws.recv_text(timeout=0 if got_data else 0.1)
            except TimeoutError:
                raw = None
            except Exception:
                return  # 断开 -> 外层重连
            if raw:
                try:
                    if isinstance(raw, bytes):
                        self._handle_input(raw)
                    else:
                        self._handle_msg(json.loads(raw))
                except Exception as e:
                    print(f'[remote-bash] 消息处理异常: {e}', file=sys.stderr)

            # 3. 心跳
            now = time.time()
            if self.registered and now - self.last_beat >= self.heartbeat:
                if not self.ws.send({'type': 'ping'}):
                    return
                self.last_beat = now

            # 4. tty 掉线（daemon 没了）
            if not self.tty.is_alive():
                print('[remote-bash] daemon tty 连接断开')
                return

    def _send_data(self, chunk, hist=False, reset=False):
        """实时输出走二进制帧（服务端支持时，省掉 base64）；历史回放带着 hist/reset
        标记，量不大且是一次性的，继续用 JSON 以免标记和数据分帧配对。"""
        if hist or reset or not self.peer_bin:
            msg = {'type': 'data', 'data': base64.b64encode(chunk).decode()}
            if hist:
                msg['hist'] = True
            if reset:
                msg['reset'] = True
            return self.ws.send(msg)
        return self.ws.send_binary(bytes(chunk))

    def _flush(self):
        while len(self.pending) >= 8192:
            chunk = self.pending[:8192]
            self.pending = self.pending[8192:]
            if not self._send_data(chunk):
                return
        if self.pending:
            if not self._send_data(self.pending):
                return
            self.pending = b''

    def _handle_input(self, raw):
        """二进制输入帧：原样写进 tty（不再 base64）"""
        if raw:
            self.tty.write(raw)

    def _handle_msg(self, m):
        t = m.get('type')
        if t == 'hello':
            if m.get('ok'):
                self.peer_bin = bool(m.get('bin'))
                self.registered = True
                self.ok_count += 1
                self.last_beat = time.time()
                print(f'[remote-bash] 注册成功 id={m.get("id")} name={m.get("name")}')
                # 先回放最近输出（让服务端/新 viewer 看到当前屏幕），再继续实时流。
                # history 包含 pending 内容，所以回放后清空 pending 避免重复。
                if self.history:
                    # 分块上传历史（几 MB 一次发会撑爆单帧，也拖慢界面）
                    hist = bytes(self.history)
                    # reset=True 让服务端用这份历史替换旧缓冲（否则每次重连都追加一遍）
                    for i in range(0, len(hist), REPLAY_CHUNK):
                        self._send_data(hist[i:i + REPLAY_CHUNK], hist=True, reset=i == 0)
                self.pending = b''
            else:
                print(f'[remote-bash] 注册被拒: {m.get("error")}', file=sys.stderr)
                if m.get('pairRequired') or 'token' in str(m.get('error') or ''):
                    # token 失效/被吊销：清掉重新配对一次，然后让外层重连（不退出，避免 systemd 空转）
                    # 60s 内只尝试一次，防止被拒后疯狂刷配对请求
                    now_ts = time.time()
                    if now_ts - getattr(self, '_last_repair', 0) > 60:
                        self._last_repair = now_ts
                        drop_token(self.name)
                        tok = pair_device(self.url, self.name, self.proxy)
                        if tok:
                            self.token = tok
                # 非 0 退出，配合 systemd Restart=on-failure 自动重试（例如 token 刚改过）
                raise SystemExit(1)
        elif t == 'input':
            data = m.get('data', '')
            try:
                raw = base64.b64decode(data)
            except Exception:
                raw = b''
            if raw:
                self.tty.write(raw)
        elif t == 'resize':
            cols = int(m.get('cols', 80) or 80)
            rows = int(m.get('rows', 24) or 24)
            self.tty.set_winsize(cols, rows)
        elif t == 'pong':
            pass
        elif t == 'ping':
            self.ws.send({'type': 'pong'})
        elif t == 'bye':
            print('[remote-bash] 服务端要求退出')
            raise SystemExit
        elif t == 'replaced':
            print(f'[remote-bash] 同名客户端已从别处重连（{m.get("reason") or ""}），本进程退出以免抢连接',
                  file=sys.stderr)
            raise SystemExit(0)


# --------------------------------------------------------------------------
# daemon 的生命周期管理：找出/拉起/杀掉
# --------------------------------------------------------------------------
def state_dir():
    d = os.environ.get('REMOTE_BASH_STATE', os.path.join(os.path.expanduser('~'), '.remote-bash'))
    try:
        os.makedirs(d, exist_ok=True, mode=0o700)
    except OSError:
        pass
    # 目录里是持有登录 shell 的 unix socket，只允许当前用户访问
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def daemon_path(name):
    safe = ''.join(c if (c.isalnum() or c in '._-') else '_' for c in name)
    return os.path.join(state_dir(), f'{safe}.sock')


def daemon_log(name):
    safe = ''.join(c if (c.isalnum() or c in '._-') else '_' for c in name)
    return os.path.join(state_dir(), f'{safe}.daemon.log')


def spawn_daemon(name, shell_cmd, proxy='', scrollback_kb=None):
    """后台拉起 daemon 进程（与当前进程脱离），返回是否成功。
    proxy: HTTP 代理（如 http://127.0.0.1:3128），传给 daemon 注入其 shell 环境。"""
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), '--daemon', '--name', name,
             '--shell', shell_cmd or '', '--proxy', proxy or '',
             '--scrollback', str(scrollback_kb or (SCROLLBACK_LIMIT // 1024))],
            stdin=subprocess.DEVNULL,
            stdout=open(daemon_log(name), 'a'),
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
        return True
    except Exception as e:
        print(f'[remote-bash] 拉起 daemon 失败: {e}', file=sys.stderr)
        return False


def is_daemon_alive(name):
    """探测本地 daemon。
    True  = 活着（或不确定/忙，按活着处理，绝不重建以免丢掉旧 shell）
    False = 确认没有 daemon 在 listen（socket 不存在或 ECONNREFUSED，可安全重建）
    区分 ECONNREFUSED/ENOENT（陈旧 socket）与超时（可能只是忙）。"""
    import errno
    path = daemon_path(name)
    if not os.path.exists(path):
        return False
    for _ in range(3):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.5)
        try:
            s.connect(path)
            return True
        except OSError as e:
            if e.errno in (errno.ECONNREFUSED, errno.ENOENT):
                return False  # 确实无 daemon 在 listen
            # 超时/其它：重试，仍不确定则按“活着”处理
        finally:
            try:
                s.close()
            except OSError:
                pass
    return True


def ensure_daemon(name, shell_cmd, proxy='', max_wait=8, scrollback_kb=None):
    """保证 daemon 就绪：活着则直接返回；否则拉起并等待 socket。"""
    if is_daemon_alive(name):
        return True
    # 清理可能残留的陈旧 socket 文件
    path = daemon_path(name)
    try:
        if os.path.exists(path):
            os.unlink(path)
    except OSError:
        pass
    if not spawn_daemon(name, shell_cmd, proxy, scrollback_kb):
        return False
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if is_daemon_alive(name):
            return True
        time.sleep(0.3)
    return False


def inject_proxy_env(proxy):
    """把会话配置的 HTTP 代理展开为标准代理环境变量，注入 daemon 环境。
    daemon 的 shell 由 pty.fork() 继承 os.environ（_spawn_shell 里 copy），
    因此 shell 及其所有子进程（git/curl/pip/npm 等）都会自动走该代理。
    NO_PROXY 确保 localhost / 本机地址不经过代理，避免误伤本机服务。"""
    if not proxy:
        return
    os.environ.setdefault('REMOTE_BASH_PROXY', proxy)
    for key in ('http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY',
                'all_proxy', 'ALL_PROXY'):
        os.environ.setdefault(key, proxy)
    merged = os.environ.get('no_proxy') or os.environ.get('NO_PROXY') or ''
    merged = merged.strip(',')
    if not any(h in merged for h in ('localhost', '127.0.0.1', '::1')):
        merged += (',' if merged else '') + 'localhost,127.0.0.1,::1'
    os.environ.setdefault('no_proxy', merged)
    os.environ.setdefault('NO_PROXY', merged)


def run_daemon(args):
    """--daemon 模式：常驻持有 tty，直到 shell 退出"""
    # 忽略 SIGCHLD 噪声由 waitpid 处理；Ctrl+C 直接退出
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    # 启动 shell 前先注入代理环境变量（--proxy 默认读 REMOTE_BASH_PROXY）
    inject_proxy_env(args.proxy)
    limit = max(16, int(getattr(args, 'scrollback', 0) or SCROLLBACK_KB)) * 1024
    d = TtyDaemon(daemon_path(args.name),
                  args.shell or os.environ.get('REMOTE_BASH_SHELL')
                  or (os.environ.get('SHELL') or '/bin/bash'),
                  log_file=daemon_log(args.name),
                  scrollback_limit=limit)
    try:
        d.run()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            if os.path.exists(d.sock_path):
                os.unlink(d.sock_path)
        except OSError:
            pass
    return 0


# ---------------- 设备注册（配对，类似 tailscale up）----------------

def token_path(name):
    return os.path.join(state_dir(), f'{name}.token')


def load_token(name):
    try:
        with open(token_path(name), 'r', encoding='utf-8') as f:
            return f.read().strip()
    except OSError:
        return ''


def save_token(name, token):
    p = token_path(name)
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            os.chmod(os.path.dirname(p), 0o700)
        except OSError:
            pass
        tmp = p + '.tmp'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(token + '\n')
        os.replace(tmp, p)
        try:
            os.chmod(p, 0o600)
        except OSError:
            pass
        return True
    except OSError as e:
        print(f'[remote-bash] 保存 token 失败: {e}', file=sys.stderr)
        return False


def drop_token(name):
    try:
        os.unlink(token_path(name))
    except OSError:
        pass


def http_base(ws_url):
    from urllib.parse import urlparse
    u = urlparse(ws_url)
    return f'{"https" if u.scheme == "wss" else "http"}://{u.netloc}'


def pair_device(ws_url, name, proxy='', interval=2, timeout_sec=600):
    """申请配对码 -> 打印链接 -> 等管理员在浏览器批准 -> 拿到并保存 token"""
    base = http_base(ws_url)
    try:
        code, obj = http_json(
            f'{base}/api/remote/pair/start',
            {'name': name, 'host': socket.gethostname() or '',
             'os': platform.system() or '', 'arch': platform.machine() or '', 'user': _local_user()},
            proxy=proxy,
        )
    except Exception as e:
        print(f'[remote-bash] 申请配对码失败: {e}', file=sys.stderr)
        return None
    if code != 200 or not obj.get('success'):
        print(f'[remote-bash] 申请配对码失败: HTTP {code} {obj.get("error", "")}', file=sys.stderr)
        return None

    url = obj.get('url') or f'{base}/workbench/?rb_pair={obj.get("code")}'
    print('', flush=True)
    print('=' * 66, flush=True)
    print('  设备还没注册。用浏览器打开下面链接，点「允许」即可（像 tailscale 一样）：', flush=True)
    print(f'    {url}', flush=True)
    print(f'  配对码 {obj.get("code")}   有效期 {obj.get("expiresIn", 600)} 秒', flush=True)
    print('  已经登录 workbench 的话不用再输密码；过期就重新运行安装脚本。', flush=True)
    print('=' * 66, flush=True)

    secret = obj.get('pollSecret', '')
    deadline = time.time() + min(timeout_sec, int(obj.get('expiresIn') or 600))
    while time.time() < deadline:
        time.sleep(interval)
        try:
            _, r = http_json(f'{base}/api/remote/pair/poll', {'code': obj.get('code')},
                             headers={'x-pair-secret': secret}, proxy=proxy)
        except Exception as e:
            print(f'[remote-bash] 查询配对结果失败（继续重试）: {e}', file=sys.stderr)
            continue
        st = r.get('status')
        if st == 'approved' and r.get('token'):
            save_token(name, r['token'])
            print(f'[remote-bash] 注册成功：{name} 已授权，token -> {token_path(name)}', flush=True)
            return r['token']
        if st == 'denied':
            print('[remote-bash] 管理员拒绝了这次注册', file=sys.stderr)
            return None
        if st == 'expired':
            print('[remote-bash] 配对码已过期，请重试', file=sys.stderr)
            return None
    print('[remote-bash] 等待批准超时', file=sys.stderr)
    return None


def run_client(args):
    name = (args.name or socket.gethostname() or 'remote').strip() or 'remote'
    os_name = platform.system() or 'unknown'
    arch = platform.machine() or 'unknown'
    shell_cmd = args.shell or os.environ.get('REMOTE_BASH_SHELL') or ''
    sb_kb = max(16, int(getattr(args, 'scrollback', 0) or SCROLLBACK_KB))

    token = (args.token or os.environ.get('REMOTE_BASH_TOKEN') or load_token(name)).strip()

    if getattr(args, 'pair', False):
        return 0 if pair_device(args.url, name, args.proxy) else 1

    if not ensure_daemon(name, shell_cmd, args.proxy, scrollback_kb=sb_kb):
        print('[remote-bash] 无法启动本地 daemon，退出', file=sys.stderr)
        return 2

    tty_ = DaemonTty(daemon_path(name), name=name)
    code = 0
    try:
        try:
            tty_.open()
        except OSError as e:
            print(f'[remote-bash] 连接本地 daemon 失败: {e}', file=sys.stderr)
            return 2
        print(f'[remote-bash] 已连接本地 daemon: 会话 {name} (数据保存在 ~/.remote-bash)')
        if args.proxy:
            print(f'[remote-bash] 使用 HTTP 代理: {args.proxy}')
        print(f'[remote-bash] 心跳间隔: {args.heartbeat}s')

        if not token:
            # 没注册过：自动走配对（链接打到 stdout / journal，install.sh 也会转述）
            token = pair_device(args.url, name, args.proxy) or ''
        loop = AgentLoop(tty_, args.url, token, args.proxy, name,
                         socket.gethostname() or '', os_name, arch, args.heartbeat,
                         shell=shell_cmd, scrollback_limit=sb_kb * 1024)
        code = loop.run()
    finally:
        tty_.close()
    return code


def main():
    ap = argparse.ArgumentParser(description='remote-bash agent：把本机 tty 挂到 workbench（daemon 常驻，client 退出 shell 不丢）')
    ap.add_argument('--url', default=os.environ.get('REMOTE_BASH_URL', 'wss://edge02.10w123.com/workbench/wss'),
                    help='workbench WebSocket 地址（默认环境变量 REMOTE_BASH_URL 或 wss://edge02.10w123.com/workbench/wss）')
    ap.add_argument('--name', default=os.environ.get('REMOTE_BASH_NAME', ''),
                    help='客户端显示名 = 会话名（默认 主机名）；daemon 按这个名字持久化')
    ap.add_argument('--token', default=os.environ.get('REMOTE_BASH_TOKEN', ''),
                    help='可选鉴权 token（服务端 REMOTE_BASH_TOKEN）')
    ap.add_argument('--shell', default='', help='远端 shell 命令（默认 $SHELL 或 /bin/bash）')
    ap.add_argument('--proxy', default=os.environ.get('REMOTE_BASH_PROXY', os.environ.get('http_proxy', os.environ.get('HTTP_PROXY', ''))),
                    help='通过 HTTP 代理连接（如 http://127.0.0.1:3128；默认环境变量）')
    ap.add_argument('--scrollback', type=int, default=SCROLLBACK_KB,
                    help='断连重连后回放的最近输出大小（KB，默认 4096=4MB）')
    ap.add_argument('--heartbeat', type=int, default=DEFAULT_HEARTBEAT,
                    help=f'心跳间隔秒数（默认 {DEFAULT_HEARTBEAT}s，保持长连接）')
    ap.add_argument('--no-daemon', action='store_true',
                    help='不自动拉起 daemon（要求 daemon 已在前台运行）')
    ap.add_argument('--pair', action='store_true',
                    help='只做设备注册：打印链接、等管理员批准、保存 token 后退出')
    ap.add_argument('--daemon', action='store_true', help='以前台 daemon 模式运行（持有 tty）')
    args = ap.parse_args()

    if args.daemon:
        return run_daemon(args)
    return run_client(args)


if __name__ == '__main__':
    sys.exit(main())

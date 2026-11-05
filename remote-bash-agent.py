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
DEFAULT_HEARTBEAT = 15      # 秒

# ---------- 本地 daemon 帧协议 ----------
FRAME_DATA = 0x01   # payload: 裸 tty 字节
FRAME_RESIZE = 0x02  # payload: struct '<HH' (cols, rows)
FRAME_HELLO = 0x03  # client -> daemon: payload: 名称（UTF-8）


# --------------------------------------------------------------------------
# daemon：常驻持有 tty 的独立进程
# --------------------------------------------------------------------------
class TtyDaemon:
    """持有 pty shell + 监听 unix socket；client 通过 socket 读写 tty。"""

    def __init__(self, sock_path, shell_cmd, log_file=None):
        self.sock_path = sock_path
        self.shell_cmd = shell_cmd
        self.log_file = log_file
        self.master = None
        self.pid = None
        self.clients = []       # [(sock, read_buf)]
        self.server = None
        self._buf = b''

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

        readers = [self.server, self.master]
        while True:
            try:
                ready, _, _ = select.select(readers, [], [], 1.0)
            except (OSError, ValueError):
                break

            for fd in ready:
                if fd is self.server:
                    try:
                        conn, _ = self.server.accept()
                    except OSError:
                        continue
                    conn.setblocking(False)
                    self.clients.append([conn, b''])
                    readers.append(conn)
                elif fd is self.master:
                    try:
                        data = os.read(self.master, 65536)
                    except BlockingIOError:
                        continue
                    except OSError:
                        data = None
                    if data:
                        frame = self.encode_frame(FRAME_DATA, data)
                        for pair in list(self.clients):
                            try:
                                pair[0].sendall(frame)
                            except OSError:
                                pass
                    # master 读不到 & 子进程已退出 -> daemon 结束
                    if not data and not self._shell_alive():
                        self._log('shell 已退出，daemon 退出')
                        return
                else:
                    # client socket 可读
                    try:
                        chunk = fd.recv(65536)
                    except (OSError, BlockingIOError):
                        chunk = b''
                    if not chunk:
                        self._drop_client(fd, readers)
                        continue
                    pair = next((p for p in self.clients if p[0] is fd), None)
                    if pair is None:
                        continue
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

    def _write_master(self, data):
        if self.master is None:
            return
        try:
            os.write(self.master, data)
        except OSError:
            pass

    def _shell_alive(self):
        if self.pid is None:
            return False
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid == 0
        except ChildProcessError:
            return False

    def _drop_client(self, fd, readers):
        self.clients = [p for p in self.clients if p[0] is not fd]
        try:
            fd.close()
        except OSError:
            pass
        if fd in readers:
            readers.remove(fd)

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

    def __init__(self, sock_path):
        self.sock_path = sock_path
        self.sock = None
        self._buf = b''

    def open(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(self.sock_path)
        self.sock.setblocking(True)
        return True

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
        """建立到目标的 TCP（可能经 HTTP CONNECT 代理），返回 socket"""
        proxy = self._parse_proxy()
        if not proxy:
            return socket.create_connection((host, port), timeout=30)

        phost, pport = proxy
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
        if u.scheme == 'wss':
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE  # 自签证书也接受
            sock = ctx.wrap_socket(sock, server_hostname=host)
        sock.settimeout(None)

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

    # ---- 接收 ----------------
    def recv_text(self, timeout=15):
        """阻塞接收一帧，返回其文本；断线/关闭抛 ConnectionError"""
        if self.ws is not None:
            if timeout:
                self.ws.settimeout(timeout)
            try:
                raw = self.ws.recv()
            except Exception as e:
                raise ConnectionError(str(e))
            if isinstance(raw, bytes):
                raw = raw.decode('utf-8', errors='replace')
            return raw

        if self.raw is None:
            raise ConnectionError('未连接')
        self.raw.settimeout(timeout)
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
            if opcode == 0x1:  # text
                if fin:
                    return payload.decode('utf-8', errors='replace')
                self._frag = payload
                continue
            if opcode == 0x0 and hasattr(self, '_frag'):  # continuation
                self._frag += payload
                if fin:
                    txt = self._frag.decode('utf-8', errors='replace')
                    del self._frag
                    return txt
                continue
            # 二进制等其他帧忽略

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
    def __init__(self, tty_, url, token, proxy, name, host, os_name, arch, heartbeat):
        self.tty = tty_
        self.url = url
        self.token = token
        self.proxy = proxy
        self.name = name
        self.host = host
        self.os_name = os_name
        self.arch = arch
        self.heartbeat = heartbeat
        self.ws = None
        self.pending = b''
        self.registered = False
        self.last_beat = 0.0

    def run(self):
        while True:
            try:
                self.ws = WsClient(self.url, self.token, self.proxy)
                self.ws.connect()
                print(f'[remote-bash] 已连接 {self.url}')
                self.ws.send({
                    'type': 'hello', 'role': 'agent',
                    'name': self.name, 'host': self.host,
                    'os': self.os_name, 'arch': self.arch,
                    'token': self.token or None,
                })
                self.last_beat = time.time()
                self._loop_once_many()
            except KeyboardInterrupt:
                break
            except SystemExit:
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

            print('[remote-bash] 连接已断开，重连中...')
            time.sleep(RECONNECT_BASE)

    def _loop_once_many(self):
        """持续运行：tty 输出 -> wss；wss 消息 -> tty；心跳"""
        while True:
            # 1. tty 输出
            out = self.tty.read()
            if out:
                self.pending += out
                if len(self.pending) > BUFFER_LIMIT:
                    self.pending = self.pending[-BUFFER_LIMIT:]
                if self.registered:
                    self._flush()

            # 2. wss 消息（短超时轮询）
            try:
                raw = self.ws.recv_text(timeout=0.1)
            except TimeoutError:
                raw = None
            except Exception:
                return  # 断开 -> 外层重连
            if raw:
                try:
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

    def _flush(self):
        while len(self.pending) >= 8192:
            chunk = self.pending[:8192]
            self.pending = self.pending[8192:]
            if not self.ws.send({'type': 'data', 'data': base64.b64encode(chunk).decode()}):
                return
        if self.pending:
            if not self.ws.send({'type': 'data', 'data': base64.b64encode(self.pending).decode()}):
                return
            self.pending = b''

    def _handle_msg(self, m):
        t = m.get('type')
        if t == 'hello':
            if m.get('ok'):
                self.registered = True
                self.last_beat = time.time()
                print(f'[remote-bash] 注册成功 id={m.get("id")} name={m.get("name")}')
                self._flush()
            else:
                print(f'[remote-bash] 注册被拒: {m.get("error")}', file=sys.stderr)
                raise SystemExit
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


# --------------------------------------------------------------------------
# daemon 的生命周期管理：找出/拉起/杀掉
# --------------------------------------------------------------------------
def state_dir():
    d = os.environ.get('REMOTE_BASH_STATE', os.path.join(os.path.expanduser('~'), '.remote-bash'))
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass
    return d


def daemon_path(name):
    safe = ''.join(c if (c.isalnum() or c in '._-') else '_' for c in name)
    return os.path.join(state_dir(), f'{safe}.sock')


def daemon_log(name):
    safe = ''.join(c if (c.isalnum() or c in '._-') else '_' for c in name)
    return os.path.join(state_dir(), f'{safe}.daemon.log')


def spawn_daemon(name, shell_cmd, proxy=''):
    """后台拉起 daemon 进程（与当前进程脱离），返回是否成功。
    proxy: HTTP 代理（如 http://127.0.0.1:3128），传给 daemon 注入其 shell 环境。"""
    try:
        proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), '--daemon', '--name', name,
             '--shell', shell_cmd or '', '--proxy', proxy or ''],
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
    """尝试连接 unix socket 探测 daemon；能连上则 True"""
    path = daemon_path(name)
    if not os.path.exists(path):
        return False
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(path)
        s.close()
        return True
    except OSError:
        return False


def ensure_daemon(name, shell_cmd, proxy='', max_wait=8):
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
    if not spawn_daemon(name, shell_cmd, proxy):
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
    d = TtyDaemon(daemon_path(args.name), args.shell or (os.environ.get('SHELL') or '/bin/bash'),
                  log_file=daemon_log(args.name))
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


def run_client(args):
    name = (args.name or socket.gethostname() or 'remote').strip() or 'remote'
    os_name = platform.system() or 'unknown'
    arch = platform.machine() or 'unknown'

    if not ensure_daemon(name, args.shell, args.proxy):
        print('[remote-bash] 无法启动本地 daemon，退出', file=sys.stderr)
        return 2

    tty_ = DaemonTty(daemon_path(name))
    try:
        if not tty_.open():
            print('[remote-bash] 连接本地 daemon 失败', file=sys.stderr)
            return 2
        print(f'[remote-bash] 已连接本地 daemon: 会话 {name} (数据保存在 ~/.remote-bash)')
        if args.proxy:
            print(f'[remote-bash] 使用 HTTP 代理: {args.proxy}')
        print(f'[remote-bash] 心跳间隔: {args.heartbeat}s')

        loop = AgentLoop(tty_, args.url, args.token, args.proxy, name,
                         socket.gethostname() or '', os_name, arch, args.heartbeat)
        loop.run()
    finally:
        tty_.close()
    return 0


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
    ap.add_argument('--heartbeat', type=int, default=DEFAULT_HEARTBEAT,
                    help=f'心跳间隔秒数（默认 {DEFAULT_HEARTBEAT}s，保持长连接）')
    ap.add_argument('--no-daemon', action='store_true',
                    help='不自动拉起 daemon（要求 daemon 已在前台运行）')
    ap.add_argument('--daemon', action='store_true', help='以前台 daemon 模式运行（持有 tty）')
    args = ap.parse_args()

    if args.daemon:
        return run_daemon(args)
    return run_client(args)


if __name__ == '__main__':
    sys.exit(main())

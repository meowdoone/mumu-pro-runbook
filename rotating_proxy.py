#!/usr/bin/env python3
"""rotating_proxy.py —— 本地免认证 HTTP 代理，上游是 IPRoyal 池，失败自动换节点。

为什么需要它：
  1. Android 全局 http_proxy 不支持 user:pass@host，必须有个免认证的本地入口。
  2. IPRoyal 节点会随机回 403（实测单节点约一半请求失败），
     所以每次连接都要在多个上游里挑一个能通的，失败就换，直到用尽。

用法：
  python3 rotating_proxy.py --list ~/Desktop/iproyal-proxies.txt --port 18790

只支持 CONNECT（https）和绝对 URI 的 http 请求，够 Play/GMS 用。
"""
import argparse
import asyncio
import base64
import random
import sys
from pathlib import Path

ATTEMPT_TIMEOUT = 8


def parse_list(path: Path):
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":")
        if len(parts) < 4:
            continue
        host, port, user, pw = parts[0], int(parts[1]), parts[2], parts[3]
        out.append((host, port, base64.b64encode(f"{user}:{pw}".encode()).decode()))
    return out


async def try_upstream(up, target_host, target_port):
    """向上游发 CONNECT，200 才算成功。返回 (reader, writer)。"""
    host, port, cred = up
    try:
        r, w = await asyncio.wait_for(asyncio.open_connection(host, port), ATTEMPT_TIMEOUT)
    except Exception:
        return None
    req = (
        f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
        f"Host: {target_host}:{target_port}\r\n"
        f"Proxy-Authorization: Basic {cred}\r\n\r\n"
    )
    try:
        w.write(req.encode())
        await asyncio.wait_for(w.drain(), ATTEMPT_TIMEOUT)
        head = await asyncio.wait_for(r.readuntil(b"\r\n\r\n"), ATTEMPT_TIMEOUT)
    except Exception:
        w.close()
        return None
    if b" 200 " not in head.split(b"\r\n")[0]:
        w.close()
        return None
    return r, w


async def pipe(a_r, a_w, b_r, b_w):
    async def one(src, dst):
        try:
            while True:
                data = await src.read(65536)
                if not data:
                    break
                dst.write(data)
                await dst.drain()
        except Exception:
            pass
        finally:
            try:
                dst.close()
            except Exception:
                pass

    await asyncio.gather(one(a_r, b_w), one(b_r, a_w), return_exceptions=True)


async def handle(reader, writer, upstreams, stats):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 20)
    except Exception:
        writer.close()
        return

    first_line = head.split(b"\r\n")[0].decode("latin1", "ignore")
    parts = first_line.split()
    if len(parts) < 3:
        writer.close()
        return
    method, target = parts[0], parts[1]

    pool = upstreams[:]
    random.shuffle(pool)
    tunnel = None
    for up in pool:
        if method == "CONNECT":
            host, _, port = target.rpartition(":")
            tunnel = await try_upstream(up, host, int(port or 443))
        else:
            # 普通 http：直接走上游，把原始请求（去掉代理头）转发过去
            tunnel = await try_upstream(up, *(target.split("//")[-1].split("/")[0].split(":")))
        if tunnel:
            stats["ok"] += 1
            break
    if not tunnel:
        stats["fail"] += 1
        try:
            writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
        except Exception:
            pass
        writer.close()
        return

    up_r, up_w = tunnel
    if method != "CONNECT":
        # 补发原始请求，去掉可能残留的代理认证头
        body = b"\r\n".join(
            ln for ln in head.split(b"\r\n")
            if not ln.lower().startswith(b"proxy-authorization")
            and not ln.lower().startswith(b"proxy-connection")
        )
        try:
            up_w.write(body)
            await up_w.drain()
        except Exception:
            pass
    else:
        try:
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
        except Exception:
            writer.close()
            up_w.close()
            return

    await pipe(reader, writer, up_r, up_w)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", default=str(Path.home() / "Desktop/iproyal-proxies.txt"))
    ap.add_argument("--port", type=int, default=18790)
    a = ap.parse_args()

    ups = parse_list(Path(a.list))
    if not ups:
        sys.exit("代理列表为空")
    stats = {"ok": 0, "fail": 0}
    print(f"[rotating] {len(ups)} 个上游，监听 :{a.port}", flush=True)

    async def on_conn(r, w):
        await handle(r, w, ups, stats)

    server = await asyncio.start_server(on_conn, "0.0.0.0", a.port)

    async def report():
        while True:
            await asyncio.sleep(30)
            print(f"[rotating] ok={stats['ok']} fail={stats['fail']}", flush=True)

    asyncio.create_task(report())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

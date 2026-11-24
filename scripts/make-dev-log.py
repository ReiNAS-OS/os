#!/usr/bin/env python3
"""
在 chroot 的 /dev 里创建 /dev/log unix socket，并常驻接收。

dracut-logger.sh 的判定条件（/usr/lib/dracut/dracut-logger.sh:152）：
    [[ -S /dev/log ]] && [[ -w /dev/log ]] && command -v logger
三个条件都满足才算有 syslog 可用。缺任何一个都会记录
    No '/dev/log' or 'logger' included for syslog logging
而 kiwi 把 dracut 的 stderr 输出判定为命令失败，构建中断。

关键：socket 必须保持打开并持续接收。
只 bind 不 recv，写满缓冲区后 write 会阻塞或失败，检查照样不通过。
所以这里起一个后台线程不停 recv 丢弃。

用法：
    sudo python3 make-dev-log.py /mnt/fedora/dev/log &
"""
import os
import socket
import sys
import threading
import time


def serve(path: str) -> None:
    if os.path.exists(path):
        try:
            os.unlink(path)
        except OSError as e:
            print(f"无法删除旧 socket：{e}", file=sys.stderr)
            return

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.bind(path)
    except OSError as e:
        print(f"绑定失败：{e}", file=sys.stderr)
        return

    os.chmod(path, 0o666)
    print(f"已创建并监听：{path}", flush=True)

    # 持续接收并丢弃，保证写入方永不阻塞
    while True:
        try:
            sock.recv(65535)
        except OSError:
            time.sleep(0.1)


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "/mnt/fedora/dev/log"

    if not os.path.isdir(os.path.dirname(path)):
        print(f"跳过：{os.path.dirname(path)} 不存在", file=sys.stderr)
        return 1

    # 后台线程服务，主线程保持存活
    t = threading.Thread(target=serve, args=(path,), daemon=False)
    t.start()
    t.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())

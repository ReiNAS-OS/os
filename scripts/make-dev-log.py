#!/usr/bin/env python3
"""
在 chroot 的 /dev 里创建一个 /dev/log unix socket。

dracut 的 dracut-logger.sh 会检查 /dev/log 是否可写，找不到就记录
  No '/dev/log' or 'logger' included for syslog logging
kiwi 把 dracut 的任何 stderr 输出都判定为命令失败，所以构建会中断。

GitHub runner 上没有跑 syslog 服务，/dev/log 通常不存在。
这里起一个只绑定不监听的 SOCK_DGRAM socket：dracut 只要能把日志写进去
就算通过，不需要有人读。
"""
import os
import socket
import sys


def main() -> int:
    # 允许从命令行指定路径，默认按 chroot 布局
    path = sys.argv[1] if len(sys.argv) > 1 else "/mnt/fedora/dev/log"

    if not os.path.isdir(os.path.dirname(path)):
        print(f"跳过：{os.path.dirname(path)} 不存在", file=sys.stderr)
        return 1

    if os.path.exists(path):
        print(f"已存在：{path}")
        return 0

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        sock.bind(path)
    except OSError as e:
        print(f"创建失败：{e}", file=sys.stderr)
        return 1

    os.chmod(path, 0o666)
    print(f"已创建：{path}")
    # socket 需要保持打开，进程退出后文件保留但无监听；
    # dracut 只写不读，文件存在且可写即可。
    return 0


if __name__ == "__main__":
    sys.exit(main())

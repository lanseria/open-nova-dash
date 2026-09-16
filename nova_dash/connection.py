"""连接与心跳 (对应 iOS 连接页: ConnectionModel.swift / ConnectView).

生命周期与 iOS 端一致: 手动连接探测通过后才启动心跳; 心跳给业务命令让路;
连续失败退避降频, 不拿请求砸阻塞中的单线程服务器.
"""

from __future__ import annotations

import threading
import time

import requests

HEARTBEAT_INTERVAL = 3.0  # 协议要求: 必须每 3~5 秒心跳一次, 否则设备断开 Wi-Fi
HEARTBEAT_BACKOFF_INTERVAL = 15.0  # 设备无响应时的退避间隔


class HeartbeatKeeper:
    """后台心跳线程 (对应 iOS ConnectionModel.startMonitoring)."""

    def __init__(self, client) -> None:
        self.client = client
        self.beat_count = 0
        self.last_beat: float | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)
            self._thread = None

    def _loop(self) -> None:
        fail_streak = 0
        interval = HEARTBEAT_INTERVAL
        while not self._stop.wait(interval):
            if not self.client.cmd_lock.acquire(blocking=False):
                continue  # 业务命令执行中, 本轮心跳让路
            try:
                self.client.raw_cmd(3016, timeout=2)
                fail_streak = 0
                interval = HEARTBEAT_INTERVAL
                self.beat_count += 1
                self.last_beat = time.time()
            except requests.RequestException:
                # 连续失败说明设备阻塞/失联, 退避降频
                fail_streak += 1
                interval = HEARTBEAT_INTERVAL if fail_streak < 2 else HEARTBEAT_BACKOFF_INTERVAL
            finally:
                self.client.cmd_lock.release()


def connect(client, attempts: int = 3) -> bool:
    """连接探测 (对应 iOS ConnectView 点击"连接"), 连续 ping 最多 attempts 次."""
    for i in range(1, attempts + 1):
        print(f"探测设备 ({i}/{attempts}) ... ", end="", flush=True)
        if client.ping():
            print("✓")
            return True
        print("✗")
    return False

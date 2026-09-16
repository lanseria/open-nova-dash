"""设备驱动层 (对应 iOS Core/NovatekClient.swift).

单线程 HTTP 服务器的两条铁律在这里落地:
1. 所有请求(含心跳)必须经 cmd_lock 串行, 并发会导致连接被重置;
2. 读超时不自动重发 -- 重试策略只覆盖"连接建立失败"(请求未送达, 重发安全),
   否则 2001 这类状态命令会堆积到阻塞中的设备上且可能重复执行
   (v5 实测 "Max retries exceeded" 请求风暴即来源于此).
"""

from __future__ import annotations

import threading
import time
import xml.etree.ElementTree as ET

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE_URL = "http://192.168.1.254"

# 负数 Status 与 Linux errno 编号一致, 以下是本机实测/社区文档中出现过的:
ERROR_HINTS = {
    -1: "不支持/被拒绝",
    -3: "存储或状态错误: 录像中查文件列表、SD 卡未就绪时常见",
    -5: "EIO 写卡失败: 卡满或卡故障, 备份后格式化 (本机实测卡满时 1001 拍照返回此码)",
    -13: "抓拍执行失败 (exec fail)",
    -21: "本机实测于 2001 无参数查询: 查询变体大概率不支持",
    -22: "EINVAL 参数无效: 固件不认参数名/参数值, 或当前状态不允许",
}


def describe_status(root) -> str:
    text = root.findtext("Status") if root is not None else None
    if text is None:
        return "⚠️ 响应中无 Status 字段"
    try:
        code = int(text)
    except ValueError:
        return f"Status={text}"
    if code == 0:
        return "✅ 成功"
    hint = ERROR_HINTS.get(code)
    return f"❌ 失败 (Status={code}" + (f": {hint})" if hint else ")")


def is_ok(root) -> bool:
    return root is not None and root.findtext("Status") == "0"


def extract_fpath(root) -> str | None:
    """从响应中取第一个 <FPATH> (拍照成功时返回照片保存路径)."""
    if root is None:
        return None
    return next((e.text.strip() for e in root.iter("FPATH") if e.text and e.text.strip()), None)


def parse_file_list(root) -> list[str] | None:
    """解析 3015 响应为路径列表; 本机固件直接返回文件树, 无 Status 包裹."""
    if root is None:
        return None
    paths = [e.text.strip() for e in root.iter("FPATH") if e.text and e.text.strip()]
    return paths or None


class NovatekClient:
    """CGI 收发器: 串行锁 + 单连接会话 + 失联恢复等待."""

    def __init__(self, base_url: str = BASE_URL) -> None:
        self.base_url = base_url.rstrip("/")
        self.cmd_lock = threading.Lock()
        self.session = requests.Session()
        # 单连接池; 仅重试"连接建立失败"(TCP 未建成、请求未送达, 重发安全).
        self.session.mount(
            "http://",
            HTTPAdapter(
                pool_connections=1,
                pool_maxsize=1,
                max_retries=Retry(
                    total=1, connect=1, read=0, backoff_factor=0.3,
                    allowed_methods=frozenset(["GET"]),
                ),
            ),
        )

    def raw_cmd(self, cmd: int, par=None, str_par=None, timeout: float = 4):
        params = {"custom": 1, "cmd": cmd}
        if par is not None:
            params["par"] = par
        if str_par is not None:
            params["str"] = str_par
        resp = self.session.get(self.base_url + "/", params=params, timeout=timeout)
        return ET.fromstring(resp.text.strip())

    def send_cmd(self, cmd: int, par=None, str_par=None, description: str = "", timeout: float = 4):
        """发送 CGI 指令并打印结果, 返回 XML 根节点(网络异常/非 XML 返回 None)."""
        param_desc = (
            f"str={str_par}" if str_par is not None
            else f"par={par}" if par is not None
            else "无参数"
        )
        print(f"\n▶ {description} (cmd={cmd}, {param_desc})")
        try:
            with self.cmd_lock:
                root = self.raw_cmd(cmd, par, str_par, timeout)
        except requests.RequestException as e:
            print(f"  └─ 请求异常: {type(e).__name__}: {e}")
            if "Read timed out" in str(e) or "ReadTimeoutError" in str(e):
                print("      (读超时=设备阻塞处理中; 不自动重发, 避免状态命令重复执行)")
            return None
        except ET.ParseError:
            print("  └─ 非标准 XML 响应")
            return None

        print(f"  └─ 结果: {describe_status(root)}")
        # 返回的数据字段: 版本在 <String>, 查询结果在 <Value>, 拍照路径在 <File><FPATH>
        for child in root:
            text = (child.text or "").strip()
            if child.tag in ("Cmd", "Status") or not text:
                continue
            print(f"      {child.tag}: {text[:200]}")
        return root

    def ping(self, timeout: float = 3) -> bool:
        """单次心跳探测 (cmd=3016), 供连接/失联恢复轮询使用."""
        try:
            with self.cmd_lock:
                self.raw_cmd(3016, timeout=timeout)
            return True
        except (requests.RequestException, ET.ParseError):
            return False

    def wait_device_back(self, max_wait: int = 30, description: str = "等待设备恢复响应") -> bool:
        """设备 HTTP 失联时轮询心跳直到恢复或超时 (只等不重发, 超时≠命令失败)."""
        print(f"\n⏳ {description} (最多 {max_wait}s)...")
        start = time.time()
        deadline = start + max_wait
        while time.time() < deadline:
            if not self.cmd_lock.acquire(blocking=False):
                time.sleep(1)
                continue
            try:
                self.raw_cmd(3016, timeout=3)
                print(f"  ✅ 设备已恢复响应 (耗时约 {time.time() - start:.0f}s)")
                return True
            except (requests.RequestException, ET.ParseError):
                time.sleep(3)
            finally:
                self.cmd_lock.release()
        print("  ❌ 仍未恢复: 设备可能还在忙, 稍等后重试, 或查看设备屏幕/断电重启")
        return False

"""慢速控制探针 (排查 iOS 控制页"拍照/停录/开录没效果").

与 iOS 端发完全相同的命令 (1001 / 2001&par= / 3001&par=), 但节奏放慢、逐步取证:
1. 每条控制命令前静置 --delay 秒 (默认 3s), 排除"发太快, 设备来不及处理";
2. 全程 [HH:MM:SS] 时间戳, 便于与设备表现/iOS 端日志对时;
3. 不信命令回执, 每步用权威状态命令复核真实效果:
   - 录像: 2016 连采两次 (有读数=录像中, 全 0=未录像), 命令后轮询确认状态真的变了;
   - 拍照: 1003 剩余可拍张数前后对比 (数字减少 = 照片确实落盘), 回执 FPATH 仅作旁证;
4. 结束时确保设备回到循环录像状态 (行车记录仪红线).

结论判读:
- 本脚本逐项生效而 iOS 无效 → 问题在 App 侧 (节奏/超时/直播占用串行通道);
- 本脚本也复现"回执成功但状态不变" → 设备/卡侧问题 (卡满/卡慢/固件状态机).
"""

from __future__ import annotations

import time
from datetime import datetime

from .control import recording_seconds
from .core import extract_fpath, is_ok

OP_CHOICES = ("stop", "start", "capture")
DEFAULT_OPS = "stop,start,capture"

MODE_LABELS = {1: "录像", 3: "回放", 4: "照片"}
SD_LABELS = {0: "无卡", 1: "正常", 2: "被锁定"}


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def settle(seconds: float, reason: str) -> None:
    """控制命令前的静置 (对应 iOS 端缺失的节奏控制)."""
    if seconds > 0:
        log(f"⏸  静置 {seconds:g}s ({reason})")
        time.sleep(seconds)


def gap(seconds: float) -> None:
    """只读查询之间的短间隔, 不刷屏."""
    time.sleep(seconds)


def timed_cmd(client, cmd: int, par=None, str_par=None, timeout: float = 8, label: str = ""):
    """带发送/完成时间戳的命令发送, 返回 XML 根节点 (可能为 None)."""
    log(f"▶ 发送: {label}")
    start = time.time()
    root = client.send_cmd(cmd, par=par, str_par=str_par, description=label, timeout=timeout)
    log(f"◀ 完成, 耗时 {time.time() - start:.1f}s")
    return root


def value_of(root) -> int | None:
    text = root.findtext("Value") if root is not None else None
    return int(text) if text and text.isdigit() else None


def query_mode(client) -> int | None:
    """3037 工作模式 (本机实测回报: 1=录像 3=回放 4=照片)."""
    return value_of(client.send_cmd(3037, description="查询工作模式 (3037)"))


def is_recording(client) -> bool | None:
    """2016 连采两次 (间隔 1.5s): 第二次有读数=录像中; 全 0=未录像; 查询失败=None."""
    first = recording_seconds(client)
    gap(1.5)
    second = recording_seconds(client)
    if first is None or second is None:
        return None
    return second > 0


def poll_recording(client, target: bool, timeout: float) -> bool | None:
    """轮询 2016 直到达到目标状态或超时; 返回最终已知状态 (None=始终查不到)."""
    deadline = time.time() + timeout
    state: bool | None = None
    while time.time() < deadline:
        state = is_recording(client)
        if state == target:
            return state
        if state is None:
            # 读超时 ≠ 失败: 只等设备恢复, 绝不重发控制命令
            client.wait_device_back(30, "设备无响应, 等待恢复")
        else:
            gap(2)
    return state


def remaining_photos(client) -> int | None:
    """1003 剩余可拍张数 -- 拍照是否真的落盘的权威证据."""
    return value_of(client.send_cmd(1003, description="剩余可拍张数 (1003)"))


def baseline(client) -> None:
    """开局基线: 模式/录像/SD 卡/剩余空间 (卡满是各类诡异失败的常见根因)."""
    print("=" * 46)
    print(" 基线状态 (只读)")
    print("=" * 46)
    mode = query_mode(client)
    if mode is not None:
        log(f"工作模式 3037={mode} ({MODE_LABELS.get(mode, '未知')})")
    gap(0.8)
    log(f"录像状态 2016: {'录像中' if is_recording(client) else '未录像/查询失败'}")
    gap(0.8)
    root = client.send_cmd(3024, description="SD 卡状态 (3024)")
    sd = value_of(root)
    if sd is not None:
        log(f"SD 卡: {SD_LABELS.get(sd, sd)}" + (" ⚠️ 会拖垮一切写入操作!" if sd != 1 else ""))
    gap(0.8)
    root = client.send_cmd(3017, description="剩余空间 (3017)")
    free = value_of(root)
    if free is not None:
        gb = free / 1024**3
        log(f"剩余空间 ≈ {gb:.2f} GB" + ("  ⚠️ 卡快满, 循环腾挪会让命令长时间阻塞" if gb < 0.5 else ""))


def verdict(op: str, sent_ok: bool | None, achieved: bool) -> str:
    if achieved:
        log(f"✅ {op}: 设备状态确认已变化 (以 2016/1003 为准)")
        return "✅ 生效"
    if sent_ok:
        log(f"⚠️ {op}: 命令回执成功但状态未变化 —— 复现'没效果'!")
        return "⚠️ 回执成功但无效果"
    log(f"❌ {op}: 命令未确认且状态未变化")
    return "❌ 未生效"


def probe_stop(client, delay: float, verify_timeout: float) -> str:
    print("\n" + "=" * 46)
    print(" 探针①: 停止录像 (cmd=2001&par=0)")
    print("=" * 46)
    log("前置复核: 当前是否真的在录像")
    if is_recording(client) is not True:
        log("⏭ 设备本就未在录像, 停止无对象 (iOS 会提示'设备本就已停止')")
        return "⏭ 跳过 (未在录像)"
    settle(delay, "给设备留出收尾/腾挪时间")
    root = timed_cmd(client, 2001, par=0, timeout=15, label="停止录像 (2001&par=0)")
    settle(1.0, "等设备落盘收尾")
    log(f"轮询 2016 复核真实状态 (窗口 {verify_timeout:g}s)...")
    state = poll_recording(client, target=False, timeout=verify_timeout)
    return verdict("停止录像", is_ok(root), state is False)


def probe_start(client, delay: float, verify_timeout: float) -> str:
    print("\n" + "=" * 46)
    print(" 探针②: 开始录像 (cmd=2001&par=1)")
    print("=" * 46)
    log("前置复核: 当前是否真的未录像")
    if is_recording(client) is True:
        log("⏭ 设备已在录像中, 开始无对象 (iOS 会提示'设备本就在录像中')")
        return "⏭ 跳过 (已在录像)"
    settle(delay, "停录后立即开录会长时间阻塞, 必须留恢复时间")
    root = timed_cmd(client, 2001, par=1, timeout=15, label="开始录像 (2001&par=1)")
    if root is None:
        log("   命令无回执 (读超时≠失败), 以轮询结果为准")
    settle(1.0, "等设备启动编码")
    log(f"轮询 2016 复核真实状态 (窗口 {verify_timeout:g}s)...")
    state = poll_recording(client, target=True, timeout=verify_timeout)
    if state is True:
        seconds = recording_seconds(client)
        gap(2)
        again = recording_seconds(client)
        if again is None or again == 0:
            return verdict("开始录像", is_ok(root), False)
        if seconds is not None and again > seconds:
            log(f"   计数器 {seconds}s → {again}s, 增长确认")
        else:
            # 未增长也接受: 可能刚跨循环文件, 计数器归零重计
            log(f"   计数器 {seconds}s → {again}s (未增长, 按协议 2016>0 仍判录像中)")
        return verdict("开始录像", True, True)
    return verdict("开始录像", is_ok(root), False)


def probe_capture(client, delay: float, verify_timeout: float) -> str:
    print("\n" + "=" * 46)
    print(" 探针③: 拍照 (cmd=1001, 失败再走慢速连招)")
    print("=" * 46)
    log("基线: 记录剩余可拍张数 (1003), 拍完后对比")
    before = remaining_photos(client)
    gap(0.8)
    settle(delay, "拍照写卡耗时, 留足间隔")
    root = timed_cmd(client, 1001, timeout=8, label="直接拍照 (1001)")
    fpath = extract_fpath(root)
    status = root.findtext("Status") if root is not None else None

    if status == "-22":
        log("→ 回执 -22 (状态不允许), 走慢速模式切换连招 (与 iOS 同路径, 但步间静置)")
        settle(delay, "切模式前静置")
        timed_cmd(client, 3001, par=0, timeout=12, label="切换照片模式 (3001&par=0)")
        settle(2.5, "等模式稳定")
        root = timed_cmd(client, 1001, timeout=8, label="照片模式下拍照 (1001)")
        fpath = extract_fpath(root) or fpath
        settle(1.5, "等照片落盘")
        timed_cmd(client, 3001, par=1, timeout=12, label="切回录像模式 (3001&par=1)")
        settle(2.5, "等模式稳定")
        timed_cmd(client, 2001, par=1, timeout=15, label="恢复录像 (2001&par=1)")

    settle(1.5, "等写卡彻底完成再复核")
    after = remaining_photos(client)
    saved = fpath is not None or (before is not None and after is not None and after < before)
    if saved:
        where = f", 文件: {fpath}" if fpath else ""
        delta = f" (1003: {before} → {after})" if before is not None and after is not None else ""
        log(f"✅ 拍照: 照片确认落盘{where}{delta}")
        return "✅ 生效"
    log(f"⚠️ 拍照: 回执 Status={status}, 且 1003 未减少 ({before} → {after}) —— 复现'没效果'!")
    log(f"   (Status=-5 = 写卡失败, 卡满常见; 之后照常复核录像状态, 窗口 {verify_timeout:g}s)")
    state = poll_recording(client, target=True, timeout=verify_timeout)
    if state is not True:
        log("   ⚠️ 拍照后设备不在录像状态, 收尾阶段会尝试恢复")
    return "⚠️ 回执成功但无照片证据" if status == "0" else "❌ 未生效"


def ensure_recording(client, delay: float, verify_timeout: float) -> None:
    """收尾红线: 行车记录仪必须回到循环录像状态."""
    print("\n" + "=" * 46)
    print(" 收尾: 确保恢复循环录像")
    print("=" * 46)
    if is_recording(client) is True:
        log("✅ 设备仍在录像, 无需处理")
        return
    settle(delay, "收尾恢复前静置")
    timed_cmd(client, 2001, par=1, timeout=15, label="恢复循环录像 (2001&par=1)")
    state = poll_recording(client, target=True, timeout=verify_timeout)
    if state is not True:
        log("❌ 未能确认恢复录像! 请查看设备屏幕或断电重启")


def run_probe(client, ops: list[str], delay: float, verify_timeout: float) -> None:
    log(f"慢速探针开始: 操作={','.join(ops) or '无'}, 命令前静置={delay:g}s, "
        f"状态复核窗口={verify_timeout:g}s")
    log("与 iOS 对比时重点看: 每条命令的发送/回执时间戳、回执后的真实状态变化")
    gap(1.0)
    baseline(client)

    results: dict[str, str] = {}
    runners = {"stop": probe_stop, "start": probe_start, "capture": probe_capture}
    for op in ops:
        results[op] = runners[op](client, delay, verify_timeout)
        gap(1.5)

    ensure_recording(client, delay, verify_timeout)

    print("\n" + "=" * 46)
    print(" 探针结论")
    print("=" * 46)
    for op in ops:
        print(f"  {op:8s} {results.get(op, '(未运行)')}")
    print("\n定位指引:")
    print("  · 全部 ✅ 而 iOS 无效 → App 侧问题, 优先排查:")
    print("      1) 控制页 RTSP 直播开启时设备忙, CGI 明显变慢, 先关直播再点按钮;")
    print("      2) iOS 查询超时 5s/控制 15s, 设备忙十几秒时 App 先放弃了 (超时≠失败);")
    print("      3) 状态页轮询与控制命令在串行通道上互相插队, 可对照本脚本加静置间隔.")
    print("  · 出现 ⚠️'回执成功但无效果' → 设备侧问题: 卡满(3017)/卡慢/固件状态机,")
    print("      先断电重启复测; 仍复现则备份后 uv run script.py control --format-sd")

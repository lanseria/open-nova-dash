"""指令扫描台 (逐条试出设备真正认的命令码).

动机: 慢速探针 (probe) 三项全部无效果后, 怀疑命令码/参数本身不对.
本模块把协议候选命令做成可逐条试射的清单, 以人的听/视觉为判据:
- 交互模式 (`try`): 打编号单发一条, 发完停顿, 由人听提示音/看屏幕判断;
- 自动连发 (`try --all`): 按清单顺序连发, 条目间停顿 --gap 秒;
- 单发任意命令 (`try --cmd 2001 --str 1`): 对任意组合做一次性测试,
  也用于显式试探厂商自定义命令 (8005/8020).

红线: 清单只放非破坏性命令; 格卡(3010)/恢复出厂(3011)/删文件(4003/4004)
不在清单里, 单发时必须二次确认. 读超时 ≠ 失败, 超时后只等设备恢复不重发.
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from . import probe
from .core import extract_fpath
from .probe import ensure_recording, log, settle

# 危险命令: 不进候选清单, 手动单发必须二次确认
DESTRUCTIVE_CMDS = {3010: "格式化 SD 卡", 3011: "恢复出厂设置", 4003: "删除单个文件", 4004: "删除全部文件"}
# 厂商自定义命令: 用途未知, 行为不可预期
VENDOR_UNKNOWN_CMDS = {8005: "厂商自定义(用途未知)", 8020: "厂商自定义(用途未知)"}


@dataclass
class Shot:
    """一条待试射的命令."""

    cmd: int
    par: int | None = None
    str_par: str | None = None
    group: str = "其他"
    label: str = ""
    timeout: float = 8
    note: str = ""
    pause_after: float | None = None  # 自动连发时覆盖默认间隔 (秒)

    @property
    def spec(self) -> str:
        if self.str_par is not None:
            return f"cmd={self.cmd}&str={self.str_par}"
        if self.par is not None:
            return f"cmd={self.cmd}&par={self.par}"
        return f"cmd={self.cmd}"


CANDIDATES: list[Shot] = [
    Shot(2001, str_par="0", group="停录", label="停止录像 (str= 写法)", timeout=15,
         note="2026-09-18 实测: 无提示音无效果 (回执不可信)"),
    Shot(2001, par=0, group="停录", label="停止录像 (par= 写法)", timeout=15,
         note="✅ 2026-09-18 扫描台实测: 有提示音, 真停"),
    Shot(2001, str_par="1", group="开录", label="开始录像 (str= 写法)", timeout=15,
         note="2026-09-18 实测: 无提示音无效果"),
    Shot(2001, par=1, group="开录", label="开始录像 (par= 写法)", timeout=15,
         note="✅ 2026-09-18 扫描台实测: 有提示音, 真开"),
    Shot(1001, group="拍照", label="直接拍照", timeout=8,
         note="成功回 <FPATH>; -5=写卡失败"),
    Shot(2017, group="拍照", label="抓拍第一步 (2017)", timeout=8, pause_after=1.5,
         note="-13=执行失败; 成功后立刻试 2018"),
    Shot(2018, group="拍照", label="抓拍第二步: 保存 (2018)", timeout=8,
         note="-1=无文件 (说明 2017 没拍到东西)"),
    Shot(3001, par=0, group="模式", label="切模式 par=0 (推断=照片)", timeout=12,
         note="生效则 3037 回报 4"),
    Shot(3001, par=1, group="模式", label="切模式 par=1 (录像)", timeout=12,
         note="生效则 3037 回报 1"),
    Shot(2015, par=1, group="对照", label="开实时画面 (2015&par=1)", timeout=8,
         note="阳性对照: 命令通道若通, 设备屏幕应有反应"),
    Shot(2015, par=0, group="对照", label="关实时画面 (2015&par=0)", timeout=8,
         note="发完立即恢复, 不影响后续测试"),
]


@dataclass
class Scenario:
    """拍照组合实验: 一组有序步骤 (模式切换 + 拍照 + 恢复), 带落盘验证."""

    label: str
    note: str
    steps: tuple[Shot, ...]


# 2026-09-18 定论: 2001 只认 par= 写法, 所有恢复录像一律 2001&par=1
CAPTURE_SCENARIOS: list[Scenario] = [
    Scenario("录像中 1001 直接拍", "验证录像状态下 1001 是否真的落盘", (
        Shot(1001, group="拍照", label="1001 直接拍 (录像中)", timeout=8),
    )),
    Scenario("录像中 2017→2018 抓拍", "两步抓拍 (录像中), 步间 1.5s", (
        Shot(2017, group="拍照", label="2017 抓拍步1", timeout=8),
        Shot(2018, group="拍照", label="2018 保存步2", timeout=8),
    )),
    Scenario("照片模式 1001", "切照片模式(par=0) → 1001 → 切回(par=1) → 恢复录像(par=1)", (
        Shot(3001, par=0, group="模式", label="切照片模式 (3001&par=0)", timeout=12),
        Shot(1001, group="拍照", label="1001 直接拍 (照片模式)", timeout=8),
        Shot(3001, par=1, group="模式", label="切回录像模式 (3001&par=1)", timeout=12),
        Shot(2001, par=1, group="开录", label="恢复循环录像 (2001&par=1)", timeout=15),
    )),
    Scenario("照片模式 2017→2018", "照片模式下两步抓拍, 完毕恢复录像", (
        Shot(3001, par=0, group="模式", label="切照片模式 (3001&par=0)", timeout=12),
        Shot(2017, group="拍照", label="2017 抓拍步1 (照片模式)", timeout=8),
        Shot(2018, group="拍照", label="2018 保存步2", timeout=8),
        Shot(3001, par=1, group="模式", label="切回录像模式 (3001&par=1)", timeout=12),
        Shot(2001, par=1, group="开录", label="恢复循环录像 (2001&par=1)", timeout=15),
    )),
]


def print_menu() -> None:
    print("\n候选命令清单 (输入编号单发一条):")
    group = None
    for i, shot in enumerate(CANDIDATES, 1):
        if shot.group != group:
            group = shot.group
            print(f"  ── {group} ──")
        note = f"   ({shot.note})" if shot.note else ""
        print(f"   {i:2d}. {shot.spec:<18s} {shot.label}{note}")
    print("\n拍照组合实验 (输入 1xx 编号, 自动带落盘验证):")
    for i, sc in enumerate(CAPTURE_SCENARIOS, 101):
        print(f"  {i}. {sc.label}  -- {sc.note}")
    print("\n  其他输入: a=自动连发全部   c=连发拍照实验   s=查状态(3037/2016)   l=再看清单   q=退出")
    print("  任意命令直接输: `2001 par=1` / `1001` / `8005`")


def confirm_destructive(shot: Shot) -> bool:
    if shot.cmd in VENDOR_UNKNOWN_CMDS:
        print(f"    ⚠️ {VENDOR_UNKNOWN_CMDS[shot.cmd]}, 行为不可预期")
    if shot.cmd not in DESTRUCTIVE_CMDS:
        return True
    print(f"    ⚠️ 危险命令: {DESTRUCTIVE_CMDS[shot.cmd]}! 不可逆.")
    return input("       确认执行? 输入 yes: ").strip().lower() == "yes"


def fire(client, shot: Shot):
    """发射一条命令: 打印 URL (可粘到浏览器交叉验证), 提醒听音, 超时只等不重发.

    返回 XML 根节点 (网络异常/非 XML 为 None)."""
    if not confirm_destructive(shot):
        print("    已取消")
        return None
    url = f"{client.base_url}/?custom=1&{shot.spec}"
    print(f"\n🎯 [{shot.group}] {shot.label}")
    print(f"    URL: {url}   (也可粘到浏览器手动发)")
    print("    … 请留意设备提示音 / 屏幕反应 …")
    start = time.time()
    root = client.send_cmd(shot.cmd, par=shot.par, str_par=shot.str_par,
                           description=f"试射 {shot.spec}", timeout=shot.timeout)
    log(f"◀ 完成, 耗时 {time.time() - start:.1f}s")
    if root is None:
        client.wait_device_back(30, "设备无响应 (读超时≠失败, 不重发), 等恢复后继续")
    return root


def show_state(client) -> None:
    mode = probe.query_mode(client)
    if mode is not None:
        print(f"  工作模式 3037={mode} ({probe.MODE_LABELS.get(mode, '未知')})")
    recording = probe.is_recording(client)
    print(f"  录像状态 2016: {'录像中' if recording else '未录像' if recording is not None else '查询失败'}")


def run_scenario(client, number: int, sc: Scenario, step_gap: float = 2.0) -> None:
    """跑一个拍照组合实验: 逐步发射, 结束用 1003/FPATH 复核照片是否真的落盘."""
    print(f"\n══════════ 实验 {number}: {sc.label} ══════════")
    print(f"    {sc.note}; 快门音 + 1003 减少 + FPATH 三者凑齐才算拍照成功")
    before = probe.remaining_photos(client)
    fpath: str | None = None
    for i, shot in enumerate(sc.steps):
        if i:
            log(f"⏳ 步间停 {step_gap:g}s")
            time.sleep(step_gap)
        root = fire(client, shot)
        found = extract_fpath(root)
        if found:
            fpath = found
    # 实验内部的恢复步骤(切回录像模式/2001&par=1)不算拍照耗时, 稍等再复核
    settle(1.5, "等写卡彻底完成再复核")
    after = probe.remaining_photos(client)
    if fpath:
        print(f"  ✅ 回执带照片路径: {fpath}")
    if before is not None and after is not None:
        mark = "✅" if after < before else "⚠️"
        print(f"  {mark} 剩余可拍张数 1003: {before} → {after}"
              + (" (减少 = 照片确实落盘)" if after < before else " (未减少 = 没拍出来)"))
    elif fpath is None:
        print("  ⚠️ 无 FPATH 且 1003 不可用, 请结合快门音与相册判断")


def auto_capture(client, step_gap: float = 2.0, scenario_gap: float = 3.0) -> None:
    print(f"\n自动连发 {len(CAPTURE_SCENARIOS)} 个拍照实验 (步间停 {step_gap:g}s, "
          f"实验间停 {scenario_gap:g}s), 请留意快门音.")
    for i, sc in enumerate(CAPTURE_SCENARIOS, 101):
        run_scenario(client, i, sc, step_gap)
        if i < 100 + len(CAPTURE_SCENARIOS):
            log(f"⏳ 实验间停 {scenario_gap:g}s")
            time.sleep(scenario_gap)
    ensure_recording(client, delay=2, verify_timeout=20)


def parse_raw(raw: str) -> Shot | None:
    """解析手动输入: `2001 str=1` / `2001 par=0` / `1001`."""
    parts = raw.replace(":", " ").split()
    try:
        cmd = int(parts[0])
    except ValueError:
        print("  看不懂输入. 示例: 2001 str=1 / 2001 par=0 / 1001")
        return None
    par: int | None = None
    str_par: str | None = None
    for token in parts[1:]:
        if token.startswith("par=") and token[4:].isdigit():
            par = int(token[4:])
        elif token.startswith("str="):
            str_par = token[4:]
        else:
            print(f"  不认识的参数 {token!r} (只支持 par=N / str=S)")
            return None
    return Shot(cmd, par, str_par, group="手动", label=f"手动输入: {raw}", timeout=15)


def auto(client, gap: float) -> None:
    total = len(CANDIDATES)
    est = sum(s.pause_after if s.pause_after is not None else gap for s in CANDIDATES)
    print(f"\n自动连发 {total} 条, 条目间停 {gap:g}s, 全程约 {est + total * 2:.0f}s.")
    print("请守在设备旁: 听提示音、看屏幕, 记下哪几条有反应.")
    for i, shot in enumerate(CANDIDATES, 1):
        print(f"\n────────── 第 {i}/{total} 条 ──────────")
        fire(client, shot)
        pause = shot.pause_after if shot.pause_after is not None else gap
        if i < total:
            log(f"⏳ 停 {pause:g}s (听提示音 / 看屏幕)")
            time.sleep(pause)
    print("\n────────── 连发结束, 最终状态 ──────────")
    show_state(client)


def interactive(client) -> None:
    print_menu()
    last: Shot | None = None
    while True:
        try:
            raw = input("\n试射 > ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not raw:
            if last is not None:
                fire(client, last)   # 回车重发上一条, 方便再听一次
            else:
                print("  (回车=重发上一条; 先选一条)")
            continue
        if raw in ("q", "quit", "exit"):
            break
        if raw == "l":
            print_menu()
            continue
        if raw == "s":
            show_state(client)
            continue
        if raw == "a":
            auto(client, 4.0)
            continue
        if raw == "c":
            auto_capture(client)
            continue
        if raw.isdigit():
            n = int(raw)
            if 101 <= n < 101 + len(CAPTURE_SCENARIOS):
                run_scenario(client, n, CAPTURE_SCENARIOS[n - 101])
                continue
            if 1 <= n <= len(CANDIDATES):
                last = CANDIDATES[n - 1]
                fire(client, last)
                continue
            print(f"  编号超出范围 (命令 1-{len(CANDIDATES)}, 实验 101-{100 + len(CAPTURE_SCENARIOS)})")
            continue
        parsed = parse_raw(raw)
        if parsed is None:
            continue
        last = parsed
        fire(client, last)


def single(client, cmd: int, par: int | None, str_par: str | None) -> None:
    shot = Shot(cmd, par, str_par, group="手动", label=f"单发 cmd={cmd}", timeout=15)
    fire(client, shot)


def page_try(client, args) -> None:
    print("=" * 46)
    print(" 指令扫描台 (逐条试出设备真正认的命令码)")
    print("=" * 46)
    print("判据用人耳/眼睛: 每条发完留意设备提示音与屏幕反应;")
    print("回执 Status=0 只说明固件收下了, 不代表真的执行了.")
    if args.list:
        print_menu()
        return
    if args.cmd is not None:
        single(client, args.cmd, args.par, args.str_par)
        return
    if getattr(args, "capture", False):
        auto_capture(client)
        return
    if args.all:
        auto(client, args.gap)
    else:
        interactive(client)
    # 交互/连发结束都收尾回循环录像 (单发模式不动, 由测试者自己掌控)
    if not args.cmd:
        ensure_recording(client, delay=2, verify_timeout=20)

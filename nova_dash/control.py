"""控制台 (对应 iOS 控制页: ControlView.swift).

拍照/录像/直播节点/SD 卡格式化. 安全连招与 iOS ControlModel 一致:
- 拍照: 直接 1001, 失败(-22)再走 模式切换连招, 收尾必恢复录像
- 录像: 2001 只认 str= 传参; 超时不重发, 等设备恢复后按需补发
"""

from __future__ import annotations

import time

from .core import extract_fpath, is_ok

LIVE_STREAMS = {
    "主码流 (高清 1080P/4K)": "rtsp://192.168.1.254/novatek/main",
    "子码流 (标清/低延迟)": "rtsp://192.168.1.254/novatek/sub",
}


def recording_seconds(client) -> int | None:
    """cmd 2016 当前录像片段秒数 (0=未录像, None=查询失败)."""
    root = client.send_cmd(2016, description="查询录像状态 (2016, 0=未录像)")
    if root is None:
        return None
    value = root.findtext("Value")
    return int(value) if value and value.isdigit() else None


def capture(client) -> None:
    """拍照: 与 iOS 相同的安全连招, 避免让记录仪停在非录像状态.

    模式枚举 2026-09-17 实测校准 (3037 回报): par=0=照片(3037=4), par=1=录像(3037=1), par=2=回放(3037=3).
    """
    root = client.send_cmd(1001, description="直接拍照", timeout=6)
    fpath = extract_fpath(root)
    if is_ok(root) or fpath:
        print(f"  📷 照片已保存: {fpath}" if fpath else "  ✅ 拍照成功")
        return

    print("  → 直接拍照失败, 走模式切换连招: 照片模式(par=0) → 拍照 → 录像模式(par=1) → 恢复录像")
    client.send_cmd(3001, par=0, description="切换到照片模式 (par=0, 实测=照片)", timeout=12)
    time.sleep(2)
    root = client.send_cmd(1001, description="执行拍照 (cmd=1001)", timeout=6)
    fpath = extract_fpath(root)
    if fpath:
        print(f"  📷 照片已保存: {fpath}")
    else:
        status = root.findtext("Status") if root is not None else None
        hint = "(-5 = EIO 写卡失败, 卡满常见, 建议格式化后复测)" if status == "-5" else ""
        print(f"  ⚠️ 拍照未确认 {hint}")
    time.sleep(1.5)

    client.send_cmd(3001, par=1, description="切回录像模式 (par=1, 实测=录像)", timeout=12)
    time.sleep(3)
    # 本机切模式不会自动恢复循环录像, 收尾必须补 2001&str=1;
    # 超时只等恢复, 恢复后补发一次是安全的 (-22 = 已在录像, 无副作用)
    root = client.send_cmd(2001, str_par=1, description="恢复录像 (收尾)", timeout=15)
    if root is None and client.wait_device_back(60, "设备无响应, 等待恢复"):
        client.send_cmd(2001, str_par=1, description="补发恢复录像 (str=1)", timeout=15)
    seconds = recording_seconds(client)
    if seconds is not None and seconds > 0:
        print(f"  ✅ 已恢复录像 (2016={seconds}s)")


def set_record(client, on: bool) -> bool:
    action = "开始" if on else "停止"
    root = client.send_cmd(
        2001, str_par=int(on),
        description=f"{action}录像 (str={int(on)}; -22=已在目标状态)", timeout=15,
    )
    if is_ok(root):
        print(f"  ✅ 已{action}录像")
        time.sleep(2 if on else 1)
    elif root is None:
        client.wait_device_back(60, f"{action}录像后设备无响应 (不重发, 避免重复执行)")
    # 2016 复核实际状态 (不再靠命令反馈推断)
    seconds = recording_seconds(client)
    if seconds is None:
        return is_ok(root)
    if seconds > 0:
        print(f"  ✅ 已确认录像中 (2016={seconds}s)")
        return on
    print("  ✅ 已确认未录像")
    return not on


def show_live() -> None:
    print("=" * 40)
    print(" RTSP 直播节点 (对应 iOS 控制页实时画面)")
    print("=" * 40)
    for label, url in LIVE_STREAMS.items():
        print(f"  📺 {label}\n      {url}")
    print("\n  终端验证方式 (任选其一):")
    print("    ffplay -fflags nobuffer rtsp://192.168.1.254/novatek/sub")
    print("    或用 VLC 打开上述地址")


def format_sd(client) -> None:
    """显式确认后才执行的 SD 卡格式化."""
    print("=" * 40)
    print(" ⚠️  SD 卡格式化 (cmd=3010&str=1)")
    print("=" * 40)
    print("卡上全部文件 (循环录像/照片/锁定片段) 将被永久删除!")
    print("如未备份, 请先运行 uv run script.py album --download 关键字 下载需要保留的文件.")
    answer = input("确认已备份并继续格式化? 输入 yes 执行: ").strip().lower()
    if answer != "yes":
        print("已取消, 未做任何改动.")
        return
    # 官方参数为 par (par=1 格卡, par=0 格 flash); 旧写法 str=1 疑似从未生效, 2026-09 起改用 par
    root = client.send_cmd(3010, par=1, description="格式化 SD 卡 (par=1)", timeout=30)
    if is_ok(root):
        print("  → 已发出格式化指令, 设备需要时间重建文件系统")
        client.wait_device_back(60, "等待格式化完成")
        client.send_cmd(3017, description="格式化后查询剩余空间 (应接近卡总容量)")


def page_control(client, args) -> None:
    print("=" * 40)
    print(" 控制台 (对应 iOS 控制页)")
    print("=" * 40)
    if not (args.capture or args.record or args.live or args.format_sd):
        print("未指定操作. 可用: --capture 拍照 / --record on|off 录像 /"
              " --live 直播节点 / --format-sd 格式化")
        show_live()
        return
    if args.live:
        show_live()
    if args.capture:
        capture(client)
    if args.record is not None:
        set_record(client, args.record == "on")
    if args.format_sd:
        format_sd(client)

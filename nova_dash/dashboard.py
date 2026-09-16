"""状态仪表盘 (对应 iOS 状态页: DashboardView.swift).

全部为只读查询: 固件版本 3012 / SD 卡状态 3024 / 剩余空间 3017 / 电池 3019.
"""

from __future__ import annotations

BATTERY_LABELS = {0: "满", 1: "中", 2: "低", 3: "耗尽", 5: "充电中"}
SD_LABELS = {0: "无卡", 1: "正常", 2: "被锁定"}


def page_status(client) -> None:
    print("=" * 40)
    print(" 状态仪表盘 (对应 iOS 状态页, 全部只读查询)")
    print("=" * 40)

    # 固件版本
    root = client.send_cmd(3012, description="设备信息与固件版本", timeout=8)
    firmware = root.findtext("String") if root is not None else None
    if firmware:
        print(f"  🔖 固件: {firmware}")

    # SD 卡状态
    root = client.send_cmd(3024, description="SD 卡状态 (0=无卡 1=正常 2=被锁定)")
    if root is not None:
        value = root.findtext("Value")
        label = SD_LABELS.get(int(value), value) if value and value.isdigit() else value
        print(f"  💾 SD 卡: {label}")
        if value == "0":
            print("  ⚠️ SD 卡未插入! 录像/拍照/文件列表都会失败")

    # 剩余空间
    root = client.send_cmd(3017, description="剩余存储空间 (字节)")
    if root is not None:
        value = root.findtext("Value")
        if value and value.isdigit():
            gb = int(value) / 1024**3
            print(f"  📀 剩余空间: ≈ {gb:.2f} GB")
            if gb < 0.5:
                print("  ⚠️ 卡快满了: 循环覆盖清理会拖慢启动录像, 建议备份后格式化")

    # 电池
    root = client.send_cmd(3019, description="电池状态 (0=满 1=中 2=低 3=耗尽 5=充电中)")
    if root is not None:
        value = root.findtext("Value")
        label = BATTERY_LABELS.get(int(value), value) if value and value.isdigit() else value
        print(f"  🔋 电池: {label}")

"""联咏 (Novatek) 行车记录仪控制脚本 -- CLI 入口.

子命令与 iOS 客户端的功能页面一一对应:

    uv run script.py connect              # 连接页: 探测设备 + 心跳保活演示
    uv run script.py status               # 状态页: 固件/SD 卡/空间/电池仪表盘
    uv run script.py album                # 相册页: 文件列表
    uv run script.py album --download 关键字   # 相册页: 按文件名子串下载到 ./downloads/
    uv run script.py control --capture    # 控制页: 拍照 (安全连招, 收尾恢复录像)
    uv run script.py control --record on|off   # 控制页: 开始/停止录像
    uv run script.py control --live       # 控制页: RTSP 直播节点
    uv run script.py control --format-sd  # 控制页: 格式化 SD 卡 (需输入 yes)
    uv run script.py all                  # 完整回归: 状态 → 相册 → 拍照 → 录像
    uv run script.py probe                # 慢速探针: 逐一验证 停录→开录→拍照 (排查 iOS 无效果)
    uv run script.py probe --ops capture --delay 5   # 只测拍照, 命令前静置 5s
    uv run script.py try                  # 指令扫描台: 逐条试射候选命令, 听提示音判断设备认哪条
    uv run script.py try --all            # 扫描台自动连发全部候选 (条目间停 4s)
    uv run script.py try --capture-lab    # 拍照组合实验: 按模式×命令连发, 自动验证落盘
    uv run script.py try --cmd 2001 --par 1   # 单发任意命令 (8005/8020 等厂商命令也走这里)
    uv run script.py thumb                # 原生视频封面探测: 4001/4002/?4001/.THM 逐一试, 命中存图
    uv run script.py thumb --file 'A:\\CARDV\\MOVIE\\x.TS' --out thumbs  # 指定样本与输出目录
    (兼容 v6: uv run script.py --format-sd 等价于 control --format-sd)

所有页面都先连接设备(3 次探测)并启动 3s 心跳, 结束自动停止 --
与 iOS 端 ConnectionModel 的生命周期一致. 实现按页面拆分在 nova_dash/ 包中.
"""

from __future__ import annotations

import argparse
import sys
import time

from nova_dash import album, connection, control, core, dashboard, probe, sweep, thumb

SUBCOMMANDS = ("all", "album", "connect", "control", "probe", "status", "thumb", "try")


def parse_args(argv: list[str]) -> argparse.Namespace:
    # 兼容 v6 入口: uv run script.py --format-sd
    if "--format-sd" in argv and not (set(argv) & set(SUBCOMMANDS)):
        argv = ["control", *argv]

    parser = argparse.ArgumentParser(
        description="联咏 Novatek 行车记录仪控制脚本 (子命令与 iOS 页面一一对应)",
    )
    parser.add_argument("page", nargs="?", default="status", choices=SUBCOMMANDS,
                        help="功能页面 (默认: status)")
    parser.add_argument("--download", metavar="关键字",
                        help="album: 按文件名子串下载匹配文件到 ./downloads/")
    parser.add_argument("--capture", action="store_true", help="control: 拍照")
    parser.add_argument("--record", choices=["on", "off"], help="control: 开始/停止录像")
    parser.add_argument("--live", action="store_true", help="control: 打印 RTSP 直播节点")
    parser.add_argument("--format-sd", action="store_true",
                        help="control: 格式化 SD 卡 (危险操作, 需输入 yes 确认)")
    parser.add_argument("--ops", default=probe.DEFAULT_OPS, metavar="stop,start,capture",
                        help="probe: 选择要验证的操作, 逗号分隔 (默认全部)")
    parser.add_argument("--delay", type=float, default=3.0, metavar="秒",
                        help="probe: 每条控制命令前的静置秒数 (默认 3, 急躁设备可加到 5~8)")
    parser.add_argument("--verify-timeout", type=float, default=25.0, metavar="秒",
                        help="probe: 命令后轮询 2016 复核真实状态的窗口 (默认 25)")
    parser.add_argument("--cmd", type=int, metavar="N",
                        help="try: 单发指定命令号 (危险命令会要求二次确认)")
    parser.add_argument("--par", type=int, metavar="N", help="try: 配合 --cmd 的 par 参数")
    parser.add_argument("--str", dest="str_par", metavar="S", help="try: 配合 --cmd 的 str 参数")
    parser.add_argument("--all", action="store_true", help="try: 自动连发全部候选命令")
    parser.add_argument("--capture-lab", action="store_true",
                        help="try: 连发拍照组合实验 (模式×命令, 自动验证照片落盘)")
    parser.add_argument("--gap", type=float, default=4.0, metavar="秒",
                        help="try: 自动连发的条目间隔 (默认 4, 给听提示音留时间)")
    parser.add_argument("--list", action="store_true", help="try: 只打印候选命令清单")
    parser.add_argument("--file", metavar="路径",
                        help="thumb: 指定样本视频的设备路径 (默认自动选最新一段录像)")
    parser.add_argument("--out", default="thumbs", metavar="目录",
                        help="thumb: 命中图片的保存目录 (默认 ./thumbs)")
    return parser.parse_args(argv)


def run_all(client) -> None:
    """完整回归 (v6 流程, 去掉本机已证伪的 2017 抓拍): 状态 → 相册 → 拍照 → 录像."""
    dashboard.page_status(client)
    album.page_album(client)
    control.capture(client)

    print("\n" + "=" * 40)
    print(" 录像控制回归 (cmd=2001&str=)")
    print("=" * 40)
    control.set_record(client, True)
    control.set_record(client, False)
    # 收尾: 行车记录仪必须回到循环录像状态 (本机切模式不自动恢复录像)
    if not control.set_record(client, True):
        print("  ⚠️ 未能确认恢复录像, 请检查设备屏幕!")


def main() -> None:
    args = parse_args(sys.argv[1:])
    client = core.NovatekClient()
    keeper = connection.HeartbeatKeeper(client)

    # 连接生命周期与 iOS 一致: 先探测, 成功后才启动心跳
    if not connection.connect(client):
        print("\n❌ 无法连接记录仪 (192.168.1.254), 请检查:")
        print("   1. 本机是否已连接记录仪 Wi-Fi")
        print("   2. 网关是否为 192.168.1.254 (macOS: netstat -nr | grep default)")
        sys.exit(1)
    print("✅ 已连接, 启动心跳保活 (3s)")
    keeper.start()

    try:
        if args.page == "connect":
            print("\n心跳保活演示 10s (对应 iOS 连接成功后的持续监控)...")
            time.sleep(10)
            print(f"  ✅ 心跳正常, 累计 {keeper.beat_count} 次")
        elif args.page == "status":
            dashboard.page_status(client)
        elif args.page == "album":
            album.page_album(client, args.download)
        elif args.page == "control":
            control.page_control(client, args)
        elif args.page == "probe":
            wanted = [o.strip() for o in dict.fromkeys(args.ops.split(","))]
            unknown = [o for o in wanted if o and o not in probe.OP_CHOICES]
            if unknown:
                print(f"⚠️ 忽略未知操作: {', '.join(unknown)} (可选: {', '.join(probe.OP_CHOICES)})")
            ops = [o for o in wanted if o in probe.OP_CHOICES]
            if not ops:
                print("❌ 没有可运行的探针操作")
                sys.exit(1)
            probe.run_probe(client, ops, args.delay, args.verify_timeout)
        elif args.page == "try":
            sweep.page_try(client, args)
        elif args.page == "thumb":
            thumb.page_thumb(client, args)
        elif args.page == "all":
            run_all(client)
    finally:
        keeper.stop()

    print("\n=== 完成 ===")
    print("提示: 中途失联多为设备卡满/卡死, 断电重启即可恢复;")
    print("      卡满是拍照(-5)/录像(-22) 异常的常见根因, 备份后运行:")
    print("      uv run script.py control --format-sd")


if __name__ == "__main__":
    main()

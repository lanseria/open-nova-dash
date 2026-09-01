"""联咏 (Novatek) 行车记录仪 CGI 控制与诊断脚本.

相对上一版的修复要点:
1. cmd=2001 录像控制: 部分行车记录仪固件只认 str= 参数(如 BlackSys CH-100),
   只发 par= 会返回 -22 (EINVAL), 本版两种参数名都尝试.
2. cmd=3015 文件列表: 录像进行中固件会拒绝(返回 -3), 需先切到回放模式
   (cmd=3001&par=2) 再查询, 查完切回视频模式.
3. 增加只读诊断命令: 3012 版本 / 3024 SD卡状态 / 3017 剩余空间 / 3019 电池,
   先确认设备与存储状态再测试控制命令.
4. 后台心跳线程: 联咏要求 APP 每 3~5 秒发一次 cmd=3016, 否则设备可能断开.
5. 拍照验证: cmd=1001 成功时响应里的 <FPATH> 是照片保存路径, 据此确认真的拍到了.
"""

import threading
import time
import xml.etree.ElementTree as ET

import requests

BASE_URL = "http://192.168.1.254"
HEARTBEAT_INTERVAL = 3.0  # readme: 必须每 3~5 秒心跳一次

# 负数 Status 与 Linux errno 编号一致, 以下是实测/社区文档中出现过的:
ERROR_HINTS = {
    -1: "不支持/被拒绝",
    -3: "存储或状态错误: 录像中查文件列表、SD 卡未就绪时常见",
    -13: "抓拍执行失败 (exec fail)",
    -22: "EINVAL 参数无效: 固件不认这个参数名/参数值, 或当前状态不允许",
}

session = requests.Session()
heartbeat_stop = threading.Event()


def heartbeat_loop():
    while not heartbeat_stop.wait(HEARTBEAT_INTERVAL):
        try:
            session.get(BASE_URL + "/", params={"custom": 1, "cmd": 3016}, timeout=2)
        except requests.RequestException:
            pass


def describe_status(root):
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


def is_ok(root):
    return root is not None and root.findtext("Status") == "0"


def send_cmd(cmd, par=None, str_par=None, description="", timeout=4):
    """发送 CGI 指令并解析 XML 响应, 返回 XML 根节点(失败返回 None)."""
    params = {"custom": 1, "cmd": cmd}
    if par is not None:
        params["par"] = par
    if str_par is not None:
        params["str"] = str_par
    param_desc = (
        f"str={str_par}" if str_par is not None
        else f"par={par}" if par is not None
        else "无参数"
    )
    print(f"\n【测试】{description} (cmd={cmd}, {param_desc})")
    try:
        resp = session.get(BASE_URL + "/", params=params, timeout=timeout)
    except requests.RequestException as e:
        print(f"  └─ 请求异常: {e}")
        return None

    raw = resp.text.strip()
    try:
        root = ET.fromstring(raw)
    except ET.ParseError:
        print(f"  └─ 非标准 XML 响应: {raw[:300]}")
        return None

    print(f"  └─ 结果: {describe_status(root)}")
    # 打印返回的数据字段: 版本在 <String>, 查询结果在 <Value>, 拍照路径在 <File><FPATH>
    for child in root:
        text = (child.text or "").strip()
        if child.tag in ("Cmd", "Status") or not text:
            continue
        print(f"      {child.tag}: {text[:200]}")
    return root


def print_file_list(root, max_items=15):
    paths = [e.text.strip() for e in root.iter("FPATH") if e.text and e.text.strip()]
    if not paths:
        print("  (文件列表为空或本固件的列表结构不同, 可检查上面的原始字段)")
        return
    photos = [p for p in paths if p.upper().endswith((".JPG", ".JPEG"))]
    videos = [p for p in paths if p.upper().endswith((".MP4", ".MOV", ".TS"))]
    others = [p for p in paths if p not in photos and p not in videos]
    print(f"  📁 共 {len(paths)} 个文件: {len(photos)} 张照片, {len(videos)} 个视频, {len(others)} 其他")
    for label, group in (("照片", photos), ("视频", videos), ("其他", others)):
        for p in group[:max_items]:
            print(f"      [{label}] {p}")
        if len(group) > max_items:
            print(f"      ... 其余 {len(group) - max_items} 个省略")


def diagnose():
    print("=" * 40)
    print(" 第 1 步: 设备状态诊断 (全部为只读查询)")
    print("=" * 40)
    send_cmd(3012, description="查询设备信息与版本")

    root = send_cmd(3024, description="查询 SD 卡状态 (0=无卡 1=正常 2=被锁定)")
    if root is not None and root.findtext("Value") == "0":
        print("  ⚠️ SD 卡未插入! 录像/拍照/文件列表都会失败, 请先插卡再测")

    root = send_cmd(3017, description="查询剩余存储空间 (字节)")
    if root is not None:
        value = root.findtext("Value")
        if value and value.isdigit():
            print(f"      ≈ {int(value) / 1024**3:.1f} GB 可用")

    send_cmd(3019, description="查询电池状态 (0=满 1=中 2=低 3=耗尽 5=充电中)")


def test_record_control():
    print("\n" + "=" * 40)
    print(" 第 2 步: 录像控制测试 (cmd=2001)")
    print("=" * 40)

    # 先用 str= 参数尝试: 部分行车记录仪固件(如 BlackSys)只认 str, 只发 par 会 -22
    root = send_cmd(2001, str_par=0, description="停止录像 (str=0)")
    if is_ok(root):
        print("  → str= 参数有效! 本机固件的 2001 用 str 传参")
        time.sleep(1)
        send_cmd(2001, str_par=1, description="恢复录像 (str=1)")
    else:
        print("  → str=0 也失败, 再用 par=0 对照 (上一版脚本的用法)")
        send_cmd(2001, par=0, description="停止录像 (par=0, 对照)")

    # 2001 不带参数 = 查询录像状态 (GitUp Git2 的用法), 无 par 时多数固件不会误触发动作
    root = send_cmd(2001, description="查询录像状态 (2001 不带参数)")
    if is_ok(root):
        value = root.findtext("Value")
        if value is not None:
            print(f"      当前状态: {'正在录像' if value == '1' else '未在录像'} (Value={value})")

    print("  ℹ️ 若两种参数都返回 -22: 行车记录仪固件常禁用 APP 端录像开关,")
    print("     属固件设计而非脚本问题; 循环录像由设备自管, 不影响抓拍.")


def test_capture():
    print("\n" + "=" * 40)
    print(" 第 3 步: 拍照测试")
    print("=" * 40)

    # 方式 A: 2017 = 录像中抓拍快照 (GitUp Git2 实测用法; 失败时固件返回 -13)
    root = send_cmd(2017, description="方式 A: 录像中抓拍快照 (cmd=2017)")
    if is_ok(root):
        print("  → 支持 2017 抓拍, 无需打断录像")
    else:
        print("  → 本机不支持 2017 (或当前未在录像), 改用模式切换法")
    time.sleep(1)

    # 方式 B: 切照片模式 -> 1001 拍照 -> 切回视频模式 (上一版已验证 3001/1001 均返回 0)
    print("\n--- 方式 B: 切换模式拍照 ---")
    send_cmd(3001, par=1, description="切换到照片模式 (par=1)")
    time.sleep(1.5)

    root = send_cmd(1001, description="执行拍照 (cmd=1001)")
    fpath = next((e.text.strip() for e in root.iter("FPATH") if e.text), None) if root else None
    if fpath:
        print(f"  📷 照片已保存: {fpath}")
    else:
        print("  ⚠️ 响应中无 <FPATH>, 拍照是否生效需在第 4 步文件列表中确认")
    time.sleep(1)

    send_cmd(3001, par=0, description="切回视频模式 (par=0), 固件一般会自动恢复循环录像")


def test_file_list():
    print("\n" + "=" * 40)
    print(" 第 4 步: 文件列表测试 (cmd=3015)")
    print("=" * 40)

    root = send_cmd(3015, description="直接查询文件列表")
    if is_ok(root):
        print_file_list(root)
        return

    print("  → 直接查询失败(录像中常被拒, 返回 -3), 改走联咏 APP 相册标准流程:")
    print("     先切回放模式 -> 查列表 -> 切回视频模式")
    send_cmd(3001, par=2, description="切换到回放模式 (par=2)")
    time.sleep(1.5)

    root = send_cmd(3015, description="回放模式下查询文件列表")
    if is_ok(root):
        print_file_list(root)
    else:
        print("  ⚠️ 回放模式下仍失败, 请结合第 1 步 SD 卡状态排查 (无卡/卡错误时 3015 必败)")

    send_cmd(3001, par=0, description="切回视频模式 (par=0)")


if __name__ == "__main__":
    print("=== 联咏 Novatek 行车记录仪控制指令测试 (修复版) ===")
    print("说明: Status<0 为错误码(即 Linux errno), 括号内为常见含义")

    threading.Thread(target=heartbeat_loop, daemon=True).start()

    diagnose()
    test_record_control()
    test_capture()
    test_file_list()

    heartbeat_stop.set()
    print("\n=== 测试结束 ===")

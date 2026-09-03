"""联咏 (Novatek) 行车记录仪 CGI 控制与诊断脚本.

v5 变更 (基于 860N72-SF20200714 固件四轮实测):
1. 实测 3015 完全可用: 直接返回文件树(无 Status), 照片在 A:\\CARDV\\PHOTO\\*.JPG,
   循环录像在 A:\\CARDV\\MOVIE\\*.TS; 早期测试拍的照片已确认落卡.
2. 卡写满(剩 0.21GB/344个TS)是该设备的当前根因: 1001 拍照 -5(EIO 写卡失败),
   2001 开始/停止录像 -22 或长时间阻塞并拖死 HTTP.
   新增显式确认的格式化入口: uv run script.py --format-sd
3. 2001 无参数查询返回 -21: 本机不支持查询变体, 录像状态只能靠命令反馈推断.
4. 失联恢复等待加长到 60s (实测卡满时设备可阻塞 30s 以上).

v4 变更:
1. 3015 按 <FPATH> 判定成功, 不依赖 Status.
2. 2001 状态机敏感: str=0 只在录像中有效, str=1 只在空闲时有效, 重复同状态 -22;
   录像控制改为状态感知流程, 收尾确保回到录像状态(本机切模式不自动恢复循环录像).
3. 修复 XML 元素 truthiness 误判; 2017 挪到"确认录像中"后复测.

v3 变更:
1. 本机 2001 录像控制用 str= 传参 (par= 返回 -22).
2. 单线程 HTTP 服务器: 所有请求(含心跳)经锁串行; 重命令长超时+自动重试;
   录像控制放最后避免拖垮前面测试; wait_device_back() 轮询恢复.
"""

import sys
import threading
import time
import xml.etree.ElementTree as ET

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE_URL = "http://192.168.1.254"
HEARTBEAT_INTERVAL = 3.0  # readme: 必须每 3~5 秒心跳一次

# 负数 Status 与 Linux errno 编号一致, 以下是实测/社区文档中出现过的:
ERROR_HINTS = {
    -1: "不支持/被拒绝",
    -3: "存储或状态错误: 录像中查文件列表、SD 卡未就绪时常见",
    -5: "EIO 写卡失败: 卡满或卡故障, 备份后格式化 (本机实测卡满时 1001 拍照返回此码)",
    -13: "抓拍执行失败 (exec fail)",
    -21: "本机实测于 2001 无参数查询: 查询变体大概率不支持",
    -22: "EINVAL 参数无效: 固件不认这个参数名/参数值, 或当前状态不允许",
}

# 联咏固件的 HTTP 服务器是单线程的: 并发请求(哪怕只是心跳)会导致
# 连接被重置/服务长时间无响应, 因此所有请求必须经此锁串行.
CMD_LOCK = threading.Lock()

session = requests.Session()
# 单连接池 + 对连接级错误自动重试: 规避 keep-alive 连接被设备
# 单方面关闭后复用报 RemoteDisconnected 的问题 (GET 幂等, 重试安全).
session.mount(
    "http://",
    HTTPAdapter(
        pool_connections=1,
        pool_maxsize=1,
        max_retries=Retry(
            total=2, connect=2, read=1, backoff_factor=0.8,
            allowed_methods=frozenset(["GET"]),
        ),
    ),
)

heartbeat_stop = threading.Event()


def heartbeat_loop():
    while not heartbeat_stop.wait(HEARTBEAT_INTERVAL):
        if not CMD_LOCK.acquire(blocking=False):
            continue  # 有命令正在处理, 本轮心跳让路, 等下一周期
        try:
            session.get(BASE_URL + "/", params={"custom": 1, "cmd": 3016}, timeout=2)
        except requests.RequestException:
            pass
        finally:
            CMD_LOCK.release()


def raw_cmd(cmd, par=None, str_par=None, timeout=4):
    params = {"custom": 1, "cmd": cmd}
    if par is not None:
        params["par"] = par
    if str_par is not None:
        params["str"] = str_par
    resp = session.get(BASE_URL + "/", params=params, timeout=timeout)
    return ET.fromstring(resp.text.strip())


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


def extract_fpath(root):
    """从响应中取第一个 <FPATH> (拍照成功时返回照片保存路径)."""
    if root is None:
        return None
    return next((e.text.strip() for e in root.iter("FPATH") if e.text and e.text.strip()), None)


def parse_file_list(root):
    """解析 3015 响应为路径列表; 本机固件直接返回文件树, 无 Status 包裹."""
    if root is None:
        return None
    return [e.text.strip() for e in root.iter("FPATH") if e.text and e.text.strip()] or None


def send_cmd(cmd, par=None, str_par=None, description="", timeout=4):
    """发送 CGI 指令并解析 XML 响应, 返回 XML 根节点(失败返回 None)."""
    param_desc = (
        f"str={str_par}" if str_par is not None
        else f"par={par}" if par is not None
        else "无参数"
    )
    print(f"\n【测试】{description} (cmd={cmd}, {param_desc})")
    try:
        with CMD_LOCK:
            root = raw_cmd(cmd, par, str_par, timeout)
    except requests.RequestException as e:
        print(f"  └─ 请求异常: {type(e).__name__}: {e}")
        return None
    except ET.ParseError:
        print(f"  └─ 非标准 XML 响应")
        return None

    print(f"  └─ 结果: {describe_status(root)}")
    # 打印返回的数据字段: 版本在 <String>, 查询结果在 <Value>, 拍照路径在 <File><FPATH>
    for child in root:
        text = (child.text or "").strip()
        if child.tag in ("Cmd", "Status") or not text:
            continue
        print(f"      {child.tag}: {text[:200]}")
    return root


def wait_device_back(max_wait=30, description="等待设备恢复响应"):
    """设备 HTTP 失联时轮询心跳, 直到恢复或超时. 返回心跳响应根节点."""
    print(f"\n⏳ {description} (最多 {max_wait}s)...")
    start = time.time()
    deadline = start + max_wait
    while time.time() < deadline:
        if not CMD_LOCK.acquire(blocking=False):
            time.sleep(1)
            continue
        try:
            root = raw_cmd(3016, timeout=3)
            print(f"  ✅ 设备已恢复响应 (耗时约 {time.time() - start:.0f}s)")
            return root
        except (requests.RequestException, ET.ParseError):
            time.sleep(2)
        finally:
            CMD_LOCK.release()
    print("  ❌ 仍未恢复: 设备可能还在忙, 稍等后重跑脚本, 或查看设备屏幕状态")
    return None


def print_file_list(paths, max_items=15):
    if not paths:
        print("  (文件列表为空或本固件的列表结构不同)")
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
    root = send_cmd(3012, description="查询设备信息与版本")
    firmware = root.findtext("String") if root is not None else None
    if firmware:
        print(f"  🔖 固件: {firmware}")

    root = send_cmd(3024, description="查询 SD 卡状态 (0=无卡 1=正常 2=被锁定)")
    if root is not None and root.findtext("Value") == "0":
        print("  ⚠️ SD 卡未插入! 录像/拍照/文件列表都会失败, 请先插卡再测")

    root = send_cmd(3017, description="查询剩余存储空间 (字节)")
    if root is not None:
        value = root.findtext("Value")
        if value and value.isdigit():
            gb = int(value) / 1024**3
            print(f"      ≈ {gb:.2f} GB 可用")
            if gb < 0.5:
                print("  ⚠️ 卡快满了: 循环覆盖清理会拖慢启动录像, 建议备份后在设备上格式化")

    send_cmd(3019, description="查询电池状态 (0=满 1=中 2=低 3=耗尽 5=充电中)")


def test_file_list():
    print("\n" + "=" * 40)
    print(" 第 2 步: 文件列表测试 (cmd=3015)")
    print("=" * 40)

    # 本机固件的 3015 直接返回文件树 XML(无 Status 包裹), 以 FPATH 判定成败
    root = send_cmd(3015, description="直接查询文件列表", timeout=12)
    paths = parse_file_list(root)
    if paths:
        print("  → 成功: 本机 3015 直接返回文件树")
        print_file_list(paths)
        return

    print("  → 响应无 FPATH, 改走联咏 APP 相册标准流程: 先切回放模式再查")
    send_cmd(3001, par=2, description="切换到回放模式 (par=2)", timeout=12)
    time.sleep(2)

    root = send_cmd(3015, description="回放模式下查询文件列表", timeout=12)
    paths = parse_file_list(root)
    if paths:
        print_file_list(paths)
    else:
        print("  ⚠️ 回放模式下也无文件, 请结合第 1 步 SD 卡状态排查")

    send_cmd(3001, par=0, description="切回视频模式", timeout=12)
    time.sleep(3)


def test_capture():
    print("\n" + "=" * 40)
    print(" 第 3 步: 拍照测试 (cmd=1001)")
    print("=" * 40)

    # 方式 A: 直接 1001 (v1 时代实测本机在录像中发 1001 也返回过成功;
    # 上轮照片模式下返回 -5 = errno EIO, 疑似卡快满写卡失败, 格式化后应复测)
    root = send_cmd(1001, description="方式 A: 直接拍照 (cmd=1001)", timeout=6)
    fpath = extract_fpath(root)
    if is_ok(root) or fpath:
        if fpath:
            print(f"  📷 照片已保存: {fpath}")
        print("  → 直接拍照可用, 无需切换模式")
        return

    print("  → 直接拍照失败, 改用模式切换法")
    print("\n--- 方式 B: 切换模式拍照 ---")
    send_cmd(3001, par=1, description="切换到照片模式 (par=1)", timeout=12)
    time.sleep(2)

    root = send_cmd(1001, description="执行拍照 (cmd=1001)", timeout=6)
    fpath = extract_fpath(root)
    if fpath:
        print(f"  📷 照片已保存: {fpath}")
    else:
        status = root.findtext("Status") if root is not None else None
        hint = "(-5 = EIO 写卡失败, 卡快满时常见, 建议格式化后复测)" if status == "-5" else ""
        print(f"  ⚠️ 拍照未确认 {hint}")
    time.sleep(1.5)

    send_cmd(3001, par=0, description="切回视频模式", timeout=12)
    time.sleep(3)


def test_record_control():
    print("\n" + "=" * 40)
    print(" 第 4 步: 录像控制测试 (cmd=2001, 放最后避免拖垮前面测试)")
    print(" 本机实测: str=0 只在录像中有效, str=1 只在空闲时有效,")
    print(" 重复发同状态命令返回 -22")
    print("=" * 40)

    # 先确保进入录像状态 (-22 视为"已在录像中")
    root = send_cmd(2001, str_par=1, description="开始录像 (str=1; -22=已在录像中)", timeout=15)
    if is_ok(root):
        print("  → 已发出开始录像指令, 等待设备稳定...")
        time.sleep(3)
    elif root is None:
        # 单线程服务器阻塞时读会超时, 但命令可能已被执行, 不能凭超时判定失败
        wait_device_back(30, "等待设备恢复响应")
    send_cmd(2001, description="查询录像状态 (2001 无参数; 部分固件支持)")

    # 此刻应处于录像中: 复测 2017 抓拍 (此前在空闲状态下测得 -22, 不能下结论)
    root = send_cmd(2017, description="录像中复测抓拍 (cmd=2017)", timeout=6)
    if is_ok(root):
        print("  → 2017 录像中抓拍可用! APP 抓拍可免切模式")
    else:
        print("  → 2017 不可用, APP 抓拍走 1001 直接拍或模式切换法")
    time.sleep(1)

    send_cmd(2001, str_par=0, description="停止录像 (str=0; -22=本就不在录像)", timeout=12)
    time.sleep(2)
    send_cmd(2001, description="查询录像状态 (预期 Value=0 已停)")

    # 收尾: 行车记录仪必须回到循环录像状态(本机切视频模式不会自动恢复)
    send_cmd(2001, str_par=1, description="恢复录像 (str=1, 确保记录仪回到工作状态)", timeout=15)
    time.sleep(3)
    wait_device_back(60, "等待恢复录像后 HTTP 恢复 (卡满时设备可阻塞较久)")
    send_cmd(2001, description="最终确认录像状态 (预期 Value=1 录像中)")


def format_sd():
    """显式确认后才执行的 SD 卡格式化 (uv run script.py --format-sd)."""
    print("=" * 40)
    print(" ⚠️  SD 卡格式化 (cmd=3010&str=1)")
    print("=" * 40)
    print("卡上全部文件 (循环录像/照片/锁定片段) 将被永久删除!")
    print("如未备份, 请先通过文件列表确认并下载需要保留的文件.")
    answer = input("确认已备份并继续格式化? 输入 yes 执行: ").strip().lower()
    if answer != "yes":
        print("已取消, 未做任何改动.")
        return
    root = send_cmd(3010, str_par=1, description="格式化 SD 卡", timeout=30)
    if is_ok(root):
        print("  → 已发出格式化指令, 设备需要时间重建文件系统")
        wait_device_back(60, "等待格式化完成")
        send_cmd(3017, description="格式化后查询剩余空间 (应接近卡总容量)")


if __name__ == "__main__":
    if "--format-sd" in sys.argv:
        threading.Thread(target=heartbeat_loop, daemon=True).start()
        format_sd()
        heartbeat_stop.set()
        raise SystemExit(0)

    print("=== 联咏 Novatek 行车记录仪控制指令测试 (v5) ===")
    print("说明: Status<0 为错误码(即 Linux errno), 括号内为常见含义;")
    print("      卡满时 1001/2001 异常属预期, 先格式化 (uv run script.py --format-sd)")

    threading.Thread(target=heartbeat_loop, daemon=True).start()

    diagnose()
    test_file_list()
    test_capture()
    test_record_control()

    heartbeat_stop.set()
    print("\n=== 测试结束 ===")
    print("提示: 若第 4 步中途失联, 设备大概率已卡死, 断电重启即可恢复;")
    print("      卡满(剩0.2GB)是当前 1001/-5 与 2001 异常的根因, 备份后运行:")
    print("      uv run script.py --format-sd")

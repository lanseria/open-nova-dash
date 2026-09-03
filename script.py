"""联咏 (Novatek) 行车记录仪 CGI 控制与诊断脚本.

v3 变更 (基于 860N72-SF20200714 固件两轮实测):
1. 已确认本机 2001 录像控制用 str= 传参 (只发 par= 会返回 -22).
2. 实测 "停止录像" 秒回, 但 "恢复录像" 会让固件的单线程 HTTP 服务器长时间
   无响应, 期间一切 CGI (含心跳) 超时/连接重置. 应对:
   - 所有请求串行化: 心跳只在空闲时非阻塞抢锁, 有命令在处理就让路,
     杜绝对单线程服务器并发打请求;
   - 重命令 (录像/切模式) 用长超时 + 连接错误自动重试 + 命令后留稳定等待;
   - 录像控制测试挪到最后, 避免拖垮前面的测试;
   - wait_device_back(): 设备失联时轮询心跳直至恢复.
"""

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
    -13: "抓拍执行失败 (exec fail)",
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

    root = send_cmd(3015, description="直接查询文件列表 (录像中预期被拒, 作对照)", timeout=12)
    if is_ok(root):
        print_file_list(root)
        return

    print("  → 改走联咏 APP 相册标准流程: 先切回放模式 -> 查列表 -> 切回视频模式")
    send_cmd(3001, par=2, description="切换到回放模式 (par=2)", timeout=12)
    time.sleep(2)

    root = send_cmd(3015, description="回放模式下查询文件列表", timeout=12)
    if is_ok(root):
        print_file_list(root)
    else:
        print("  ⚠️ 回放模式下仍失败, 请结合第 1 步 SD 卡状态排查")

    send_cmd(3001, par=0, description="切回视频模式 (固件将自动恢复循环录像)", timeout=12)
    time.sleep(3)
    wait_device_back(20, "切回视频模式后设备要恢复循环录像, 等待 HTTP 恢复")


def test_capture():
    print("\n" + "=" * 40)
    print(" 第 3 步: 拍照测试")
    print("=" * 40)

    # 方式 A: 2017 = 录像中抓拍快照 (GitUp Git2 实测用法; 失败时固件返回 -13)
    root = send_cmd(2017, description="方式 A: 录像中抓拍快照 (cmd=2017)", timeout=6)
    if is_ok(root):
        print("  → 支持 2017 抓拍, 无需打断录像")
    else:
        print("  → 2017 不可用 (或当前未在录像), 改用模式切换法")
    time.sleep(1)

    # 方式 B: 切照片模式 -> 1001 拍照 -> 切回视频模式
    print("\n--- 方式 B: 切换模式拍照 ---")
    send_cmd(3001, par=1, description="切换到照片模式 (par=1)", timeout=12)
    time.sleep(2)

    root = send_cmd(1001, description="执行拍照 (cmd=1001)", timeout=6)
    fpath = next((e.text.strip() for e in root.iter("FPATH") if e.text), None) if root else None
    if fpath:
        print(f"  📷 照片已保存: {fpath}")
    else:
        print("  ⚠️ 响应中无 <FPATH>, 拍照是否生效需在第 2 步文件列表中确认")
    time.sleep(1.5)

    send_cmd(3001, par=0, description="切回视频模式", timeout=12)
    time.sleep(3)
    wait_device_back(20, "等待设备恢复循环录像后的 HTTP 恢复")


def test_record_control():
    print("\n" + "=" * 40)
    print(" 第 4 步: 录像控制测试 (cmd=2001, 放最后:")
    print(" 实测恢复录像会让设备长时间无响应, 避免拖垮前面测试)")
    print("=" * 40)

    root = send_cmd(2001, str_par=0, description="停止录像 (str=0, 本机已验证 str 有效)", timeout=12)
    if not is_ok(root):
        print("  → 停止失败, 跳过本步剩余测试")
        return
    time.sleep(2)
    send_cmd(2001, description="查询录像状态 (预期 Value=0 已停; 部分固件支持)")

    send_cmd(2001, str_par=1, description="恢复录像 (str=1, 实测设备会忙一阵, 长超时)", timeout=15)
    # 单线程服务器阻塞时读会超时, 但命令可能已被设备执行, 不能凭超时判定失败
    time.sleep(3)
    if wait_device_back(30, "等待恢复录像后 HTTP 恢复响应") is not None:
        send_cmd(2001, description="再次查询录像状态 (预期 Value=1 录像中)")


if __name__ == "__main__":
    print("=== 联咏 Novatek 行车记录仪控制指令测试 (v3) ===")
    print("说明: Status<0 为错误码(即 Linux errno), 括号内为常见含义;")

    threading.Thread(target=heartbeat_loop, daemon=True).start()

    diagnose()
    test_file_list()
    test_capture()
    test_record_control()

    heartbeat_stop.set()
    print("\n=== 测试结束 ===")
    print("提示: 若第 4 步中途失联, 查看设备屏幕确认录像是否已恢复;")
    print("      行车记录仪重启或按实体录像键也可恢复循环录像.")

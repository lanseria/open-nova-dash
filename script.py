import time
import xml.etree.ElementTree as ET
import requests

# 联咏方案默认网关地址
BASE_URL = "http://192.168.1.254"


def send_cmd(cmd: int, par: int = None, description: str = "") -> str:
    """发送 CGI 指令并解析联咏的 XML 响应"""
    url = f"{BASE_URL}/?custom=1&cmd={cmd}"
    if par is not None:
        url += f"&par={par}"

    print(f"\n【测试】{description} (cmd={cmd}, par={par})")
    try:
        resp = requests.get(url, timeout=3)
        raw_xml = resp.text.strip()

        # 解析联咏返回的经典 XML 结构: <Function><Cmd>...</Cmd><Status>0</Status></Function>
        try:
            root = ET.fromstring(raw_xml)
            status = root.findtext("Status")
            value = root.findtext("Value")
            status_desc = "✅ 成功" if status == "0" else f"❌ 失败 (错误码: {status})"
            print(f"  └─ 结果: {status_desc} | 返回值: {value}")
        except ET.ParseError:
            print(f"  └─ 原始响应: {raw_xml}")

        return raw_xml
    except Exception as e:
        print(f"  └─ 请求异常: {e}")
        return ""


if __name__ == "__main__":
    print("=== 联咏 Novatek 行车记录仪控制指令测试 ===")

    # 1. 基础通信与状态测试
    send_cmd(3016, description="1. 发送心跳包")
    send_cmd(3012, description="2. 查询设备信息与版本")

    print("\n" + "=" * 40)
    print(" 开始拍照逻辑测试")
    print("=" * 40)

    # 方案 A: 直接尝试“录像中抓拍”指令（不打断录像）
    send_cmd(1002, description="方案 A: 录像中抓拍 (cmd=1002)")
    time.sleep(1)

    # 方案 B: 停止录像 -> 执行拍照 -> 恢复录像 (最稳妥的方式)
    print("\n--- 正在尝试方案 B: 先停录再拍照 ---")
    send_cmd(2001, par=0, description="1) 停止录像")
    time.sleep(1)

    send_cmd(1001, description="2) 执行标准拍照 (cmd=1001)")
    time.sleep(1)

    send_cmd(2001, par=1, description="3) 恢复录像")
    time.sleep(1)

    # 方案 C: 切换为照片模式拍照
    print("\n--- 正在尝试方案 C: 切换模式拍照 ---")
    send_cmd(2001, par=0, description="1) 停止录像")
    send_cmd(3001, par=1, description="2) 切换到照片模式 (par=1:照片, 0:视频)")
    time.sleep(1)

    send_cmd(1001, description="3) 在照片模式下拍照")
    time.sleep(1)

    send_cmd(3001, par=0, description="4) 切回视频模式")
    send_cmd(2001, par=1, description="5) 重新开始录像")

    # 4. 拉取 SD 卡相册列表（查看刚才拍的照片是否存在）
    print("\n" + "=" * 40)
    send_cmd(3015, description="查询 SD 卡文件列表 (cmd=3015)")
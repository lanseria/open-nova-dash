"""相册 (对应 iOS 相册页: AlbumView.swift).

- 文件列表: 3015, 本机固件直接返回文件树 XML(无 Status 包裹), 按 <FPATH> 解析;
  若固件拒绝则回退"切回放模式再查"的标准联咏 APP 流程.
- 下载: URL = 去掉返回路径的 A: 盘符前缀, 同样走串行锁.
"""

from __future__ import annotations

import time
from pathlib import Path

from .core import parse_file_list

DOWNLOAD_DIR = Path("downloads")


def download_url(base_url: str, path: str) -> str:
    """A:\\CARDV\\MOVIE\\x.TS -> http://192.168.1.254/CARDV/MOVIE/x.TS"""
    rel = path.split(":", 1)[-1].replace("\\", "/")
    return base_url + rel


def fetch_file_list(client) -> list[str]:
    root = client.send_cmd(3015, description="查询文件列表", timeout=12)
    paths = parse_file_list(root)
    if paths:
        print("  → 本机 3015 直接返回文件树")
        return paths

    print("  → 响应无 FPATH, 走联咏 APP 标准流程: 先切回放模式再查")
    client.send_cmd(3001, par=2, description="切换到回放模式 (par=2)", timeout=12)
    time.sleep(2)
    root = client.send_cmd(3015, description="回放模式下查询文件列表", timeout=12)
    paths = parse_file_list(root) or []
    client.send_cmd(3001, par=1, description="切回录像模式 (par=1, 2026-09-17 校准)", timeout=12)
    time.sleep(3)
    if not paths:
        print("  ⚠️ 未取到文件, 请结合状态页 SD 卡信息排查")
    return paths


def group_paths(paths: list[str]) -> dict[str, list[str]]:
    photos = [p for p in paths if p.upper().endswith((".JPG", ".JPEG"))]
    videos = [p for p in paths if p.upper().endswith((".MP4", ".MOV", ".TS"))]
    others = [p for p in paths if p not in photos and p not in videos]
    return {"照片": photos, "视频": videos, "其他": others}


def print_file_list(paths: list[str], max_items: int = 15) -> None:
    if not paths:
        print("  (文件列表为空或本固件的列表结构不同)")
        return
    groups = group_paths(paths)
    print(f"  📁 共 {len(paths)} 个文件: "
          f"{len(groups['照片'])} 张照片, {len(groups['视频'])} 个视频, {len(groups['其他'])} 其他")
    for label, group in groups.items():
        for p in group[:max_items]:
            print(f"      [{label}] {p}")
        if len(group) > max_items:
            print(f"      ... 其余 {len(group) - max_items} 个省略")


def download_file(client, path: str) -> Path | None:
    """下载单个文件到 ./downloads/, 打印进度. 下载与命令一样持有串行锁."""
    url = download_url(client.base_url, path)
    name = path.replace("\\", "/").split("/")[-1]
    DOWNLOAD_DIR.mkdir(exist_ok=True)
    dest = DOWNLOAD_DIR / name
    print(f"\n⬇️  下载 {name}")
    print(f"      {url}")
    try:
        with client.cmd_lock:
            resp = client.session.get(url, stream=True, timeout=(3, 30))
            resp.raise_for_status()
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            with dest.open("wb") as f:
                for chunk in resp.iter_content(chunk_size=1 << 16):
                    f.write(chunk)
                    done += len(chunk)
                    if total:
                        print(f"\r      {done / 1048576:.1f} / {total / 1048576:.1f} MB",
                              end="", flush=True)
    except OSError as e:
        print(f"\n  ❌ 写入失败: {e}")
        return None
    except Exception as e:  # noqa: BLE001 - requests 异常统一提示
        print(f"\n  ❌ 下载失败: {type(e).__name__}: {e}")
        return None
    print(f"\n  ✅ 已保存: {dest}")
    return dest


def page_album(client, download_keyword: str | None = None) -> None:
    print("=" * 40)
    print(" 相册 (对应 iOS 相册页, cmd=3015)")
    print("=" * 40)
    paths = fetch_file_list(client)
    print_file_list(paths)

    if download_keyword:
        matches = [p for p in paths if download_keyword.lower() in p.lower()]
        if not matches:
            print(f"\n⚠️ 没有文件名包含 \"{download_keyword}\" 的文件")
            return
        print(f"\n匹配到 {len(matches)} 个文件, 开始下载到 ./{DOWNLOAD_DIR}/")
        for p in matches:
            download_file(client, p)

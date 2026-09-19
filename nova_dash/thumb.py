"""视频封面探测 (判断设备是否支持原生视频缩略图).

背景: iOS 封面目前靠下载视频头部 + FFmpeg 抽帧, 流量与耗时都大. 联咏固件
可能的原生封面方案 (novatek-protocol.md 第三节):
1. CGI `cmd=4001&str=<路径>` 缩略图 / `cmd=4002` 预览图 (协议备注可能需回放模式);
2. hfs 下载 URL 追加查询参数 `?4001` / `?4002` 直接取内嵌缩略图;
3. 伴生 .THM 缩略图文件 (已知可用, 作对照基线).

流程: 自动选最新一段录像作样本 → 当前模式逐条试射 → 未命中则切回放模式
再试 4001/4002 → 切回录像模式并恢复循环录像. 命中的图片存到 --out 目录,
结束时汇总"设备是否支持原生封面、推荐方案".
"""

from __future__ import annotations

import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

from . import album
from .probe import ensure_recording, log, settle

OUT_DIR = Path("thumbs")
READ_CAP = 512 * 1024  # 防止"服务器忽略参数返回整个视频"时下载爆量
VIDEO_EXTS = (".TS", ".MP4", ".MOV")


@dataclass
class Candidate:
    cid: str
    label: str
    url_suffix: str | None = None   # HTTP 方案: 拼在文件下载 URL 后
    cmd: int | None = None          # CGI 方案
    needs_playback: bool = False    # 放到回放模式那一轮再试
    note: str = ""


CANDIDATES: list[Candidate] = [
    Candidate("http-4001", "下载 URL 追加 ?4001",
              note="2026-09-19 实测: 服务器忽略, 回吐视频本体"),
    Candidate("http-4002", "下载 URL 追加 ?4002",
              note="2026-09-19 实测: 同上"),
    Candidate("http-cmd4001", "下载 URL 追加 ?custom=1&cmd=4001",
              note="✅ 2026-09-19 实测命中: 直接返回 ~28KB JPEG"),
    Candidate("cgi-4001", "CGI cmd=4001&str=<路径> (缩略图)",
              note="2026-09-19 实测: -21"),
    Candidate("cgi-4002", "CGI cmd=4002&str=<路径> (预览图)",
              note="2026-09-19 实测: -21"),
    Candidate("cgi-4001-pb", "回放模式下 CGI cmd=4001"),
    Candidate("cgi-4002-pb", "回放模式下 CGI cmd=4002"),
]


def sniff_image(data: bytes) -> tuple[str, int] | None:
    """识别图片签名; JPEG 允许嵌在响应头部之后 (返回 (类型, 起始偏移))."""
    if data[:3] == b"\xff\xd8\xff":
        return "JPEG", 0
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "PNG", 0
    if data[:2] == b"BM":
        return "BMP", 0
    idx = data.find(b"\xff\xd8\xff", 0, 4096)
    if idx >= 0:
        return "JPEG(内嵌)", idx
    return None


def looks_like_ts(data: bytes) -> bool:
    """MPEG-TS 特征: 0x47 同步字节按 188 字节周期重复."""
    return len(data) >= 188 * 3 and all(data[i] == 0x47 for i in range(0, 188 * 3, 188))


def fetch_http(client, url: str) -> tuple[bytes | None, str, str]:
    """下载 URL (持串行锁, 最多读 READ_CAP), 返回 (数据, Content-Type, Content-Length)."""
    try:
        with client.cmd_lock:
            resp = client.session.get(url, stream=True, timeout=(3, 10))
            ctype = resp.headers.get("Content-Type", "?")
            total = resp.headers.get("Content-Length", "?")
            chunks: list[bytes] = []
            got = 0
            for chunk in resp.iter_content(chunk_size=64 * 1024):
                chunks.append(chunk)
                got += len(chunk)
                if got >= READ_CAP:
                    break
        return b"".join(chunks), ctype, total
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ 请求失败: {type(e).__name__}: {e}")
        return None, "?", "?"


def fetch_cgi(client, cmd: int, path: str) -> tuple[bytes | None, str]:
    """发 CGI 命令取二进制; XML 响应视为设备回执 (拒绝/不支持), 返回 (None, 说明)."""
    try:
        with client.cmd_lock:
            resp = client.session.get(
                client.base_url + "/",
                params={"custom": 1, "cmd": cmd, "str": path},
                timeout=(3, 15),
            )
            data = resp.content
    except Exception as e:  # noqa: BLE001
        print(f"  ❌ 请求失败: {type(e).__name__}: {e}")
        return None, "请求异常"
    try:
        root = ET.fromstring(data.decode("ascii"))
    except (UnicodeDecodeError, ET.ParseError):
        return data, f"Content-Type={resp.headers.get('Content-Type', '?')}"
    status = root.findtext("Status")
    return None, f"XML 回执 Status={status} (设备没吐图片)"


def save_image(out_dir: Path, stem: str, cid: str, data: bytes, kind: str, offset: int) -> Path:
    out_dir.mkdir(exist_ok=True)
    payload = data[offset:]
    ext = "png" if kind == "PNG" else "bmp" if kind == "BMP" else "jpg"
    path = out_dir / f"{stem}.{cid}.{ext}"
    path.write_bytes(payload)
    return path


def try_candidate(client, cand: Candidate, target: str, out_dir: Path, stem: str) -> tuple[str, Path] | None:
    """试射一个方案; 命中返回 (说明, 保存路径)."""
    if cand.url_suffix is not None:
        url = album.download_url(client.base_url, target) + cand.url_suffix
        print(f"\n🎯 [{cand.cid}] {cand.label}")
        print(f"    GET {url}")
        if cand.note:
            print(f"    ({cand.note})")
        data, ctype, total = fetch_http(client, url)
        if not data:
            return None
        if looks_like_ts(data):
            print(f"  ❌ 未命中: 返回的是视频流本体 (Content-Length={total}, "
                  f"已按 {READ_CAP // 1024}KB 截断) —— 服务器忽略了这个参数")
            return None
    else:
        print(f"\n🎯 [{cand.cid}] {cand.label}")
        if cand.note:
            print(f"    ({cand.note})")
        data, note = fetch_cgi(client, cand.cmd, target)
        if data is None:
            print(f"  ❌ 未命中: {note}")
            return None

    kind_offset = sniff_image(data)
    if kind_offset is None:
        head = data[:16].hex()
        print(f"  ❌ 未命中: {len(data)} 字节且非图片签名 (头部: {head})")
        return None
    kind, offset = kind_offset
    path = save_image(out_dir, stem, cand.cid, data, kind, offset)
    print(f"  ✅ 命中: {kind}, {len(data) - offset} 字节 → 已存 {path} (请打开确认画面内容)")
    return cand.label, path


def pick_video(client, override: str | None) -> tuple[str | None, list[str]]:
    """选最新一段录像作样本; 返回 (目标路径, 全部文件列表)."""
    paths = album.fetch_file_list(client)
    if override:
        return override, paths
    videos = sorted(
        (p for p in paths if p.upper().endswith(VIDEO_EXTS) and "MOVIE" in p.upper()),
        reverse=True,
    ) or sorted((p for p in paths if p.upper().endswith(VIDEO_EXTS)), reverse=True)
    if not videos:
        return None, paths
    print(f"  样本: {videos[0]} (最新一段)")
    return videos[0], paths


def try_thm(client, target: str, paths: list[str], out_dir: Path, stem: str) -> tuple[str, Path] | None:
    """对照基线: 伴生 .THM 缩略图文件."""
    thm = target.rsplit(".", 1)[0] + ".THM"
    if not any(p.upper() == thm.upper() for p in paths):
        print("\n⚠️ 对照: 文件列表里没有伴生 .THM, 跳过 (iOS 可继续用 FFmpeg 抽帧)")
        return None
    print(f"\n🎯 [thm-baseline] 对照基线: 伴生缩略图文件")
    url = album.download_url(client.base_url, thm)
    print(f"    GET {url}")
    data, _, _ = fetch_http(client, url)
    if not data:
        return None
    kind_offset = sniff_image(data)
    if kind_offset is None:
        print(f"  ❌ .THM 不是图片格式 ({len(data)} 字节)")
        return None
    kind, offset = kind_offset
    path = save_image(out_dir, stem, "thm-baseline", data, kind, offset)
    print(f"  ✅ {kind} → 已存 {path}")
    return ".THM 伴生文件", path


def page_thumb(client, args) -> None:
    print("=" * 46)
    print(" 原生视频封面探测 (4001/4002/?4001/.THM)")
    print("=" * 46)
    target, paths = pick_video(client, args.file)
    if target is None:
        print("  ❌ 卡上没有可用的视频文件")
        return
    stem = target.replace("\\", "/").rsplit("/", 1)[-1].rsplit(".", 1)[0]
    out_dir = Path(args.out)

    hits: list[tuple[str, Path]] = []
    first_round = [c for c in CANDIDATES if not c.needs_playback]
    for cand in first_round:
        hit = try_candidate(client, cand, target, out_dir, stem)
        if hit:
            hits.append(hit)
        time.sleep(0.8)

    if not hits:
        print("\n→ 当前模式未命中, 切回放模式再试 (协议备注: 4001/4002 需回放模式)")
        client.send_cmd(3001, par=2, description="切换回放模式 (par=2)", timeout=12)
        settle(2.5, "等模式稳定")
        for cand in (c for c in CANDIDATES if c.needs_playback):
            hit = try_candidate(client, cand, target, out_dir, stem)
            if hit:
                hits.append(hit)
            time.sleep(0.8)
        client.send_cmd(3001, par=1, description="切回录像模式 (par=1)", timeout=12)
        settle(2.5, "等模式稳定")

    baseline = try_thm(client, target, paths, out_dir, stem)

    ensure_recording(client, delay=2, verify_timeout=20)

    print("\n" + "=" * 46)
    print(" 封面探测结论")
    print("=" * 46)
    if hits:
        print(f"  ✅ 设备支持原生视频封面! 命中 {len(hits)} 个方案:")
        for label, path in hits:
            print(f"      · {label} → {path}")
        print("  请打开上述图片确认画面正确后, 即可把对应方案接进 iOS 封面流程")
        print("  (替代/兜底现有 FFmpeg 抽帧, 省流量且更快)")
    else:
        print("  ❌ 4001/4002 的 CGI 与 HTTP 变体均未取得封面")
        if baseline:
            print(f"  ✅ 但 .THM 伴生文件可用 (对照: {baseline[1]}), iOS 可改用它替代 FFmpeg 抽帧")
        else:
            print("  设备不支持原生封面, iOS 维持现有 FFmpeg 抽帧方案")
    print(f"  (全部产物在 {out_dir}/ 目录)")

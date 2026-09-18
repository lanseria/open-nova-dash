# OpenNovaDash

开源的联咏（Novatek）方案行车记录仪 Wi-Fi 伴侣：通过记录仪自带的 Wi-Fi 热点（网关 `192.168.1.254`）发送 CGI 指令，实现**实时画面、相册管理、拍照录像控制**，无需厂商 App。

包含两个组件：

| 组件 | 路径 | 说明 |
| --- | --- | --- |
| Python 控制脚本 | `script.py` | 终端里直接诊断设备、列文件、拍照、控制录像、格式化 SD 卡 |
| iOS 客户端 (NovaDash) | `ios/` | SwiftUI 编写的完整 App：状态仪表盘 + 相册 + 控制台 + RTSP 直播 |

理论上适用于所有联咏方案的行车记录仪/运动相机（SJCAM、GoXtreme、Viofo 等），不同厂商固件对协议的支持有差异。已在一台 **860N72（固件 SF20200714）** 上完整实测。

## 功能特性

**iOS 客户端 (NovaDash)**

- **连接管理**：手动点击连接才开始探测，3 秒心跳保活（`cmd=3016`），断开自动回到待连接页
- **状态仪表盘**：固件版本、电池、SD 卡状态、剩余空间、心跳时间
- **相册**：按天分组的封面卡片，FFmpeg 流式抽帧生成封面（含磁盘缓存），点击即在线播放 TS 视频（KSPlayer/FFmpeg 拉流，无需先下载），支持下载导出到系统相册
- **控制台**：拍照（含录像中安全抓拍连招）、录像开关、RTSP 实时直播（`novatek/main` 主码流 / `novatek/sub` 子码流）

**Python 脚本**（子命令与 iOS 页面一一对应）

- `connect` 连接探测 + 心跳保活演示
- `status` 状态仪表盘（固件版本/电池/SD 卡/剩余空间）
- `album` 文件列表，`--download 关键字` 按文件名子串下载到 `./downloads/`
- `control` 拍照（安全连招）/ 录像开关 / RTSP 节点 / SD 卡格式化（二次确认）
- `probe` 慢速控制探针：逐一验证 停录→开录→拍照，命令前静置、全程时间戳、用 2016/1003 复核真实效果（排查 iOS 端"点了没反应"）
- `try` 指令扫描台：逐条试射候选命令码（交互单发 / `--all` 自动连发 / `--cmd` 任意单发 / `--capture` 拍照组合实验），以设备提示音与屏幕反应为判据，找出固件真正认的命令（2026-09-18 实测定稿：`2001` 只认 `par=` 写法）
- 内置串行锁 + 心跳退避，规避记录仪 HTTP 服务的并发红线

## 快速开始

### 前置条件

手机（或电脑）先连接记录仪的 Wi-Fi 热点，记录仪网关地址为 `192.168.1.254`。

### Python 脚本

全部通过 [uv](https://docs.astral.sh/uv/) 执行（**无需本机预装 Python**，uv 会按项目 `.python-version` 自动下载并管理 Python 3.13，自动创建 .venv 并安装依赖）：

```bash
uv sync                    # 安装依赖
uv run script.py --help    # 查看子命令（与 iOS 页面一一对应）
uv run script.py status    # 例：状态仪表盘
```

新增依赖：`uv add <package>`，移除依赖：`uv remove <package>`。

### iOS 客户端

1. 准备本地 SPM 依赖：将 [KSPlayer](https://github.com/kingslay/KSPlayer) 与 [FFmpegKit](https://github.com/kingslay/FFmpegKit) 克隆到**与本仓库同级的目录**（`Package.swift` 会自动按相对路径 `../../KSPlayer`、`../../FFmpegKit` 查找）：

   ```bash
   cd /path/to/parent
   git clone https://github.com/kingslay/KSPlayer.git
   git clone https://github.com/kingslay/FFmpegKit.git
   ```

   > FFmpegKit 仓库约 670MB（二进制直接在仓库内），克隆较慢请耐心等待。

2. 用 Xcode 打开 `ios/NovaDash.xcodeproj`，在 Signing & Capabilities 中选择自己的开发团队，修改 Bundle Identifier 为唯一值。

3. 连接 iPhone 真机运行（首次需在 设置 → 通用 → VPN 与设备管理 中信任开发者证书）。

4. 手机连接记录仪 Wi-Fi 后打开 NovaDash，点击"连接记录仪"即可。

> 真机运行时 iOS 会弹"本地网络"权限弹窗，必须允许，否则无法访问 `192.168.1.254`。

## 协议要点（踩坑红线）

记录仪内置的 HTTP 服务器有诸多硬性约束，完整协议见 [novatek-protocol.md](novatek-protocol.md)，iOS 端实测记录见 [iOS.md](iOS.md)。最关键的几条：

- **HTTP 服务是单线程的，所有请求必须串行**（包括心跳），并发会导致连接被重置
- **心跳 `cmd=3016` 必须每 3~5 秒一次**，否则设备主动断开 Wi-Fi
- **读超时 ≠ 命令失败**：重命令后设备会阻塞几秒到几十秒，严禁超时后重发状态命令（会造成请求堆积/重复执行），应轮询心跳等设备恢复
- **录像中查文件列表会被拒**（返回 `-3`），需先 `3001&par=2` 切回放模式，查完 `3001&par=1` 切回录像模式并 `2001&par=1` 恢复录像
- **下载 URL 规则**：`3015` 返回的 `A:\CARDV\MOVIE\x.TS` 去掉盘符前缀 → `http://192.168.1.254/CARDV/MOVIE/x.TS`
- **RTSP 直播节点**：`rtsp://192.168.1.254/novatek/main`（主码流）、`rtsp://192.168.1.254/novatek/sub`（子码流低延迟）

## 目录结构

```
open-nova-dash/
├── script.py              # CLI 入口：子命令与 iOS 页面一一对应
├── nova_dash/             # Python 实现，按 iOS 功能页面拆分
│   ├── core.py                # CGI 驱动（串行锁/收发/失联恢复等待）
│   ├── connection.py          # 连接探测 + 心跳保活
│   ├── dashboard.py           # 状态仪表盘
│   ├── album.py               # 文件列表 + 下载
│   ├── control.py             # 拍照/录像/直播节点/格式化
│   ├── probe.py               # 慢速控制探针（排查 iOS 控制无效果）
│   └── sweep.py               # 指令扫描台（逐条试射命令码）
├── pyproject.toml         # Python 项目配置
├── novatek-protocol.md    # 联咏 Wi-Fi CGI 协议（当前硬件实测版）
├── iOS.md                 # iOS 端实现设计与协议实测记录
└── ios/
    ├── NovaDash.xcodeproj
    └── NovaDash/
        ├── NovaDashApp.swift      # 入口 + 连接状态机 + 待连接页
        ├── Core/
        │   ├── NovatekClient.swift    # CGI 驱动（actor + 优先级串行信号量）
        │   ├── ConnectionModel.swift  # 连接/心跳状态机
        │   ├── Models.swift           # 文件模型与按天分组
        │   ├── ThumbnailStore.swift   # 封面两级缓存（内存 + 磁盘）
        │   ├── FFmpegThumb.swift      # FFmpeg C API 抽帧
        │   └── AsyncSemaphore.swift   # 优先级信号量
        └── Views/
            ├── DashboardView.swift    # 状态仪表盘
            ├── AlbumView.swift        # 相册 + 照片查看器 + 视频播放
            └── ControlView.swift      # 控制台 + RTSP 直播
```

## 致谢

协议整理参考了开源社区的逆向成果（GoXtreme-Wi-Fi-API 等，详见 [novatek-protocol.md](novatek-protocol.md) 第三节），播放能力基于 [KSPlayer](https://github.com/kingslay/KSPlayer) / [FFmpegKit](https://github.com/kingslay/FFmpegKit)。

仅供学习研究使用，使用本项目中"格式化 SD 卡""恢复出厂设置"等危险命令造成的后果请自行承担。

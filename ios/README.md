# NovaDash iOS

联咏（Novatek 860N72-SF20200714）行车记录仪的控制 APP。协议能力与坑位说明见仓库根目录 `readme.md` 与 `iOS.md`（全部来自 `script.py` 五轮实测）。

## 功能（v0.1）

- **状态**：固件版本 / 电池 / SD 卡 / 剩余空间（3012/3019/3024/3017），心跳保活（3016，3 秒一次，失败退避）
- **相册**：SD 卡文件列表（3015，-3 时自动走回放模式流程），按照片/视频筛选；下载（hfs 服务器，实测 URL 规则：去掉 `A:` 盘符前缀）、照片存系统相册、TS 视频分享导出
- **控制**：远程拍照（1001，-22 时自动切换模式拍照）、录像开始/停止（2001&str，-22 语义化为"已处于目标状态"）

## 运行

```bash
# 模拟器（共享 Mac 网络: Mac 连着记录仪 Wi-Fi 时可直接联调）
open NovaDash.xcodeproj   # Xcode 里选任一 iPhone 模拟器, Cmd+R

# 真机（需在 Xcode Signing & Capabilities 里选自己的开发者账号/Team）
```

命令行验证编译：

```bash
cd ios
xcodebuild -project NovaDash.xcodeproj -target NovaDash -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 首次运行注意

1. iOS 会在首次访问 `192.168.1.254` 时弹**本地网络权限**，必须允许；
2. 记录仪 Wi-Fi 无外网，iOS 可能提示"无法接入网络"——选择**保持连接**（客户端已禁用蜂窝回退）；
3. 保存照片需**相册写入权限**；
4. 当前卡快满（0.2GB）时拍照/录像会失败（-5/-22），请先在设备上格式化。

## 架构红线（驱动层已实现，改动前先读 readme"坑位说明"）

- 固件 HTTP 服务器**单线程**：所有请求（含心跳）经 `AsyncSemaphore` 串行，心跳忙时让路；
- **读超时不重发**状态命令（可能重复执行）；
- 重命令（录像/切模式）长超时（12~15s），"超时 ≠ 命令失败"；
- 下载 URL = 原始路径去掉 `A:` 前缀；hfs 服务器不复用连接。

## 已知待办

- RTSP 实时预览（流地址待 `ffplay` 验证，选型 MobileVLCKit/KSPlayer）
- TS 视频 FFmpegKit 重封装 MP4 后存系统相册
- 缩略图（4001）、删除（4003）、格式化入口（3010&str=1）

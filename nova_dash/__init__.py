"""OpenNovaDash Python 端: 按 iOS 客户端功能页面拆分的记录仪控制实现.

模块与 iOS 的对应关系:
- core.py       <-> Core/NovatekClient.swift   (CGI 驱动: 串行锁/收发/恢复等待)
- connection.py <-> 连接页 ConnectionModel.swift (探测 + 心跳保活)
- dashboard.py  <-> 状态页 DashboardView.swift   (固件/SD 卡/空间/电池)
- album.py      <-> 相册页 AlbumView.swift       (文件列表/下载)
- control.py    <-> 控制页 ControlView.swift     (拍照/录像/直播节点/格式化)
- probe.py      <-> 控制页诊断探针               (慢速节奏验证拍照/录像命令, 排查 iOS 无效果)
- sweep.py      <-> 控制页指令扫描台             (逐条试射候选命令码, 以设备提示音/屏幕为判据)
- thumb.py      <-> 相册页封面探测               (判断设备是否支持原生视频缩略图 4001/4002/.THM)
"""

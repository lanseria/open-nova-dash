import Foundation

enum NovatekError: LocalizedError {
    /// 设备返回负数 Status (即 Linux errno, 错误码含义来自 script.py 五轮实测)
    case deviceStatus(Int)
    /// 请求层失败 (超时/连接断开等)
    case transport(String)
    /// 响应不是预期的 CGI XML 结构
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .deviceStatus(let code):
            switch code {
            case -1: return "设备不支持该命令"
            case -3: return "当前状态不允许 (如录像中查询文件列表)"
            case -5: return "存储写入失败: 卡满或卡故障, 请备份后在设备上格式化"
            case -13: return "抓拍执行失败"
            case -21: return "该命令的查询变体不受支持"
            case -22: return "状态不允许: 与当前设备状态冲突"
            default: return "设备返回错误码 \(code)"
            }
        case .transport(let message):
            return "通信失败: \(message)"
        case .badResponse(let message):
            return "响应异常: \(message)"
        }
    }

    /// 面向用户的错误文案 (含网络层错误翻译)
    static func describe(_ error: Error) -> String {
        if let e = error as? NovatekError {
            return e.errorDescription ?? "未知错误"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "设备无响应 (可能正忙, 稍候再试; 超时不代表命令失败)"
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return "无法连接记录仪: 请确认已连接记录仪 Wi-Fi, 并在系统弹窗中允许本地网络访问"
            default:
                break
            }
            return urlError.localizedDescription
        }
        return error.localizedDescription
    }
}

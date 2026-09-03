import Foundation

/// 解析联咏的两类 XML 响应:
/// 1) CGI 标准响应 <Function><Cmd/><Status/><Value/><String/></Function>
/// 2) 3015 文件树 (本机固件无 Status 包裹), 含若干 <FPATH>A:\CARDV\...</FPATH>
final class NovatekXMLParser: NSObject, XMLParserDelegate {
    private var textBuffer = ""
    private var cmd: Int?
    private var status: Int?
    private var value: String?
    private var string: String?
    private(set) var filePaths: [String] = []

    private override init() {
        super.init()
    }

    var reply: RawReply {
        RawReply(
            response: CGIResponse(cmd: cmd, status: status, value: value, string: string),
            filePaths: filePaths
        )
    }

    static func parse(_ data: Data) -> RawReply {
        let delegate = NovatekXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.reply
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        textBuffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        textBuffer = ""
        switch elementName.uppercased() {
        case "CMD": cmd = Int(text)
        case "STATUS": status = Int(text)
        case "VALUE": value = text.isEmpty ? nil : text
        case "STRING": string = text.isEmpty ? nil : text
        case "FPATH" where !text.isEmpty: filePaths.append(text)
        default: break
        }
    }
}

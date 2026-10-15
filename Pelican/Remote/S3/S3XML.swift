import Foundation

/// A small XML tree, enough for S3's and WebDAV's responses.
final class S3XML {
    let name: String
    var text = ""
    var children: [S3XML] = []

    init(name: String) { self.name = name }

    /// First child with this name, e.g. `xml["Code"]?.text`.
    subscript(_ child: String) -> S3XML? { children.first { $0.name == child } }
    func all(_ child: String) -> [S3XML] { children.filter { $0.name == child } }
    func value(_ child: String) -> String? { self[child]?.text }

    /// With `localNames`, "D:href" and "d:href" both become "href" (WebDAV servers pick their own prefixes).
    static func parse(_ data: Data, localNames: Bool = false) -> S3XML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = localNames
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: S3XML?
        private var stack: [S3XML] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = S3XML(name: name)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}

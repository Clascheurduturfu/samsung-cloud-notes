import Foundation

// Foundation's XMLDocument tree exists only on macOS. This order-preserving DOM
// implements the small subset the shared cloud code uses, so iOS parses and
// re-serializes Samsung documents without dropping comments, processing
// instructions, attribute order or whitespace. DTDs and entity declarations are
// rejected outright: Samsung's documents never contain them.
#if !os(macOS)
typealias XMLNode = PortableXMLNode
typealias XMLElement = PortableXMLElement
typealias XMLDocument = PortableXMLDocument
#else
// On iOS these helpers come from Cloud.swift's XMLElement extension; on macOS
// they are only needed by the self-test that cross-checks this implementation.
extension PortableXMLElement {
    func first(_ name: String) -> PortableXMLElement? { elements(forName: name).first }
    func value(_ name: String) -> String { first(name)?.stringValue ?? "" }
    func attr(_ name: String) -> String { attribute(forName: name)?.stringValue ?? "" }
}
#endif

class PortableXMLNode {
    enum Kind { case document, element, attribute, text, cdata, comment, instruction }
    let kind: Kind
    var name: String?
    fileprivate var content = ""
    fileprivate(set) weak var parent: PortableXMLNode?
    fileprivate(set) var children: [PortableXMLNode] = []
    fileprivate init(kind: Kind, name: String? = nil, content: String = "") { self.kind = kind; self.name = name; self.content = content }

    static func attribute(withName name: String, stringValue: String) -> Any {
        PortableXMLNode(kind: .attribute, name: name, content: stringValue)
    }
    var stringValue: String? {
        get {
            switch kind {
            case .element, .document: return children.map { $0.kind == .comment || $0.kind == .instruction ? "" : $0.stringValue ?? "" }.joined()
            default: return content
            }
        }
        set {
            switch kind {
            case .element, .document:
                children.forEach { $0.parent = nil }
                children = []
                if let newValue, !newValue.isEmpty { insert(PortableXMLNode(kind: .text, content: newValue)) }
                (self as? PortableXMLElement)?.selfClosing = false
            default: content = newValue ?? ""
            }
        }
    }
    func detach() {
        guard let parent else { return }
        if kind == .attribute, let element = parent as? PortableXMLElement { element.attributeNodes.removeAll { $0 === self } }
        else { parent.children.removeAll { $0 === self } }
        self.parent = nil
    }
    fileprivate func insert(_ node: PortableXMLNode) {
        node.detach(); node.parent = self; children.append(node)
    }
    func xmlString(options: PortableXMLDocument.Options = []) -> String {
        var output = ""; write(to: &output); return output
    }
    fileprivate func write(to output: inout String) {
        switch kind {
        case .document, .element: for child in children { child.write(to: &output) }
        case .attribute: output += "\(name ?? "")=\"\(Self.escape(content, attribute: true))\""
        case .text: output += Self.escape(content, attribute: false)
        case .cdata: output += "<![CDATA[\(content)]]>"
        case .comment: output += "<!--\(content)-->"
        case .instruction: output += "<?\(name ?? "")\(content.isEmpty ? "" : " " + content)?>"
        }
    }
    static func escape(_ value: String, attribute: Bool) -> String {
        var result = ""; result.reserveCapacity(value.utf8.count)
        for character in value.unicodeScalars {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where attribute: result += "&quot;"
            case "\n" where attribute: result += "&#10;"
            case "\r": result += "&#13;"
            case "\t" where attribute: result += "&#9;"
            default: result.unicodeScalars.append(character)
            }
        }
        return result
    }
}

final class PortableXMLElement: PortableXMLNode {
    fileprivate(set) var attributeNodes: [PortableXMLNode] = []
    fileprivate var selfClosing = false
    init(name: String, stringValue: String? = nil) {
        super.init(kind: .element, name: name)
        if let stringValue { self.stringValue = stringValue }
    }
    func elements(forName name: String) -> [PortableXMLElement] {
        children.compactMap { $0 as? PortableXMLElement }.filter { $0.name == name }
    }
    func attribute(forName name: String) -> PortableXMLNode? { attributeNodes.first { $0.name == name } }
    func addAttribute(_ value: Any) {
        guard let node = value as? PortableXMLNode, node.kind == .attribute, let name = node.name else { return }
        attribute(forName: name)?.detach()
        node.detach(); node.parent = self; attributeNodes.append(node)
    }
    func addChild(_ node: PortableXMLNode) { insert(node); selfClosing = false }
    func nodes(forXPath path: String) throws -> [PortableXMLNode] { try PortableXPath.evaluate(path, context: self) }
    fileprivate override func write(to output: inout String) {
        output += "<" + (name ?? "")
        for attribute in attributeNodes { output += " "; attribute.write(to: &output) }
        if children.isEmpty && selfClosing { output += "/>"; return }
        output += ">"
        super.write(to: &output)
        output += "</\(name ?? "")>"
    }
}

final class PortableXMLDocument: PortableXMLNode {
    struct Options: OptionSet {
        let rawValue: Int
        static let nodePreserveAll = Options(rawValue: 1)
        static let nodeLoadExternalEntitiesNever = Options(rawValue: 2)
    }
    init(data: Data, options: Options = []) throws {
        super.init(kind: .document)
        var parser = PortableXMLParser(bytes: Array(data))
        try parser.parse(into: self)
        guard rootElement() != nil else { throw NotesError.message("The XML document has no root element.") }
    }
    func rootElement() -> PortableXMLElement? { children.lazy.compactMap { $0 as? PortableXMLElement }.first }
    var xmlString: String { xmlString(options: []) }
    func nodes(forXPath path: String) throws -> [PortableXMLNode] { try PortableXPath.evaluate(path, context: self) }
}

/// Supports the location paths used by this project: `/a/b`, `.//a/b`, `a/b`,
/// each step optionally filtered by one `[@name='value']` predicate.
private enum PortableXPath {
    static func evaluate(_ path: String, context: PortableXMLNode) throws -> [PortableXMLNode] {
        var steps: Substring
        var current: [PortableXMLNode]
        var descend = false
        if path.hasPrefix(".//") { steps = path.dropFirst(3); current = [context]; descend = true }
        else if path.hasPrefix("/") {
            var root: PortableXMLNode = context
            while let parent = root.parent { root = parent }
            steps = path.dropFirst(); current = [root]
        } else { steps = Substring(path); current = [context] }
        for raw in steps.split(separator: "/", omittingEmptySubsequences: false) {
            guard !raw.isEmpty else { throw NotesError.message("Unsupported XPath: \(path)") }
            var name = raw, predicate: (String, String)?
            if let open = raw.firstIndex(of: "[") {
                guard raw.hasSuffix("]") else { throw NotesError.message("Unsupported XPath: \(path)") }
                name = raw[..<open]
                let body = raw[raw.index(after: open)..<raw.index(before: raw.endIndex)]
                let parts = body.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].hasPrefix("@"), let quote = parts[1].first, quote == "'" || quote == "\"",
                      parts[1].count >= 2, parts[1].last == quote else { throw NotesError.message("Unsupported XPath: \(path)") }
                predicate = (String(parts[0].dropFirst()), String(parts[1].dropFirst().dropLast()))
            }
            func matches(_ node: PortableXMLNode) -> Bool {
                guard let element = node as? PortableXMLElement, name == "*" || element.name == String(name) else { return false }
                guard let predicate else { return true }
                return element.attribute(forName: predicate.0)?.stringValue == predicate.1
            }
            var next: [PortableXMLNode] = []
            for node in current {
                if descend {
                    var stack = Array(node.children.reversed())
                    while let candidate = stack.popLast() {
                        if matches(candidate) { next.append(candidate) }
                        stack.append(contentsOf: candidate.children.reversed())
                    }
                } else { next += node.children.filter(matches) }
            }
            current = next; descend = false
        }
        return current
    }
}

private struct PortableXMLParser {
    let bytes: [UInt8]
    var position = 0
    init(bytes: [UInt8]) {
        // Skip a UTF-8 byte-order mark.
        self.bytes = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Array(bytes.dropFirst(3)) : bytes
    }
    func failure(_ reason: String) -> Error { NotesError.message("Invalid XML at byte \(position): \(reason).") }
    func starts(with literal: String) -> Bool {
        let pattern = Array(literal.utf8)
        return position + pattern.count <= bytes.count && bytes[position..<position + pattern.count].elementsEqual(pattern)
    }
    mutating func until(_ literal: String) throws -> String {
        let pattern = Array(literal.utf8)
        var index = position
        while index + pattern.count <= bytes.count {
            if bytes[index] == pattern[0] && bytes[index..<index + pattern.count].elementsEqual(pattern) {
                let value = String(decoding: bytes[position..<index], as: UTF8.self)
                position = index + pattern.count
                return value
            }
            index += 1
        }
        throw failure("missing \(literal)")
    }
    static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d }
    static func isNameByte(_ byte: UInt8) -> Bool {
        !isSpace(byte) && byte != UInt8(ascii: "/") && byte != UInt8(ascii: ">") && byte != UInt8(ascii: "=") && byte != UInt8(ascii: "<")
            && byte != UInt8(ascii: "\"") && byte != UInt8(ascii: "'") && byte != UInt8(ascii: "?")
    }
    mutating func skipSpace() { while position < bytes.count, Self.isSpace(bytes[position]) { position += 1 } }
    mutating func name() throws -> String {
        let start = position
        while position < bytes.count, Self.isNameByte(bytes[position]) { position += 1 }
        guard position > start else { throw failure("expected a name") }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }
    func decodeEntities(_ raw: String) throws -> String {
        guard raw.contains("&") else { return raw }
        var output = ""; var rest = Substring(raw)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";") else { throw failure("unterminated entity") }
            let entity = rest[rest.index(after: amp)..<semicolon]
            switch entity {
            case "lt": output += "<"
            case "gt": output += ">"
            case "amp": output += "&"
            case "quot": output += "\""
            case "apos": output += "'"
            default:
                let value: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") { value = UInt32(entity.dropFirst(2), radix: 16) }
                else if entity.hasPrefix("#") { value = UInt32(entity.dropFirst(), radix: 10) }
                else { value = nil }
                guard let value, let scalar = Unicode.Scalar(value) else { throw failure("unsupported entity &\(entity);") }
                output.unicodeScalars.append(scalar)
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        return output + rest
    }
    mutating func parse(into document: PortableXMLDocument) throws {
        var stack: [PortableXMLNode] = [document]
        while position < bytes.count {
            let parent = stack[stack.count - 1]
            if bytes[position] != UInt8(ascii: "<") {
                let start = position
                while position < bytes.count, bytes[position] != UInt8(ascii: "<") { position += 1 }
                let raw = String(decoding: bytes[start..<position], as: UTF8.self)
                if parent.kind == .document {
                    guard raw.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else { throw failure("text outside the root element") }
                    continue
                }
                parent.insert(PortableXMLNode(kind: .text, content: try decodeEntities(raw)))
            } else if starts(with: "<!--") {
                position += 4; parent.insert(PortableXMLNode(kind: .comment, content: try until("-->")))
            } else if starts(with: "<![CDATA[") {
                guard parent.kind == .element else { throw failure("CDATA outside the root element") }
                position += 9; parent.insert(PortableXMLNode(kind: .cdata, content: try until("]]>")))
            } else if starts(with: "<!") {
                throw failure("document type declarations are not accepted")
            } else if starts(with: "<?") {
                position += 2
                let target = try name()
                let body = try until("?>")
                // Includes the XML declaration, which is retained verbatim.
                parent.insert(PortableXMLNode(kind: .instruction, name: target, content: body.trimmingCharacters(in: .whitespaces)))
            } else if starts(with: "</") {
                position += 2
                let closing = try name(); skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ">") else { throw failure("malformed closing tag") }
                position += 1
                guard stack.count > 1, let open = parent as? PortableXMLElement, open.name == closing else { throw failure("mismatched </\(closing)>") }
                stack.removeLast()
            } else {
                position += 1
                if parent.kind == .document, document.rootElement() != nil { throw failure("multiple root elements") }
                let element = PortableXMLElement(name: try name())
                while true {
                    skipSpace()
                    guard position < bytes.count else { throw failure("unterminated tag") }
                    if bytes[position] == UInt8(ascii: ">") { position += 1; parent.insert(element); stack.append(element); break }
                    if starts(with: "/>") { position += 2; element.selfClosing = true; parent.insert(element); break }
                    let attribute = try name(); skipSpace()
                    guard position < bytes.count, bytes[position] == UInt8(ascii: "=") else { throw failure("attribute without value") }
                    position += 1; skipSpace()
                    guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") || bytes[position] == UInt8(ascii: "'") else { throw failure("unquoted attribute") }
                    let quote = String(UnicodeScalar(bytes[position])); position += 1
                    let value = try decodeEntities(try until(quote))
                    guard element.attribute(forName: attribute) == nil else { throw failure("duplicate attribute \(attribute)") }
                    element.addAttribute(PortableXMLNode.attribute(withName: attribute, stringValue: value))
                }
            }
        }
        guard stack.count == 1 else { throw failure("unclosed element") }
    }
}

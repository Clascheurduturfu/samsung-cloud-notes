package local.samsungcloudnotes

// An order-preserving DOM matching Sources/Shared/PortableXML.swift. Samsung
// documents are re-uploaded after editing, so comments, processing instructions,
// attribute order and whitespace are retained. DTDs are rejected outright.

open class XmlNode internal constructor(val kind: Kind, var name: String? = null, internal var content: String = "") {
    enum class Kind { DOCUMENT, ELEMENT, ATTRIBUTE, TEXT, CDATA, COMMENT, INSTRUCTION }
    var parent: XmlNode? = null
        internal set
    internal val children = mutableListOf<XmlNode>()

    open var stringValue: String
        get() = when (kind) {
            Kind.ELEMENT, Kind.DOCUMENT -> children.joinToString("") { if (it.kind == Kind.COMMENT || it.kind == Kind.INSTRUCTION) "" else it.stringValue }
            else -> content
        }
        set(value) {
            when (kind) {
                Kind.ELEMENT, Kind.DOCUMENT -> {
                    children.forEach { it.parent = null }
                    children.clear()
                    if (value.isNotEmpty()) insert(XmlNode(Kind.TEXT, content = value))
                    (this as? XmlElement)?.selfClosing = false
                }
                else -> content = value
            }
        }

    fun detach() {
        val owner = parent ?: return
        if (kind == Kind.ATTRIBUTE && owner is XmlElement) owner.attributeNodes.removeAll { it === this }
        else owner.children.removeAll { it === this }
        parent = null
    }

    internal fun insert(node: XmlNode) {
        node.detach(); node.parent = this; children.add(node)
    }

    fun xmlString(): String = StringBuilder().also { write(it) }.toString()
    val bytes: ByteArray get() = xmlString().toByteArray(Charsets.UTF_8)

    internal open fun write(output: StringBuilder) {
        when (kind) {
            Kind.DOCUMENT, Kind.ELEMENT -> children.forEach { it.write(output) }
            Kind.ATTRIBUTE -> output.append(name).append("=\"").append(escape(content, attribute = true)).append('"')
            Kind.TEXT -> output.append(escape(content, attribute = false))
            Kind.CDATA -> output.append("<![CDATA[").append(content).append("]]>")
            Kind.COMMENT -> output.append("<!--").append(content).append("-->")
            Kind.INSTRUCTION -> output.append("<?").append(name).append(if (content.isEmpty()) "" else " $content").append("?>")
        }
    }

    companion object {
        fun attribute(name: String, value: String) = XmlNode(Kind.ATTRIBUTE, name, value)
        fun escape(value: String, attribute: Boolean): String {
            val result = StringBuilder(value.length)
            for (character in value) {
                when {
                    character == '&' -> result.append("&amp;")
                    character == '<' -> result.append("&lt;")
                    character == '>' -> result.append("&gt;")
                    character == '"' && attribute -> result.append("&quot;")
                    character == '\n' && attribute -> result.append("&#10;")
                    character == '\r' -> result.append("&#13;")
                    character == '\t' && attribute -> result.append("&#9;")
                    else -> result.append(character)
                }
            }
            return result.toString()
        }
    }
}

class XmlElement(name: String, stringValue: String? = null) : XmlNode(Kind.ELEMENT, name) {
    internal val attributeNodes = mutableListOf<XmlNode>()
    internal var selfClosing = false

    init { if (stringValue != null) this.stringValue = stringValue }

    fun elements(name: String): List<XmlElement> = children.filterIsInstance<XmlElement>().filter { it.name == name }
    fun first(name: String): XmlElement? = elements(name).firstOrNull()
    fun value(name: String): String = first(name)?.stringValue ?: ""
    fun attr(name: String): String = attribute(name)?.stringValue ?: ""
    fun attribute(name: String): XmlNode? = attributeNodes.firstOrNull { it.name == name }
    fun set(name: String, value: String) {
        val existing = attribute(name)
        if (existing != null) existing.stringValue = value else addAttribute(XmlNode.attribute(name, value))
    }
    fun addAttribute(node: XmlNode) {
        require(node.kind == Kind.ATTRIBUTE)
        attribute(node.name ?: return)?.detach()
        node.detach(); node.parent = this; attributeNodes.add(node)
    }
    fun addChild(node: XmlNode) { insert(node); selfClosing = false }

    /** All descendant elements with [name], depth first in document order. */
    fun descendants(name: String): List<XmlElement> {
        val found = mutableListOf<XmlElement>()
        val stack = ArrayDeque(children.asReversed())
        while (stack.isNotEmpty()) {
            val node = stack.removeLast()
            if (node is XmlElement && node.name == name) found.add(node)
            stack.addAll(node.children.asReversed())
        }
        return found
    }

    override fun write(output: StringBuilder) {
        output.append('<').append(name)
        for (attribute in attributeNodes) { output.append(' '); attribute.write(output) }
        if (children.isEmpty() && selfClosing) { output.append("/>"); return }
        output.append('>')
        super.write(output)
        output.append("</").append(name).append('>')
    }
}

class XmlDocument(data: ByteArray) : XmlNode(Kind.DOCUMENT) {
    init {
        XmlParser(data).parse(this)
        if (rootElement() == null) throw NotesException("The XML document has no root element.")
    }
    fun rootElement(): XmlElement? = children.firstOrNull { it is XmlElement } as XmlElement?
}

private class XmlParser(data: ByteArray) {
    private val bytes = if (data.size >= 3 && data[0] == 0xef.toByte() && data[1] == 0xbb.toByte() && data[2] == 0xbf.toByte()) data.copyOfRange(3, data.size) else data
    private var position = 0

    private fun failure(reason: String) = NotesException("Invalid XML at byte $position: $reason.")
    private fun startsWith(literal: String): Boolean {
        val pattern = literal.toByteArray()
        if (position + pattern.size > bytes.size) return false
        for (i in pattern.indices) if (bytes[position + i] != pattern[i]) return false
        return true
    }
    private fun text(from: Int, to: Int) = String(bytes, from, to - from, Charsets.UTF_8)
    private fun until(literal: String): String {
        val pattern = literal.toByteArray()
        var index = position
        while (index + pattern.size <= bytes.size) {
            var match = true
            for (i in pattern.indices) if (bytes[index + i] != pattern[i]) { match = false; break }
            if (match) { val value = text(position, index); position = index + pattern.size; return value }
            index++
        }
        throw failure("missing $literal")
    }
    private fun isSpace(byte: Byte) = byte == ' '.code.toByte() || byte == '\t'.code.toByte() || byte == '\n'.code.toByte() || byte == '\r'.code.toByte()
    private fun isNameByte(byte: Byte) = !isSpace(byte) && byte.toInt().toChar() !in "/>=<\"'?"
    private fun skipSpace() { while (position < bytes.size && isSpace(bytes[position])) position++ }
    private fun name(): String {
        val start = position
        while (position < bytes.size && isNameByte(bytes[position])) position++
        if (position == start) throw failure("expected a name")
        return text(start, position)
    }
    private fun decodeEntities(raw: String): String {
        if (!raw.contains('&')) return raw
        val output = StringBuilder()
        var index = 0
        while (true) {
            val amp = raw.indexOf('&', index)
            if (amp < 0) { output.append(raw, index, raw.length); break }
            output.append(raw, index, amp)
            val semicolon = raw.indexOf(';', amp)
            if (semicolon < 0) throw failure("unterminated entity")
            when (val entity = raw.substring(amp + 1, semicolon)) {
                "lt" -> output.append('<')
                "gt" -> output.append('>')
                "amp" -> output.append('&')
                "quot" -> output.append('"')
                "apos" -> output.append('\'')
                else -> {
                    val value = when {
                        entity.startsWith("#x") || entity.startsWith("#X") -> entity.substring(2).toIntOrNull(16)
                        entity.startsWith("#") -> entity.substring(1).toIntOrNull()
                        else -> null
                    }
                    if (value == null || !Character.isValidCodePoint(value)) throw failure("unsupported entity &$entity;")
                    output.appendCodePoint(value)
                }
            }
            index = semicolon + 1
        }
        return output.toString()
    }

    fun parse(document: XmlDocument) {
        val stack = mutableListOf<XmlNode>(document)
        while (position < bytes.size) {
            val parent = stack.last()
            if (bytes[position] != '<'.code.toByte()) {
                val start = position
                while (position < bytes.size && bytes[position] != '<'.code.toByte()) position++
                val raw = text(start, position)
                if (parent.kind == XmlNode.Kind.DOCUMENT) {
                    if (raw.isNotBlank()) throw failure("text outside the root element")
                    continue
                }
                parent.insert(XmlNode(XmlNode.Kind.TEXT, content = decodeEntities(raw)))
            } else if (startsWith("<!--")) {
                position += 4; parent.insert(XmlNode(XmlNode.Kind.COMMENT, content = until("-->")))
            } else if (startsWith("<![CDATA[")) {
                if (parent.kind != XmlNode.Kind.ELEMENT) throw failure("CDATA outside the root element")
                position += 9; parent.insert(XmlNode(XmlNode.Kind.CDATA, content = until("]]>")))
            } else if (startsWith("<!")) {
                throw failure("document type declarations are not accepted")
            } else if (startsWith("<?")) {
                position += 2
                val target = name()
                parent.insert(XmlNode(XmlNode.Kind.INSTRUCTION, target, until("?>").trim(' ', '\t')))
            } else if (startsWith("</")) {
                position += 2
                val closing = name(); skipSpace()
                if (position >= bytes.size || bytes[position] != '>'.code.toByte()) throw failure("malformed closing tag")
                position++
                if (stack.size <= 1 || parent !is XmlElement || parent.name != closing) throw failure("mismatched </$closing>")
                stack.removeAt(stack.size - 1)
            } else {
                position++
                if (parent.kind == XmlNode.Kind.DOCUMENT && document.rootElement() != null) throw failure("multiple root elements")
                val element = XmlElement(name())
                while (true) {
                    skipSpace()
                    if (position >= bytes.size) throw failure("unterminated tag")
                    if (bytes[position] == '>'.code.toByte()) { position++; parent.insert(element); stack.add(element); break }
                    if (startsWith("/>")) { position += 2; element.selfClosing = true; parent.insert(element); break }
                    val attribute = name(); skipSpace()
                    if (position >= bytes.size || bytes[position] != '='.code.toByte()) throw failure("attribute without value")
                    position++; skipSpace()
                    if (position >= bytes.size || (bytes[position] != '"'.code.toByte() && bytes[position] != '\''.code.toByte())) throw failure("unquoted attribute")
                    val quote = bytes[position].toInt().toChar().toString(); position++
                    val value = decodeEntities(until(quote))
                    if (element.attribute(attribute) != null) throw failure("duplicate attribute $attribute")
                    element.addAttribute(XmlNode.attribute(attribute, value))
                }
            }
        }
        if (stack.size != 1) throw failure("unclosed element")
    }
}

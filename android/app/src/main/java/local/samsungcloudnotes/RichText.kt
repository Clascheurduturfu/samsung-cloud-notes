package local.samsungcloudnotes

// Port of Sources/Shared/RichText.swift. Keep the two in step.
//
// Samsung stores typed text as Base64 UTF-8 runs separated by `<?a …?>` markers.
// Inside a marker, `'key'='value'` opens an attribute at the current UTF-16
// offset and a bare `'key'` closes the most recent open attribute with that key.
// Spans (`span/bold`, `span/foregroundColor`, …) style character ranges;
// paragraph attributes (`paragraph/alignment`, bullets, checkboxes, …) style
// whole paragraphs; `sectionData` records the section length.
//
// Every attribute is kept as an opaque range, so formatting this client cannot
// display still survives an edit: ranges are remapped through a diff of the old
// and new text and written back with a matching spanOrderDataList.

data class StyleRange(
    val key: String,
    val value: String,
    val start: Int,
    val end: Int,
    /** Position of the opening token in the original stream. */
    val sequence: Int,
    /** Index of the matching spanOrderData record; unmatched spans sort last. */
    val orderRank: Int = Int.MAX_VALUE,
    /** Samsung span type identifier taken from spanOrderData, when known. */
    val typeId: Int? = null,
) {
    val isSpan: Boolean get() = key.startsWith("span/")
    val isParagraph: Boolean get() = key.startsWith("paragraph/")
    val name: String get() = key.substringAfter('/')
}

class RichText(val text: String, val ranges: List<StyleRange>) {
    companion object {
        private val marker = Regex("<\\?(.*?)\\?>", RegexOption.DOT_MATCHES_ALL)
        private val token = Regex("'([^']*)'(?:='([^']*)')?")
        private const val UNSUPPORTED = "This note uses formatting markup this version cannot rewrite safely. It is read-only here so the formatting is not lost."

        /** Samsung's span identifiers (spanOrderData and the sdocx rich-text model). */
        val spanTypes = mapOf(
            "foregroundColor" to 1, "fontSize" to 3, "fontName" to 4, "bold" to 5, "italic" to 6,
            "underline" to 7, "hyperText" to 9, "backgroundColor" to 17, "strikethrough" to 20,
        )

        fun parse(encoded: String, orderData: List<String> = emptyList()): RichText {
            if (encoded.isEmpty()) return RichText("", emptyList())
            val source = base64Decode(encoded.filterNot { it.isWhitespace() })?.let(::strictUtf8)
                ?: throw NotesException("This text uses an unsupported encoding. Its original data has been retained.")
            val text = StringBuilder()
            val keys = mutableListOf<String>(); val values = mutableListOf<String>()
            val starts = mutableListOf<Int>(); val ends = mutableListOf<Int>()
            val open = HashMap<String, ArrayDeque<Int>>()
            var offset = 0
            for (match in marker.findAll(source)) {
                text.append(decodeRun(source.substring(offset, match.range.first)))
                offset = match.range.last + 1
                val body = match.groupValues[1]
                if (body != "a" && !body.startsWith("a ")) throw NotesException(UNSUPPORTED)
                val content = body.substring(1)
                var position = 0
                for (item in token.findAll(content)) {
                    if (content.substring(position, item.range.first).isNotBlank()) throw NotesException(UNSUPPORTED)
                    position = item.range.last + 1
                    val key = item.groupValues[1]
                    val value = item.groups[2]?.value
                    if (value != null) {
                        keys.add(key); values.add(value); starts.add(text.length); ends.add(-1)
                        open.getOrPut(key) { ArrayDeque() }.addLast(keys.size - 1)
                    } else {
                        val stack = open[key]
                        if (stack.isNullOrEmpty()) throw NotesException(UNSUPPORTED)
                        ends[stack.removeLast()] = text.length
                    }
                }
                if (content.substring(position).isNotBlank()) throw NotesException(UNSUPPORTED)
            }
            text.append(decodeRun(source.substring(offset)))
            val parsed = keys.indices.map { i ->
                StyleRange(keys[i], values[i], starts[i], if (ends[i] < 0) text.length else ends[i], i)
            }
            return RichText(text.toString(), matchOrderData(parsed, orderData))
        }

        private fun decodeRun(value: String): String {
            if (value.isBlank()) return ""
            return base64Decode(value.filterNot { it.isWhitespace() })?.let(::strictUtf8)
                ?: throw NotesException("This text includes an unsupported span. Export the original document to retain it.")
        }

        /** Attaches each spanOrderData record (`type,start,end,value`) to the span it describes. */
        private fun matchOrderData(ranges: List<StyleRange>, orderData: List<String>): List<StyleRange> {
            val result = ranges.toMutableList()
            val used = BooleanArray(result.size)
            orderData.forEachIndexed { rank, encoded ->
                val record = base64Decode(encoded)?.let(::strictUtf8)?.split(",", limit = 4) ?: return@forEachIndexed
                if (record.size != 4) return@forEachIndexed
                val type = record[0].toIntOrNull() ?: return@forEachIndexed
                val start = record[1].toIntOrNull() ?: return@forEachIndexed
                val end = record[2].toIntOrNull() ?: return@forEachIndexed
                val index = result.indices.firstOrNull { i ->
                    val range = result[i]
                    !used[i] && range.isSpan && range.start == start && range.end == end && range.value == record[3] &&
                        (spanTypes[range.name] ?: type) == type
                } ?: return@forEachIndexed
                used[index] = true
                result[index] = result[index].copy(orderRank = rank, typeId = type)
            }
            return result
        }
    }

    /**
     * True when nothing visible would be lost by rewriting the text with the plain
     * 1.1 encoder: whole-text size/colour defaults, "off" styles, left alignment
     * and bookkeeping only. Older clients produced such markup.
     */
    val hasOnlyDefaultStyling: Boolean get() = ranges.all { range ->
        range.end == range.start || when (range.key) {
            "paragraph/parsingState", "sectionData/sectionData" -> true
            "paragraph/alignment" -> range.value == "0"
            "span/fontSize", "span/foregroundColor" -> range.start == 0 && range.end == text.length
            "span/backgroundColor" -> range.value.substringAfterLast(',') == "0"
            "span/bold", "span/italic", "span/underline", "span/strikethrough" -> range.value.substringAfterLast(',').equals("false", ignoreCase = true)
            else -> false
        }
    }

    /** Returns the same formatting carried over to [newText] (UTF-16 offsets, `\n` line breaks). */
    fun withText(newText: String): RichText {
        if (newText == text) return this
        val origin = TextDiff.origins(text, newText)
        fun map(position: Int): Int {
            var low = 0; var high = origin.size
            while (low < high) { val mid = (low + high) ushr 1; if (origin[mid] < position) low = mid + 1 else high = mid }
            return low
        }
        // Paragraph k starts at 0 or at its leading line break, as Samsung writes it.
        val paragraphStarts = listOf(0) + newText.indices.filter { it > 0 && newText[it] == '\n' }
        val result = mutableListOf<StyleRange>()
        for (range in ranges) {
            if (range.start == range.end) {
                val position = keepSurrogates(newText, map(range.start), forward = true)
                result.add(range.copy(start = position, end = position))
                continue
            }
            val start = keepSurrogates(newText, map(range.start), forward = false)
            val end = keepSurrogates(newText, map(range.end), forward = true)
            if (end <= start) continue
            var value = range.value
            if (range.key == "sectionData/sectionData" && value == (range.end - range.start).toString()) value = (end - start).toString()
            val moved = range.copy(value = value, start = start, end = end)
            if (!range.isParagraph) { result.add(moved); continue }
            // A one-paragraph style applies to each paragraph typed inside it (a new
            // checklist line); every paragraph style covers whole paragraphs only, and
            // a merged paragraph keeps the style of the paragraph it starts with.
            val pieces = if (text.substring(range.start + 1, range.end).indexOf('\n') < 0) splitParagraphs(newText, moved) else listOf(moved)
            pieces.mapNotNullTo(result) { snapToParagraphs(it, paragraphStarts, newText.length) }
        }
        return RichText(newText, result)
    }

    /** Normalises legacy values that native Samsung parsers rejected in 1.1.0 uploads. */
    fun normalizedForUpload(): RichText = RichText(text, ranges.mapNotNull { range ->
        if (range.isSpan && range.start == range.end) return@mapNotNull null // caret-only typing styles
        when (range.key) {
            "paragraph/parsingState" -> range.copy(value = range.value.lowercase())
            "span/fontSize" -> {
                val parts = range.value.split(",", limit = 2)
                if (parts.size == 2 && parts[1].toIntOrNull() != null) range.copy(value = parts[0] + "," + parts[1] + ".0") else range
            }
            else -> range
        }
    })

    /** Base64 `<text>` payload. */
    fun encode(): String {
        if (text.isEmpty() && ranges.isEmpty()) return ""
        val positions = (ranges.flatMap { listOf(it.start, it.end) } + listOf(0, text.length)).toSortedSet().toList()
        val active = mutableListOf<StyleRange>()
        val payload = StringBuilder()
        for ((index, position) in positions.withIndex()) {
            val closing = active.filter { it.end == position }
            active.removeAll(closing)
            val closeTokens = closing.reversed().map { "'${it.key}'" }
            val openTokens = mutableListOf<String>()
            // Zero-length entries first, as Samsung writes them, so FIFO and LIFO readers agree.
            val starting = ranges.filter { it.start == position }
                .sortedWith(compareBy<StyleRange> { it.end != it.start }.thenByDescending { it.end }.thenBy { it.sequence })
            for (range in starting) {
                openTokens.add("'${range.key}'='${range.value}'")
                if (range.end == position) openTokens.add("'${range.key}'") else active.add(range)
            }
            if (position == text.length && closeTokens.isNotEmpty() && openTokens.isNotEmpty()) {
                payload.append("<?a ").append(closeTokens.joinToString(" ")).append("?>")
                payload.append("<?a ").append(openTokens.joinToString(" ")).append("?>")
            } else if (closeTokens.isNotEmpty() || openTokens.isNotEmpty()) {
                payload.append("<?a ").append((closeTokens + openTokens).joinToString(" ")).append("?>")
            }
            val next = positions.getOrNull(index + 1) ?: break
            if (next > position) payload.append(base64(text.substring(position, next).toByteArray(Charsets.UTF_8)))
        }
        return base64(payload.toString().toByteArray(Charsets.UTF_8))
    }

    /** Base64 spanOrderData values, in Samsung's original span order. */
    fun spanOrderData(): List<String> = ranges.filter { it.isSpan && it.end > it.start }
        .sortedWith(compareBy<StyleRange> { it.orderRank }.thenBy { it.sequence })
        .map { range ->
            val type = range.typeId ?: spanTypes[range.name]
                ?: throw NotesException("This note uses a text style (${range.name}) this version cannot save yet. Its formatting has been kept unchanged.")
            base64("$type,${range.start},${range.end},${range.value}".toByteArray(Charsets.UTF_8))
        }

    private fun splitParagraphs(source: String, range: StyleRange): List<StyleRange> {
        val pieces = mutableListOf<StyleRange>()
        var start = range.start
        for (index in range.start + 1 until range.end) {
            if (source[index] != '\n') continue
            pieces.add(range.copy(start = start, end = index)); start = index
        }
        pieces.add(range.copy(start = start, end = range.end))
        return pieces
    }

    /** Expands a range to the paragraphs whose first unit it covers; null if it covers none. */
    private fun snapToParagraphs(range: StyleRange, starts: List<Int>, length: Int): StyleRange? {
        val first = starts.binarySearch(range.start).let { if (it >= 0) it else -it - 1 }
        if (first >= starts.size || starts[first] >= range.end) return null
        var last = first
        while (last + 1 < starts.size && starts[last + 1] < range.end) last++
        return range.copy(start = starts[first], end = if (last + 1 < starts.size) starts[last + 1] else length)
    }

    private fun keepSurrogates(source: String, position: Int, forward: Boolean): Int =
        if (position in 1 until source.length && source[position - 1].isHighSurrogate() && source[position].isLowSurrogate()) {
            if (forward) position + 1 else position - 1
        } else position
}

/**
 * Maps each UTF-16 unit of a new text to the old unit whose styling it inherits:
 * unchanged units keep their own index, replacements inherit from the first
 * replaced unit and pure insertions from the unit before them. The result never
 * decreases, so a style range [s, e) maps to [lowerBound(s), lowerBound(e)).
 */
object TextDiff {
    private const val MAX_EDIT_DISTANCE = 2000

    fun origins(old: String, new: String): IntArray {
        val n = old.length; val m = new.length
        val kept = IntArray(m) { -1 }
        var prefix = 0
        while (prefix < n && prefix < m && old[prefix] == new[prefix]) { kept[prefix] = prefix; prefix++ }
        var suffix = 0
        while (suffix < n - prefix && suffix < m - prefix && old[n - 1 - suffix] == new[m - 1 - suffix]) {
            kept[m - 1 - suffix] = n - 1 - suffix; suffix++
        }
        myers(old.substring(prefix, n - suffix), new.substring(prefix, m - suffix))?.forEach { (oldIndex, newIndex) ->
            kept[prefix + newIndex] = prefix + oldIndex
        }
        slideOverLineBreaks(old, new, kept)
        val origin = IntArray(m)
        var j = 0
        while (j < m) {
            if (kept[j] >= 0) { origin[j] = kept[j]; j++; continue }
            var end = j
            while (end < m && kept[end] < 0) end++
            val a = if (j == 0) 0 else kept[j - 1] + 1
            val b = if (end == m) n else kept[end]
            val inherit = if (b > a) a else maxOf(a - 1, 0)
            for (k in j until end) origin[k] = minOf(inherit, maxOf(n - 1, 0))
            j = end
        }
        return origin
    }

    /**
     * A paragraph owns its leading line break in Samsung's markup. When an inserted
     * or deleted block is bounded by line breaks it can align either way; prefer
     * the alignment that starts the block at a line break, so a new line typed
     * after a checklist item joins that checklist and a deleted line takes its own
     * paragraph style with it.
     */
    private fun slideOverLineBreaks(old: String, new: String, kept: IntArray) {
        val m = new.length
        var j = 0
        while (j < m) { // pure insertions
            if (kept[j] >= 0) { j++; continue }
            var start = j; var end = j
            while (end < m && kept[end] < 0) end++
            val next = if (end < m) kept[end] else old.length
            if (start > 0 && kept[start - 1] >= 0 && kept[start - 1] + 1 == next) {
                while (start > 0 && kept[start - 1] >= 0 && new[start - 1] == '\n' && new[end - 1] == '\n') {
                    kept[end - 1] = kept[start - 1]; kept[start - 1] = -1; start--; end--
                }
            }
            j = maxOf(end, j + 1)
        }
        for (k in 1..m) { // pure deletions between kept[k - 1] and kept[k]
            var left = k - 1
            if (kept[left] < 0) continue
            var gapEnd = if (k < m) kept[k] else old.length
            if (k < m && kept[k] < 0) continue
            if (gapEnd <= kept[left] + 1) continue
            while (left >= 0 && kept[left] >= 0 && old[kept[left]] == '\n' && old[gapEnd - 1] == '\n' &&
                (left == 0 || kept[left - 1] == kept[left] - 1)) {
                kept[left] = gapEnd - 1; gapEnd--; left--
            }
        }
    }

    /** Matching (old, new) index pairs, or null when the edit is too large to align. */
    private fun myers(a: String, b: String): List<Pair<Int, Int>>? {
        val n = a.length; val m = b.length
        if (n == 0 || m == 0) return emptyList()
        val max = minOf(n + m, MAX_EDIT_DISTANCE)
        val offset = max + 1
        val v = IntArray(2 * max + 3)
        val trace = ArrayList<IntArray>()
        for (d in 0..max) {
            trace.add(v.copyOfRange(offset - d - 1, offset + d + 2))
            var k = -d
            while (k <= d) {
                var x = if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) v[offset + k + 1] else v[offset + k - 1] + 1
                var y = x - k
                while (x < n && y < m && a[x] == b[y]) { x++; y++ }
                v[offset + k] = x
                if (x >= n && y >= m) return backtrack(trace, n, m)
                k += 2
            }
        }
        return null
    }

    private fun backtrack(trace: List<IntArray>, n: Int, m: Int): List<Pair<Int, Int>> {
        val pairs = ArrayList<Pair<Int, Int>>()
        var x = n; var y = m
        for (d in trace.indices.reversed()) {
            val v = trace[d]
            fun at(k: Int) = v[k + d + 1]
            val k = x - y
            val previousK = if (k == -d || (k != d && at(k - 1) < at(k + 1))) k + 1 else k - 1
            val previousX = at(previousK)
            val previousY = previousX - previousK
            while (x > previousX && y > previousY) { x--; y--; pairs.add(x to y) }
            x = previousX; y = previousY
        }
        return pairs
    }
}

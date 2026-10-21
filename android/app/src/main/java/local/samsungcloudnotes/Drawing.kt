package local.samsungcloudnotes

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.pdf.PdfDocument
import java.io.ByteArrayOutputStream
import kotlin.math.abs
import kotlin.math.max

// Port of the read-only stroke preview in Sources/Shared/Drawing.swift. The cloud
// envelope was examined directly; sdocx's published format research informed
// the channel/framing interpretation. No upstream code is bundled.

private class InkBytes(val bytes: ByteArray) {
    var position = 0
    val remaining get() = bytes.size - position
    fun take(count: Int): ByteArray {
        if (count < 0 || position > bytes.size || count > bytes.size - position) throw NotesException("Incomplete drawing data.")
        return bytes.copyOfRange(position, position + count).also { position += count }
    }
    fun integer(count: Int): Long = take(count).foldIndexed(0L) { index, sum, byte -> sum or ((byte.toLong() and 0xff) shl (index * 8)) }
    fun number(count: Int): Double {
        val bits = integer(count)
        val result = if (count == 8) java.lang.Double.longBitsToDouble(bits) else java.lang.Float.intBitsToFloat(bits.toInt()).toDouble()
        if (!result.isFinite() || abs(result) >= 10_000_000) throw NotesException("Unsupported drawing coordinate.")
        return result
    }
}

private class InkFrame(stream: InkBytes) {
    val kind: Int
    val properties: ByteArray
    val fields: ByteArray
    val fixed: ByteArray
    val flexible: ByteArray
    init {
        val length = stream.integer(4).toInt()
        if (length < 12 || length > 16_000_000) throw NotesException("Unsupported drawing frame.")
        val header = InkBytes(stream.take(length - 4))
        kind = header.integer(2).toInt()
        val split = header.integer(4).toInt()
        properties = header.take(header.integer(1).toInt())
        fields = header.take(header.integer(1).toInt())
        val fixedEnd = if (split == 0 && fields.all { it.toInt() == 0 }) length else split
        if (fixedEnd < header.position + 4 || fixedEnd > length) throw NotesException("Invalid drawing frame bounds.")
        fixed = header.take(fixedEnd - 4 - header.position)
        flexible = header.take(length - fixedEnd)
    }
    companion object {
        fun bit(bytes: ByteArray, index: Int) = index / 8 < bytes.size && (bytes[index / 8].toInt() and (1 shl (index % 8))) != 0
    }
}

data class InkPoint(val x: Double, val y: Double)

class InkStroke(data: ByteArray) {
    val points: List<InkPoint>
    val color: Long
    val width: Double
    init {
        val stream = InkBytes(data)
        if (stream.integer(4) != 0xffffffffL || stream.integer(4) != 4L || stream.integer(4) != 4000L) throw NotesException("Unsupported cloud stroke version.")
        val base = InkFrame(stream)
        val ink = InkFrame(stream)
        if (base.kind != 0 || ink.kind != 1 || !InkFrame.bit(base.properties, 3) || InkFrame.bit(ink.properties, 3)) throw NotesException("Unsupported or hidden drawing stroke.")
        if (InkFrame.bit(base.fields, 0) && abs(InkBytes(base.flexible).number(4)) >= 0.001) throw NotesException("Rotated strokes are not supported in this preview.")
        val channel = InkBytes(ink.fixed)
        val count = channel.integer(2).toInt()
        val compressed = InkFrame.bit(ink.properties, 0)
        val stylus = InkFrame.bit(ink.properties, 2)
        val expected = if (count == 0) 0 else if (compressed) 16 + (count - 1) * 4 + (if (stylus) 4 else 2) * (4 + (count - 1) * 2) else count * (if (stylus) 32 else 24)
        if (count <= 0 || count > 65535 || channel.remaining != expected + 2) throw NotesException("Unsupported drawing point channels.")
        val decoded = ArrayList<InkPoint>(count)
        var x = 0.0; var y = 0.0
        for (index in 0 until count) {
            if (compressed && index > 0) {
                val dx = channel.integer(2); val dy = channel.integer(2)
                x += (dx and 0x7fffL).toDouble() / 32 * (if ((dx and 0x8000L) == 0L) 1 else -1)
                y += (dy and 0x7fffL).toDouble() / 32 * (if ((dy and 0x8000L) == 0L) 1 else -1)
            } else { x = channel.number(8); y = channel.number(8) }
            if (abs(x) >= 1_000_000 || abs(y) >= 1_000_000) throw NotesException("Drawing lies outside preview bounds.")
            decoded.add(InkPoint(x, y))
        }
        points = decoded
        var pressure = channel.number(4)
        var totalPressure = pressure.coerceIn(0.0, 1.0)
        for (index in 1 until count) {
            if (compressed) {
                val raw = channel.integer(2)
                pressure += (raw and 0x7fffL).toDouble() / 4096 * (if ((raw and 0x8000L) == 0L) 1 else -1)
            } else pressure = channel.number(4)
            totalPressure += pressure.coerceIn(0.0, 1.0)
        }
        val style = InkBytes(ink.flexible)
        if (InkFrame.bit(ink.fields, 0)) style.take(4)
        if (InkFrame.bit(ink.fields, 1)) style.take(4)
        color = if (InkFrame.bit(ink.fields, 2)) style.integer(4) else 0xff000000L
        val penWidth = if (InkFrame.bit(ink.fields, 3)) style.number(4) else 1.0
        if (penWidth < 0 || penWidth > 1000) throw NotesException("Unsupported drawing pen size.")
        width = max(0.3, penWidth * max(0.15, totalPressure / count))
    }
}

class DrawingPage(val id: Int, val width: Double, val height: Double, val background: Long, val strokes: List<InkStroke>, val unsupported: Int) {
    fun draw(canvas: Canvas) {
        canvas.drawColor(background.toInt())
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }
        for (stroke in strokes) {
            val first = stroke.points.firstOrNull() ?: continue
            paint.color = stroke.color.toInt(); paint.strokeWidth = stroke.width.toFloat()
            if (stroke.points.size == 1) {
                paint.style = Paint.Style.FILL
                canvas.drawCircle(first.x.toFloat(), first.y.toFloat(), (stroke.width / 2).toFloat(), paint); continue
            }
            paint.style = Paint.Style.STROKE
            val path = Path().apply { moveTo(first.x.toFloat(), first.y.toFloat()); stroke.points.drop(1).forEach { lineTo(it.x.toFloat(), it.y.toFloat()) } }
            canvas.drawPath(path, paint)
        }
    }

    companion object {
        fun from(page: XmlElement, index: Int): DrawingPage? {
            val width = page.attr("width").toDoubleOrNull() ?: 720.0
            val height = page.attr("height").toDoubleOrNull() ?: 1080.0
            if (!width.isFinite() || !height.isFinite() || width <= 0 || height <= 0 || width > 100_000 || height > 100_000) return null
            val background = (page.attr("bgColor").toLongOrNull() ?: -1L) and 0xffffffffL
            val strokes = mutableListOf<InkStroke>()
            var unsupported = 0
            for (layer in page.first("layerList")?.elements("layer") ?: emptyList()) {
                if (layer.attr("visible") == "false") continue
                for (list in layer.descendants("objectList")) for (obj in list.elements("object")) {
                    val data = if (obj.attr("type") == "stroke") base64Decode(obj.value("strokeBinary")) else null
                    val stroke = data?.takeIf { it.size <= 16_000_000 }?.let { runCatching { InkStroke(it) }.getOrNull() }
                    if (stroke == null) unsupported++ else strokes.add(stroke)
                }
            }
            if (strokes.isEmpty() && unsupported == 0) return null
            return DrawingPage(index, width, height, background, strokes, unsupported)
        }

        fun pdf(pages: List<DrawingPage>): ByteArray {
            val document = PdfDocument()
            try {
                for (page in pages) {
                    val info = PdfDocument.PageInfo.Builder(page.width.toInt().coerceAtLeast(1), page.height.toInt().coerceAtLeast(1), page.id + 1).create()
                    val pdfPage = document.startPage(info)
                    page.draw(pdfPage.canvas)
                    document.finishPage(pdfPage)
                }
                return ByteArrayOutputStream().also { document.writeTo(it) }.toByteArray()
            } finally { document.close() }
        }
    }
}

/** Scales [page] to fit [canvasWidth] for on-screen previews. */
fun DrawingPage.drawScaled(canvas: Canvas, canvasWidth: Float) {
    val scale = canvasWidth / width.toFloat()
    canvas.save(); canvas.scale(scale, scale); draw(canvas); canvas.restore()
}

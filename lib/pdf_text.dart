import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal pure-Dart PDF text extraction for chat attachments.
///
/// Strategy: scan the raw file for `stream…endstream` payloads, inflate them
/// (PDF content streams are usually FlateDecode = raw zlib), then pull the
/// text-showing operators' parenthesized strings out of the content stream.
///
/// This is deliberately best-effort (no font/CMap parsing):
/// - Text PDFs exported from Word/LaTeX/web tools extract well.
/// - Scanned PDFs (page images, no text layer) extract nothing — the caller
///   tells the user honestly and suggests attaching page screenshots instead.
class PdfText {
  PdfText._();

  static const maxChars = 12000;

  /// Returns the extracted text. [scanned] is true when the PDF has pages
  /// but no extractable text layer.
  static ({String text, bool scanned}) extract(Uint8List bytes) {
    final raw = latin1.decode(bytes);
    final buf = StringBuffer();
    var pageMarkers = RegExp(r'/Type\s*/Page[^s]').allMatches(raw).length;
    if (pageMarkers == 0) pageMarkers = '/Type/Page'.allMatches(raw).length;

    var i = raw.indexOf('stream');
    while (i >= 0 && buf.length < maxChars) {
      final isEnd = i >= 3 && raw.startsWith('end', i - 3);
      var start = i + 'stream'.length;
      if (raw.startsWith('\r\n', start)) {
        start += 2;
      } else if (start < raw.length && (raw[start] == '\n' || raw[start] == '\r')) {
        start += 1;
      }
      final end = raw.indexOf('endstream', start);
      if (end < 0) break;
      if (!isEnd) {
        // latin1 roundtrip is byte-exact, so zlib gets the original bytes.
        final payload = Uint8List.fromList(latin1.encode(raw.substring(start, end)));
        String content;
        try {
          content = utf8.decode(zlib.decode(payload), allowMalformed: true);
        } catch (_) {
          content = utf8.decode(payload, allowMalformed: true); // uncompressed stream
        }
        buf.write(_opsText(content));
      }
      i = raw.indexOf('stream', end + 'endstream'.length);
    }

    final text = buf
        .toString()
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    final clipped = text.length > maxChars ? '${text.substring(0, maxChars)}\n… (truncated)' : text;
    return (text: clipped, scanned: pageMarkers > 0 && text.trim().length < 20);
  }

  static final _parenRe = RegExp(r'\(((?:\\.|[^\\()])*)\)');

  /// Extracts the strings shown by text operators in one content stream.
  static String _opsText(String content) {
    if (!content.contains('BT') && !(content.contains('Tj') || content.contains('TJ'))) {
      return '';
    }
    final buf = StringBuffer();
    for (final m in _parenRe.allMatches(content)) {
      buf.write(_unescape(m.group(1)!));
      buf.write('\n');
    }
    return buf.toString();
  }

  static String _unescape(String s) {
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != r'\' || i + 1 >= s.length) {
        buf.write(c);
        continue;
      }
      final n = s[i + 1];
      switch (n) {
        case 'n':
          buf.write('\n');
          i++;
        case 'r':
          buf.write('\r');
          i++;
        case 't':
          buf.write('\t');
          i++;
        case 'b':
        case 'f':
          i++;
        case '(':
        case ')':
        case r'\':
          buf.write(n);
          i++;
        default:
          // Octal escape \ddd (up to 3 digits).
          if (int.tryParse(n, radix: 8) != null) {
            var oct = n;
            var j = i + 1;
            while (oct.length < 3 && j < s.length && int.tryParse(s[j], radix: 8) != null) {
              oct += s[j];
              j++;
            }
            buf.write(String.fromCharCode(int.parse(oct, radix: 8)));
            i += oct.length;
          } else {
            buf.write(n);
            i++;
          }
      }
    }
    return buf.toString();
  }
}

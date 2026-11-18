import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 対応する字幕ファイルの拡張子
const subtitleExtensions = ['.lrc', '.srt'];

/// 読み込む字幕ファイルの最大サイズ (巨大ファイルでメモリを使い切らないため)
const maxSubtitleBytes = 2 * 1024 * 1024;

/// 1ファイルから読む最大行数
const maxSubtitleCues = 5000;

bool isSubtitleFile(String name) =>
    subtitleExtensions.contains(p.extension(name).toLowerCase());

/// 字幕の1行。
class SubtitleCue {
  const SubtitleCue({required this.start, this.end, required this.text});

  final Duration start;

  /// 終わりの時刻。null なら次の行 (最終行なら曲の終わり) まで
  final Duration? end;
  final String text;

  SubtitleCue withEnd(Duration end) =>
      SubtitleCue(start: start, end: end, text: text);
}

enum SubtitleSource {
  /// 音声と同じフォルダにある同名ファイル
  sidecar,

  /// ユーザーが選んでアプリ内にコピーしたファイル
  manual,
}

/// 読み込んだ字幕。
class Subtitles {
  const Subtitles({
    required this.cues,
    required this.source,
    required this.fileName,
    this.garbled = false,
  });

  /// 開始時刻順
  final List<SubtitleCue> cues;
  final SubtitleSource source;
  final String fileName;

  /// UTF-8 として読めない文字があった (Shift_JIS 等の可能性)
  final bool garbled;

  /// [i] 行目の終わり。分からなければ null (曲の終わりまで)。
  Duration? endOf(int i) =>
      cues[i].end ?? (i + 1 < cues.length ? cues[i + 1].start : null);

  /// [pos] 時点で表示する行 (最後に始まった行)。最初の行より前なら -1。
  int indexAt(Duration pos) {
    var lo = 0, hi = cues.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= pos) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return found;
  }
}

/// 字幕の読み込み結果。
class SubtitleLoad {
  const SubtitleLoad({this.subtitles, this.error});

  static const notFound = SubtitleLoad();

  final Subtitles? subtitles;

  /// 字幕ファイルはあったが使えなかった理由
  final String? error;
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

List<SubtitleCue> parseSubtitles(String text, String extension) =>
    extension.toLowerCase() == '.srt' ? parseSrt(text) : parseLrc(text);

final _lrcTime = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _lrcOffset = RegExp(
  r'^\s*\[offset:\s*([+-]?\d{1,7})\s*\]',
  caseSensitive: false,
);

/// 拡張 LRC の単語ごとのタイムスタンプ <mm:ss.xx>
final _lrcWordTime = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

Duration _time(String h, String m, String s, String? frac) => Duration(
  hours: int.parse(h),
  minutes: int.parse(m),
  seconds: int.parse(s),
  // "5" → 500ms, "50" → 500ms, "500" → 500ms
  milliseconds: frac == null ? 0 : int.parse(frac.padRight(3, '0')),
);

/// LRC を解析する。
///
/// - 1行に複数のタイムスタンプ `[00:12.00][00:45.00]歌詞` に対応
/// - `[offset:+500]` (正の値で早める) に対応
/// - 空の行は直前の行の終わりとして扱う
List<SubtitleCue> parseLrc(String text) {
  var offsetMs = 0;
  final raw = <SubtitleCue>[];
  for (final line in const LineSplitter().convert(text)) {
    final off = _lrcOffset.firstMatch(line);
    if (off != null) {
      offsetMs = int.parse(off[1]!);
      continue;
    }
    final times = <Duration>[];
    var rest = line.trimLeft();
    for (
      var m = _lrcTime.matchAsPrefix(rest);
      m != null;
      m = _lrcTime.matchAsPrefix(rest)
    ) {
      times.add(_time('0', m[1]!, m[2]!, m[3]));
      rest = rest.substring(m.end).trimLeft();
    }
    final body = rest.replaceAll(_lrcWordTime, '').trim();
    for (final t in times) {
      raw.add(SubtitleCue(start: t, text: body));
    }
  }

  final offset = Duration(milliseconds: offsetMs);
  final shifted = [
    for (final c in raw)
      SubtitleCue(
        start: c.start - offset < Duration.zero
            ? Duration.zero
            : c.start - offset,
        text: c.text,
      ),
  ]..sort((a, b) => a.start.compareTo(b.start));

  final cues = <SubtitleCue>[];
  for (final c in shifted) {
    if (c.text.isEmpty) {
      if (cues.isNotEmpty && cues.last.end == null) {
        cues.last = cues.last.withEnd(c.start);
      }
      continue;
    }
    cues.add(c);
    if (cues.length >= maxSubtitleCues) break;
  }
  return cues;
}

final _srtTime = RegExp(
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
  r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
);

/// `<i>` などの HTML タグと `{\an8}` などの ASS タグ
final _srtTag = RegExp(r'<[^>]*>|\{\\[^}]*\}');

/// SRT を解析する。
List<SubtitleCue> parseSrt(String text) {
  final lines = const LineSplitter().convert(text);
  final cues = <SubtitleCue>[];
  for (var i = 0; i < lines.length && cues.length < maxSubtitleCues; i++) {
    final m = _srtTime.firstMatch(lines[i]);
    if (m == null) continue;
    final body = <String>[];
    var j = i + 1;
    for (; j < lines.length && lines[j].trim().isNotEmpty; j++) {
      final t = lines[j].replaceAll(_srtTag, '').trim();
      if (t.isNotEmpty) body.add(t);
    }
    i = j;
    final start = _time(m[1]!, m[2]!, m[3]!, m[4]);
    final end = _time(m[5]!, m[6]!, m[7]!, m[8]);
    if (end <= start || body.isEmpty) continue;
    cues.add(SubtitleCue(start: start, end: end, text: body.join('\n')));
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// 字幕ファイルのバイト列を文字列にする (UTF-8 / BOM 付き UTF-16 に対応)。
({String text, bool garbled}) decodeSubtitleBytes(Uint8List bytes) {
  String text;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    text = utf8.decode(bytes.sublist(3), allowMalformed: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    text = _decodeUtf16(bytes, littleEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    text = _decodeUtf16(bytes, littleEndian: false);
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
  }
  return (text: text, garbled: text.contains('�'));
}

String _decodeUtf16(Uint8List b, {required bool littleEndian}) {
  final units = <int>[
    for (var i = 2; i + 1 < b.length; i += 2)
      littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1],
  ];
  return String.fromCharCodes(units);
}

// ---------------------------------------------------------------------------
// 読み込み・保存
// ---------------------------------------------------------------------------

/// 字幕ファイルを探して読む。
///
/// 1. ユーザーが選んだ字幕 (アプリ内にコピー済み)
/// 2. 音声と同じフォルダにある同名の .lrc / .srt
///
/// Android 11 以降は他アプリが置いた音声以外のファイルを読めない場合が
/// あるため、2 が使えない時のために 1 を用意している。
class SubtitleStore {
  SubtitleStore(this.manualDir);

  /// 手動で選んだ字幕のコピー先 (アプリ専用領域)
  final Directory manualDir;

  /// 曲のパスから、コピーした字幕のファイル名を作る (FNV-1a 64bit)。
  static String keyFor(String trackPath) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(trackPath)) {
      h ^= b;
      h *= 0x100000001b3; // 64bit で桁あふれさせる
    }
    String hex(int v) => (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return hex(h >> 32) + hex(h);
  }

  File _manualFile(String trackPath, String ext) =>
      File(p.join(manualDir.path, '${keyFor(trackPath)}$ext'));

  Future<SubtitleLoad> load(String trackPath) async {
    for (final ext in subtitleExtensions) {
      final f = _manualFile(trackPath, ext);
      if (await f.exists()) {
        return _read(
          f,
          SubtitleSource.manual,
          p.basenameWithoutExtension(trackPath) + ext,
        );
      }
    }
    final base = p.withoutExtension(trackPath);
    for (final ext in subtitleExtensions) {
      for (final e in {ext, ext.toUpperCase()}) {
        final f = File('$base$e');
        final bool exists;
        try {
          exists = await f.exists();
        } on FileSystemException {
          continue;
        }
        if (exists) {
          return _read(f, SubtitleSource.sidecar, p.basename(f.path));
        }
      }
    }
    return SubtitleLoad.notFound;
  }

  Future<SubtitleLoad> _read(
    File f,
    SubtitleSource source,
    String fileName,
  ) async {
    try {
      if (await f.length() > maxSubtitleBytes) {
        return const SubtitleLoad(error: 'ファイルが大きすぎます (2MB まで)');
      }
      final decoded = decodeSubtitleBytes(await f.readAsBytes());
      final cues = parseSubtitles(decoded.text, p.extension(f.path));
      if (cues.isEmpty) {
        return const SubtitleLoad(error: '時刻付きの行が見つかりませんでした');
      }
      return SubtitleLoad(
        subtitles: Subtitles(
          cues: cues,
          source: source,
          fileName: fileName,
          garbled: decoded.garbled,
        ),
      );
    } on FileSystemException {
      return SubtitleLoad(
        error: '${p.basename(f.path)} を読み取れませんでした (アクセス権限がありません)',
      );
    }
  }

  /// ユーザーが選んだ字幕をアプリ内にコピーする。
  /// 使えないファイルならエラーメッセージ、成功なら null。
  Future<String?> saveManual(
    String trackPath,
    String fileName,
    Uint8List bytes,
  ) async {
    final ext = p.extension(fileName).toLowerCase();
    if (!subtitleExtensions.contains(ext)) {
      return '.lrc か .srt のファイルを選んでください';
    }
    if (bytes.length > maxSubtitleBytes) {
      return 'ファイルが大きすぎます (2MB まで)';
    }
    final decoded = decodeSubtitleBytes(bytes);
    if (parseSubtitles(decoded.text, ext).isEmpty) {
      return '時刻付きの行が見つかりませんでした';
    }
    await manualDir.create(recursive: true);
    await removeManual(trackPath);
    await _manualFile(trackPath, ext).writeAsBytes(bytes, flush: true);
    return null;
  }

  Future<void> removeManual(String trackPath) async {
    for (final ext in subtitleExtensions) {
      final f = _manualFile(trackPath, ext);
      if (await f.exists()) await f.delete();
    }
  }
}

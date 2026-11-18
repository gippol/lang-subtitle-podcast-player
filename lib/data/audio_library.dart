import 'dart:io';

import 'package:path/path.dart' as p;

/// 再生対象とする拡張子 (ExoPlayer が対応している主要フォーマット)。
const audioExtensions = {
  '.mp3',
  '.m4a',
  '.m4b',
  '.aac',
  '.wav',
  '.ogg',
  '.oga',
  '.opus',
  '.flac',
};

bool isAudioFile(String path) =>
    audioExtensions.contains(p.extension(path).toLowerCase());

/// フォルダの中身 (サブフォルダと音声ファイルのフルパス)。
class FolderContents {
  const FolderContents({required this.folders, required this.tracks});

  final List<String> folders;
  final List<String> tracks;

  bool get isEmpty => folders.isEmpty && tracks.isEmpty;
}

/// ルートフォルダ配下の音声ファイルを扱う。
class AudioLibrary {
  AudioLibrary({required this.rootPath});

  /// 内部ストレージ/Music/LangPlayer
  static const defaultRootPath = '/storage/emulated/0/Music/LangPlayer';

  final String rootPath;

  /// ルートフォルダが無ければ作成する。作成できなければ false。
  Future<bool> ensureRoot() async {
    final dir = Directory(rootPath);
    if (await dir.exists()) return true;
    try {
      await dir.create(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<FolderContents> list(String path) async {
    final folders = <String>[];
    final tracks = <String>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue; // 隠しファイル/フォルダは除外
      if (entity is Directory) {
        folders.add(entity.path);
      } else if (entity is File && isAudioFile(entity.path)) {
        tracks.add(entity.path);
      }
    }
    int byName(String a, String b) =>
        naturalCompare(p.basename(a), p.basename(b));
    folders.sort(byName);
    tracks.sort(byName);
    return FolderContents(folders: folders, tracks: tracks);
  }

  /// ルートからの相対表示用パス (例: LangPlayer/English/Podcast)。
  String displayPath(String path) {
    final rootName = p.basename(rootPath);
    if (p.equals(path, rootPath)) return rootName;
    return p.join(rootName, p.relative(path, from: rootPath));
  }
}

final _chunk = RegExp(r'\d+|\D+');

/// 数字部分を数値として比較する自然順ソート ("2.mp3" < "10.mp3")。
int naturalCompare(String a, String b) {
  final ca = _chunk.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final cb = _chunk.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < ca.length && i < cb.length; i++) {
    final x = ca[i], y = cb[i];
    final nx = int.tryParse(x), ny = int.tryParse(y);
    final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
    if (c != 0) return c;
  }
  final c = ca.length.compareTo(cb.length);
  return c != 0 ? c : a.compareTo(b);
}

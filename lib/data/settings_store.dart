import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bookmark.dart';

/// 前回の再生状態 (アプリ再起動時に続きから再開するため)。
class LastSession {
  const LastSession({
    required this.folder,
    required this.trackPath,
    required this.position,
  });

  final String folder;
  final String trackPath;
  final Duration position;
}

/// 再生設定・再生位置の永続化。
class SettingsStore {
  SettingsStore(this._prefs);

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  static const _kSpeed = 'speed';
  static const _kRepeat = 'repeat';
  static const _kShuffle = 'shuffle';
  static const _kSessionFolder = 'session.folder';
  static const _kSessionTrack = 'session.track';
  static const _kSessionPos = 'session.positionMs';
  static const _kPositions = 'positions';
  static const _kAbCount = 'ab.count';
  static const _kAbGap = 'ab.gapMs';
  static const _kBookmarks = 'bookmarks';
  static const _kShowSubtitles = 'subtitles.show';

  /// ファイルごとの再生位置を覚えておく最大件数。
  static const maxSavedPositions = 300;

  /// 保存できる区間の最大件数。
  static const maxBookmarks = 1000;

  /// 再生速度として受け付ける範囲 (外部アプリから不正値が来ても安全な値に丸める)。
  static const minSpeed = 0.25;
  static const maxSpeed = 4.0;

  static double sanitizeSpeed(double v) =>
      v.isFinite ? v.clamp(minSpeed, maxSpeed).toDouble() : 1.0;

  double get speed => sanitizeSpeed(_prefs.getDouble(_kSpeed) ?? 1.0);
  Future<void> setSpeed(double v) =>
      _prefs.setDouble(_kSpeed, sanitizeSpeed(v));

  AudioServiceRepeatMode get repeatMode {
    final name = _prefs.getString(_kRepeat);
    return AudioServiceRepeatMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => AudioServiceRepeatMode.all,
    );
  }

  Future<void> setRepeatMode(AudioServiceRepeatMode m) =>
      _prefs.setString(_kRepeat, m.name);

  bool get shuffle => _prefs.getBool(_kShuffle) ?? false;
  Future<void> setShuffle(bool v) => _prefs.setBool(_kShuffle, v);

  LastSession? get lastSession {
    final folder = _prefs.getString(_kSessionFolder);
    final track = _prefs.getString(_kSessionTrack);
    if (folder == null || track == null) return null;
    return LastSession(
      folder: folder,
      trackPath: track,
      position: Duration(milliseconds: _prefs.getInt(_kSessionPos) ?? 0),
    );
  }

  Future<void> saveSession(LastSession s) async {
    await _prefs.setString(_kSessionFolder, s.folder);
    await _prefs.setString(_kSessionTrack, s.trackPath);
    await _prefs.setInt(_kSessionPos, s.position.inMilliseconds);
  }

  // ---- ファイルごとの再生位置 (挿入順を保持し、古いものから削除) ----

  Map<String, int> _positions() {
    final raw = _prefs.getString(_kPositions);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is int)
            e.key as String: e.value as int,
      };
    } on FormatException {
      return {}; // 壊れたデータで起動不能にならないよう破棄する
    }
  }

  Duration? positionFor(String path) {
    final ms = _positions()[path];
    return ms == null ? null : Duration(milliseconds: ms);
  }

  Future<void> savePosition(String path, Duration pos) async {
    final map = _positions()
      ..remove(path)
      ..[path] = pos.inMilliseconds;
    while (map.length > maxSavedPositions) {
      map.remove(map.keys.first);
    }
    await _prefs.setString(_kPositions, jsonEncode(map));
  }

  Future<void> clearPosition(String path) async {
    final map = _positions();
    if (map.remove(path) != null) {
      await _prefs.setString(_kPositions, jsonEncode(map));
    }
  }

  bool get showSubtitles => _prefs.getBool(_kShowSubtitles) ?? true;
  Future<void> setShowSubtitles(bool v) => _prefs.setBool(_kShowSubtitles, v);

  // ---- 区間リピートの回し方 ----

  AbRepeatSettings get abRepeat {
    final count = (_prefs.getInt(_kAbCount) ?? 0).clamp(
      0,
      AbRepeatSettings.maxCount,
    );
    final gapMs = (_prefs.getInt(_kAbGap) ?? 0).clamp(
      0,
      AbRepeatSettings.maxGap.inMilliseconds,
    );
    return AbRepeatSettings(
      count: count,
      gap: Duration(milliseconds: gapMs),
    );
  }

  Future<void> setAbRepeat(AbRepeatSettings s) async {
    await _prefs.setInt(_kAbCount, s.count);
    await _prefs.setInt(_kAbGap, s.gap.inMilliseconds);
  }

  // ---- 保存した区間 ----

  List<AbBookmark> get bookmarks {
    final raw = _prefs.getString(_kBookmarks);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [for (final e in decoded) ?AbBookmark.fromJson(e)];
    } on FormatException {
      return [];
    }
  }

  Future<void> saveBookmarks(List<AbBookmark> list) {
    final kept = list.length > maxBookmarks
        ? list.sublist(list.length - maxBookmarks)
        : list;
    return _prefs.setString(
      _kBookmarks,
      jsonEncode([for (final b in kept) b.toJson()]),
    );
  }
}

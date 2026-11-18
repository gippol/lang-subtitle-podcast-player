import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lang_player/audio/player_handler.dart';
import 'package:lang_player/data/audio_library.dart';
import 'package:lang_player/data/bookmark.dart';
import 'package:lang_player/data/settings_store.dart';
import 'package:lang_player/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('naturalCompare', () {
    test('数字を数値として比較する', () {
      final names = [
        '10.mp3',
        '2.mp3',
        'Lesson 1.mp3',
        '1.mp3',
        'lesson 10.mp3',
        'Lesson 9.mp3',
      ];
      names.sort(naturalCompare);
      expect(names, [
        '1.mp3',
        '2.mp3',
        '10.mp3',
        'Lesson 1.mp3',
        'Lesson 9.mp3',
        'lesson 10.mp3',
      ]);
    });
  });

  test('isAudioFile は大文字拡張子も判定する', () {
    expect(isAudioFile('/a/b.MP3'), isTrue);
    expect(isAudioFile('/a/b.flac'), isTrue);
    expect(isAudioFile('/a/b.txt'), isFalse);
  });

  test('AudioLibrary.list はフォルダと音声ファイルを分けて自然順に並べる', () async {
    final root = await Directory.systemTemp.createTemp('langplayer');
    addTearDown(() => root.delete(recursive: true));
    await Directory(p.join(root.path, 'B')).create();
    await Directory(p.join(root.path, 'A')).create();
    await Directory(p.join(root.path, '.hidden')).create();
    for (final f in ['10.mp3', '2.m4a', 'note.txt', '.x.mp3']) {
      await File(p.join(root.path, f)).writeAsString('');
    }

    final lib = AudioLibrary(rootPath: root.path);
    final c = await lib.list(root.path);
    expect(c.folders.map(p.basename), ['A', 'B']);
    expect(c.tracks.map(p.basename), ['2.m4a', '10.mp3']);
    expect(
      lib.displayPath(p.join(root.path, 'A')),
      p.join(p.basename(root.path), 'A'),
    );
  });

  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 83)), '01:23');
    expect(
      formatDuration(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
    expect(formatDuration(null), '--:--');
  });

  group('SettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('既定値', () async {
      final s = await SettingsStore.load();
      expect(s.speed, 1.0);
      expect(s.repeatMode, AudioServiceRepeatMode.all);
      expect(s.shuffle, isFalse);
      expect(s.lastSession, isNull);
    });

    test('ファイルごとの再生位置を保存・削除できる', () async {
      final s = await SettingsStore.load();
      await s.savePosition('/x.mp3', const Duration(seconds: 42));
      expect(s.positionFor('/x.mp3'), const Duration(seconds: 42));
      await s.clearPosition('/x.mp3');
      expect(s.positionFor('/x.mp3'), isNull);
    });

    test('保存件数の上限を超えると古いものから消える', () async {
      final s = await SettingsStore.load();
      for (var i = 0; i <= SettingsStore.maxSavedPositions; i++) {
        await s.savePosition('/$i.mp3', const Duration(seconds: 10));
      }
      expect(s.positionFor('/0.mp3'), isNull);
      expect(s.positionFor('/1.mp3'), isNotNull);
    });
  });

  group('nextAbStep', () {
    const ab = AbLoop(a: Duration(seconds: 10), b: Duration(seconds: 20));
    const atB = Duration(seconds: 20);

    test('B より前・区間なしでは何もしない', () {
      expect(nextAbStep(ab, const Duration(seconds: 19), 0), AbStep.none);
      expect(nextAbStep(AbLoop.none, atB, 0), AbStep.none);
    });

    test('無制限なら何回でも戻る', () {
      expect(nextAbStep(ab.copyWith(passes: 50), atB, 0), AbStep.loop);
    });

    test('指定回数を再生し終えたら finish', () {
      expect(nextAbStep(ab, atB, 3), AbStep.loop); // 1回目終了
      expect(nextAbStep(ab.copyWith(passes: 1), atB, 3), AbStep.loop);
      expect(nextAbStep(ab.copyWith(passes: 2), atB, 3), AbStep.finish);
    });
  });

  group('区間の保存', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('保存・読み込みできる', () async {
      final s = await SettingsStore.load();
      await s.saveBookmarks(const [
        AbBookmark(
          id: '1',
          trackPath: '/a.mp3',
          a: Duration(seconds: 1),
          b: Duration(seconds: 5),
          label: '早口',
        ),
      ]);
      final list = (await SettingsStore.load()).bookmarks;
      expect(list, hasLength(1));
      expect(list.single.trackPath, '/a.mp3');
      expect(list.single.b, const Duration(seconds: 5));
      expect(list.single.label, '早口');
    });

    test('壊れたデータや不正な区間は読み飛ばす', () async {
      SharedPreferences.setMockInitialValues({
        'bookmarks':
            '[{"id":"1","track":"/a.mp3","a":5000,"b":1000},'
            '{"id":"2","track":"/a.mp3","a":0,"b":1000},"x"]',
      });
      final list = (await SettingsStore.load()).bookmarks;
      expect(list.map((b) => b.id), ['2']);

      SharedPreferences.setMockInitialValues({'bookmarks': '{oops'});
      expect((await SettingsStore.load()).bookmarks, isEmpty);
    });

    test('繰り返し設定の既定値と範囲外の値の丸め', () async {
      final s = await SettingsStore.load();
      expect(s.abRepeat.count, 0);
      expect(s.abRepeat.gap, Duration.zero);

      SharedPreferences.setMockInitialValues({
        'ab.count': -3,
        'ab.gapMs': 999999,
      });
      final r = (await SettingsStore.load()).abRepeat;
      expect(r.count, 0);
      expect(r.gap, AbRepeatSettings.maxGap);
    });
  });
}

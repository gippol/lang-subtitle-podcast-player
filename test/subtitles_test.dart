import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lang_player/data/subtitles.dart';
import 'package:path/path.dart' as p;

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  group('parseLrc', () {
    test('時刻・メタ情報・複数タイムスタンプ・単語タイムスタンプ', () {
      final cues = parseLrc('''
[ti:Lesson 1]
[ar:Someone]
[00:01.50]Hello.
[00:05.00][00:20.5]Repeat <00:05.50>this.
[00:10.123]How are you?
''');
      expect(cues.map((c) => c.start), [
        ms(1500),
        ms(5000),
        ms(10123),
        ms(20500),
      ]);
      expect(cues.map((c) => c.text), [
        'Hello.',
        'Repeat this.',
        'How are you?',
        'Repeat this.',
      ]);
    });

    test('offset (正の値で早める) と空行による終わり', () {
      final cues = parseLrc('''
[offset:+500]
[00:02.00]One
[00:04.00]
[00:06.00]Two
''');
      expect(cues, hasLength(2));
      expect(cues[0].start, ms(1500));
      expect(cues[0].end, ms(3500));
      expect(cues[1].start, ms(5500));
      expect(cues[1].end, isNull);
    });

    test('時刻の無い行しかなければ空', () {
      expect(parseLrc('just text\n[ar:x]'), isEmpty);
    });
  });

  group('parseSrt', () {
    test('CRLF・複数行・タグ・番号', () {
      const srt =
          '1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i>\r\nworld\r\n\r\n'
          '2\r\n00:00:04.000 --> 00:00:06,000\r\n{\\an8}Bye\r\n';
      final cues = parseSrt(srt);
      expect(cues, hasLength(2));
      expect(cues[0].start, ms(1000));
      expect(cues[0].end, ms(3500));
      expect(cues[0].text, 'Hello\nworld');
      expect(cues[1].text, 'Bye');
    });

    test('終わりが始まり以前の行は捨てる', () {
      expect(parseSrt('1\n00:00:05,000 --> 00:00:01,000\nbad\n'), isEmpty);
    });
  });

  group('Subtitles', () {
    final subs = Subtitles(
      cues: parseLrc('[00:01.00]a\n[00:03.00]b\n[00:05.00]c'),
      source: SubtitleSource.sidecar,
      fileName: 'x.lrc',
    );

    test('indexAt', () {
      expect(subs.indexAt(ms(0)), -1);
      expect(subs.indexAt(ms(1000)), 0);
      expect(subs.indexAt(ms(4999)), 1);
      expect(subs.indexAt(ms(99999)), 2);
    });

    test('endOf は次の行の始まり、最終行は null', () {
      expect(subs.endOf(0), ms(3000));
      expect(subs.endOf(2), isNull);
    });
  });

  group('decodeSubtitleBytes', () {
    test('UTF-8 (BOM あり/なし)', () {
      final body = utf8.encode('[00:01.00]こんにちは');
      expect(
        decodeSubtitleBytes(Uint8List.fromList(body)).text,
        '[00:01.00]こんにちは',
      );
      final r = decodeSubtitleBytes(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]),
      );
      expect(r.text, '[00:01.00]こんにちは');
      expect(r.garbled, isFalse);
    });

    test('UTF-16LE (BOM あり)', () {
      final units = 'あa'.codeUnits;
      final bytes = [0xFF, 0xFE];
      for (final u in units) {
        bytes.addAll([u & 0xff, u >> 8]);
      }
      expect(decodeSubtitleBytes(Uint8List.fromList(bytes)).text, 'あa');
    });

    test('Shift_JIS 等は garbled', () {
      // 「あ」の Shift_JIS
      final r = decodeSubtitleBytes(Uint8List.fromList([0x82, 0xA0]));
      expect(r.garbled, isTrue);
    });
  });

  group('SubtitleStore', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('subs'));
    tearDown(() => tmp.delete(recursive: true));

    test('keyFor は安定していて曲ごとに違う', () {
      expect(SubtitleStore.keyFor('/a.mp3'), SubtitleStore.keyFor('/a.mp3'));
      expect(
        SubtitleStore.keyFor('/a.mp3'),
        isNot(SubtitleStore.keyFor('/b.mp3')),
      );
      expect(
        SubtitleStore.keyFor('/a.mp3'),
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
    });

    test('同名の字幕を自動で見つけ、手動の字幕を優先する', () async {
      final track = p.join(tmp.path, 'lesson.mp3');
      await File(p.join(tmp.path, 'lesson.srt'))
          .writeAsString('1\n00:00:01,000 --> 00:00:02,000\nside\n');
      final store = SubtitleStore(Directory(p.join(tmp.path, 'manual')));

      var r = await store.load(track);
      expect(r.subtitles?.source, SubtitleSource.sidecar);
      expect(r.subtitles?.cues.single.text, 'side');

      final err = await store.saveManual(
        track,
        'picked.lrc',
        Uint8List.fromList(utf8.encode('[00:01.00]manual')),
      );
      expect(err, isNull);
      r = await store.load(track);
      expect(r.subtitles?.source, SubtitleSource.manual);
      expect(r.subtitles?.cues.single.text, 'manual');

      await store.removeManual(track);
      r = await store.load(track);
      expect(r.subtitles?.source, SubtitleSource.sidecar);
    });

    test('不正なファイルは保存しない', () async {
      final store = SubtitleStore(Directory(p.join(tmp.path, 'manual')));
      expect(
        await store.saveManual('/a.mp3', 'x.txt', Uint8List(0)),
        isNotNull,
      );
      expect(
        await store.saveManual(
          '/a.mp3',
          'x.lrc',
          Uint8List.fromList(utf8.encode('no timestamps')),
        ),
        isNotNull,
      );
      expect(
        await store.saveManual(
          '/a.mp3',
          'x.lrc',
          Uint8List(maxSubtitleBytes + 1),
        ),
        isNotNull,
      );
    });

    test('元の曲が無くなった手動の字幕だけを掃除する', () async {
      final manual = Directory(p.join(tmp.path, 'manual'));
      final store = SubtitleStore(manual);
      final kept = p.join(tmp.path, 'kept.mp3');
      final gone = p.join(tmp.path, 'gone.mp3');
      await File(kept).writeAsString('');
      await File(gone).writeAsString('');
      final lrc = Uint8List.fromList(utf8.encode('[00:01.00]x'));
      expect(await store.saveManual(kept, 'k.lrc', lrc), isNull);
      final srt = Uint8List.fromList(
        utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nx\n'),
      );
      expect(await store.saveManual(gone, 'g.srt', srt), isNull);
      // 曲のパスの記録が無い古いコピーは判断できないので残す
      final legacy = File(p.join(manual.path, '0123456789abcdef.lrc'));
      await legacy.writeAsBytes(lrc);

      await File(gone).delete(); // 削除・移動された
      expect(await store.pruneOrphans(), 1);

      expect((await store.load(kept)).subtitles?.source, SubtitleSource.manual);
      expect((await store.load(gone)).subtitles, isNull);
      expect(await legacy.exists(), isTrue);
      final names = manual.listSync().map((e) => p.basename(e.path)).toSet();
      final goneKey = SubtitleStore.keyFor(gone);
      expect(names.where((n) => n.startsWith(goneKey)), isEmpty);
      expect(await store.pruneOrphans(), 0);
    });

    test('記録の無い古いコピーは読み込んだ時に曲のパスを記録する', () async {
      final manual = Directory(p.join(tmp.path, 'manual'))..createSync();
      final track = p.join(tmp.path, 'old.mp3');
      await File(track).writeAsString('');
      await File(p.join(manual.path, '${SubtitleStore.keyFor(track)}.lrc'))
          .writeAsString('[00:01.00]x');
      final store = SubtitleStore(manual);
      expect((await store.load(track)).subtitles, isNotNull);

      await File(track).delete();
      expect(await store.pruneOrphans(), 1);
      expect(manual.listSync(), isEmpty);
    });

    test('字幕フォルダが無ければ何もしない', () async {
      final store = SubtitleStore(Directory(p.join(tmp.path, 'none')));
      expect(await store.pruneOrphans(), 0);
    });

    test('時刻の無い字幕ファイルはエラーとして返す', () async {
      final track = p.join(tmp.path, 't.mp3');
      await File(p.join(tmp.path, 't.lrc')).writeAsString('hello');
      final r = await SubtitleStore(tmp).load(track);
      expect(r.subtitles, isNull);
      expect(r.error, isNotNull);
    });
  });
}

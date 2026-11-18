import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/player_handler.dart';
import '../data/subtitles.dart';
import '../providers.dart';

/// 再生位置に合わせて字幕を表示する。行をタップするとその行を A-B 区間に。
class SubtitlePanel extends ConsumerStatefulWidget {
  const SubtitlePanel({
    super.key,
    required this.subtitles,
    required this.duration,
  });

  final Subtitles subtitles;

  /// 曲の長さ (最終行の終わりに使う)
  final Duration? duration;

  @override
  ConsumerState<SubtitlePanel> createState() => _SubtitlePanelState();
}

class _SubtitlePanelState extends ConsumerState<SubtitlePanel> {
  /// 指でスクロールした後、自動スクロールを止めておく時間
  static const _manualScrollHold = Duration(seconds: 4);

  late List<GlobalKey> _keys = _makeKeys();
  int _scrolledTo = -1;
  DateTime _userScrolledAt = DateTime.fromMillisecondsSinceEpoch(0);

  List<GlobalKey> _makeKeys() => [
    for (var i = 0; i < widget.subtitles.cues.length; i++) GlobalKey(),
  ];

  @override
  void didUpdateWidget(SubtitlePanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.subtitles, widget.subtitles)) {
      _keys = _makeKeys();
      _scrolledTo = -1;
    }
  }

  void _scrollTo(int index) {
    if (index < 0 || index == _scrolledTo) return;
    if (DateTime.now().difference(_userScrolledAt) < _manualScrollHold) return;
    _scrolledTo = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[index].currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final subs = widget.subtitles;
    // 行が変わった時だけ再描画する
    final current = ref.watch(
      positionProvider.select((v) => subs.indexAt(v.value ?? Duration.zero)),
    );
    final ab = ref.watch(abLoopProvider).value ?? AbLoop.none;
    final scheme = Theme.of(context).colorScheme;
    _scrollTo(current);

    return NotificationListener<UserScrollNotification>(
      onNotification: (_) {
        _userScrolledAt = DateTime.now();
        // 一定時間後、次に行が変わった時に現在行へ戻す
        _scrolledTo = -1;
        return false;
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, cue) in subs.cues.indexed)
              _CueLine(
                key: _keys[i],
                text: cue.text,
                isCurrent: i == current,
                isLooping:
                    ab.isActive &&
                    ab.a == cue.start &&
                    ab.b == (subs.endOf(i) ?? widget.duration),
                color: scheme,
                onTap: () {
                  final end = subs.endOf(i) ?? widget.duration;
                  final handler = ref.read(playerHandlerProvider);
                  if (end == null || end <= cue.start) {
                    handler.seek(cue.start);
                  } else {
                    handler.startAbLoop(cue.start, end);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _CueLine extends StatelessWidget {
  const _CueLine({
    super.key,
    required this.text,
    required this.isCurrent,
    required this.isLooping,
    required this.color,
    required this.onTap,
  });

  final String text;
  final bool isCurrent;
  final bool isLooping;
  final ColorScheme color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: isLooping
            ? BoxDecoration(
                color: color.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: isCurrent ? 18 : 16,
                  height: 1.4,
                  fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  color: isCurrent ? color.onSurface : color.onSurfaceVariant,
                ),
              ),
            ),
            if (isLooping)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Icon(Icons.repeat, size: 16, color: color.primary),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 字幕の設定シート
// ---------------------------------------------------------------------------

Future<void> showSubtitleSheet(BuildContext context, String trackPath) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _SubtitleSheet(trackPath: trackPath),
    );

class _SubtitleSheet extends ConsumerWidget {
  const _SubtitleSheet({required this.trackPath});

  final String trackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final load = ref.watch(subtitlesProvider(trackPath));
    final show = ref.watch(showSubtitlesProvider);
    final scheme = Theme.of(context).colorScheme;
    final subs = load.value?.subtitles;

    final status = switch (load) {
      AsyncData(value: SubtitleLoad(subtitles: final s?)) =>
        '${s.source == SubtitleSource.manual ? '選んだ字幕' : '自動で検出'}: '
            '${s.fileName} (${s.cues.length}行)',
      AsyncData(value: SubtitleLoad(error: final e?)) => e,
      AsyncData() =>
        '字幕が見つかりません。\n'
            '音声と同じフォルダに同じ名前の .lrc / .srt を置くか、'
            '下の「ファイルを選ぶ」から指定してください。',
      AsyncError(:final error) => 'エラー: $error',
      _ => '読み込み中...',
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('字幕', style: Theme.of(context).textTheme.titleMedium),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                status,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            if (subs?.garbled ?? false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '文字化けしている場合は、字幕ファイルを UTF-8 で保存し直してください。',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            SwitchListTile(
              title: const Text('字幕を表示'),
              value: show,
              onChanged: (v) => ref.read(showSubtitlesProvider.notifier).set(v),
            ),
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('ファイルを選ぶ'),
              subtitle: const Text('.lrc / .srt (自動で読めない時はこちら)'),
              onTap: () => _pick(context),
            ),
            if (subs?.source == SubtitleSource.manual)
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('選んだ字幕を外す'),
                onTap: () async {
                  await ref.read(subtitleStoreProvider).removeManual(trackPath);
                  ref.invalidate(subtitlesProvider(trackPath));
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    // ファイル選択中にシートが閉じられても安全なよう、先に取っておく
    final messenger = ScaffoldMessenger.of(context);
    final container = ProviderScope.containerOf(context, listen: false);
    void snack(String m) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));

    final PlatformFile? file;
    try {
      file = await FilePicker.pickFile(type: FileType.any);
    } on Exception catch (e) {
      snack('ファイルを開けませんでした: $e');
      return;
    }
    if (file == null) return;
    if (!isSubtitleFile(file.name)) {
      snack('.lrc か .srt のファイルを選んでください');
      return;
    }
    final length = await file.length();
    if (length != null && length > maxSubtitleBytes) {
      snack('ファイルが大きすぎます (2MB まで)');
      return;
    }
    final error = await container
        .read(subtitleStoreProvider)
        .saveManual(trackPath, file.name, await file.readAsBytes());
    if (error != null) {
      snack(error);
      return;
    }
    container.invalidate(subtitlesProvider(trackPath));
    await container.read(showSubtitlesProvider.notifier).set(true);
    snack('字幕を読み込みました');
  }
}

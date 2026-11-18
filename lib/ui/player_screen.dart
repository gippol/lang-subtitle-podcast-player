import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../audio/player_handler.dart';
import '../data/bookmark.dart';
import '../data/subtitles.dart';
import '../providers.dart';
import 'bookmarks.dart';
import 'sleep_timer.dart';
import 'subtitles_view.dart';
import 'theme.dart';
import 'widgets.dart';

/// 再生画面 (歩きながら操作しやすいよう大きなボタンで構成)。
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static Future<void> open(BuildContext context) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const PlayerScreen()));

  static const speeds = [
    0.5, 0.6, 0.7, 0.75, 0.8, 0.9, 1.0, //
    1.1, 1.2, 1.25, 1.3, 1.5, 1.75, 2.0,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);
    final item = ref.watch(mediaItemProvider).value;
    final state = ref.watch(playbackStateProvider).value ?? PlaybackState();
    final queueLength = ref.watch(queueProvider).value?.length ?? 0;
    final folder = ref.watch(currentFolderProvider).value;
    final ab = ref.watch(abLoopProvider).value ?? AbLoop.none;
    final repeat =
        ref.watch(abRepeatProvider).value ?? const AbRepeatSettings();
    final savedCount = ref
        .watch(bookmarksProvider)
        .where((b) => b.trackPath == item?.id)
        .length;
    final scheme = Theme.of(context).colorScheme;

    if (item == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('再生中の曲はありません')),
      );
    }

    final index = (state.queueIndex ?? 0) + 1;
    final digits = queueLength.toString().length;
    final subtitles = ref.watch(subtitlesProvider(item.id)).value?.subtitles;
    final showSubtitles = ref.watch(showSubtitlesProvider);
    final showPanel = subtitles != null && showSubtitles;

    return Scaffold(
      appBar: AppBar(
        title: Text(folder == null ? '' : '~/${p.basename(folder)}'),
        actions: const [SleepTimerAction()],
      ),
      body: SafeArea(
        child: showPanel
            ? _CompactBody(item: item, subtitles: subtitles)
            : Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(),
                    Text(
                      '${index.toString().padLeft(digits, '0')} / $queueLength',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      item.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    _SeekBar(duration: item.duration, ab: ab),
                    const SizedBox(height: 8),
                    // 区間の保存 / 保存区間 / 繰り返し設定 / 字幕
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _SmallAction(
                          icon: Icons.bookmark_add_outlined,
                          label: '区間を保存',
                          onPressed: ab.isActive
                              ? () => saveCurrentAbLoop(context, ref)
                              : null,
                        ),
                        _SmallAction(
                          icon: Icons.bookmarks_outlined,
                          label: '保存区間 ($savedCount)',
                          onPressed: () =>
                              showTrackBookmarksSheet(context, item.id),
                        ),
                        _SmallAction(
                          icon: Icons.repeat,
                          label: '繰り返し ${abRepeatText(repeat)}',
                          onPressed: () => showAbRepeatSheet(context),
                        ),
                        _SmallAction(
                          icon: Icons.subtitles_off_outlined,
                          label: subtitles == null
                              ? '字幕なし'
                              : (showSubtitles ? '字幕 ON' : '字幕 OFF'),
                          onPressed: () => showSubtitleSheet(context, item.id),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // 1段目: 頭出し / 10秒戻る / 10秒進む
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        RoundButton(
                          icon: Icons.first_page,
                          label: '頭出し',
                          onPressed: handler.restartTrack,
                        ),
                        RoundButton(
                          icon: Icons.replay_10,
                          label: '-10s',
                          onPressed: handler.rewind,
                        ),
                        RoundButton(
                          icon: Icons.forward_10,
                          label: '+10s',
                          onPressed: handler.fastForward,
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    // 2段目: 前 / 再生 / 次
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        RoundButton(
                          icon: Icons.skip_previous,
                          size: 72,
                          tooltip: '前の曲 (3秒以上再生中は曲の頭へ)',
                          onPressed: handler.skipToPrevious,
                        ),
                        RoundButton(
                          icon: state.playing ? Icons.pause : Icons.play_arrow,
                          size: 104,
                          filled: true,
                          tooltip: state.playing ? '一時停止' : '再生',
                          onPressed: state.playing
                              ? handler.pause
                              : handler.play,
                        ),
                        RoundButton(
                          icon: Icons.skip_next,
                          size: 72,
                          tooltip: '次の曲',
                          onPressed: handler.skipToNext,
                        ),
                      ],
                    ),
                    const Spacer(),
                    const Divider(),
                    const SizedBox(height: 16),
                    // 3段目: リピート / シャッフル / 速度 / A-B
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _RepeatButton(mode: state.repeatMode),
                        RoundButton(
                          icon: Icons.shuffle,
                          size: 52,
                          label:
                              state.shuffleMode == AudioServiceShuffleMode.none
                              ? 'OFF'
                              : 'シャッフル',
                          filled:
                              state.shuffleMode != AudioServiceShuffleMode.none,
                          onPressed: () => handler.setShuffleMode(
                            state.shuffleMode == AudioServiceShuffleMode.none
                                ? AudioServiceShuffleMode.all
                                : AudioServiceShuffleMode.none,
                          ),
                        ),
                        RoundButton(
                          text: '${_speedText(state.speed)}x',
                          size: 52,
                          label: '速度',
                          filled: state.speed != 1.0,
                          onPressed: () =>
                              _showSpeedSheet(context, ref, state.speed),
                        ),
                        RoundButton(
                          text: 'A-B',
                          size: 52,
                          label: _abLabel(ab, repeat),
                          filled: ab.a != null,
                          onPressed: handler.cycleAbLoop,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  static String _abLabel(AbLoop ab, AbRepeatSettings repeat) => switch (ab) {
    AbLoop(waiting: true) => '無音…',
    AbLoop(isActive: true) when repeat.count > 0 =>
      '${ab.passes + 1}/${repeat.count}回',
    AbLoop(isActive: true) => '${ab.passes + 1}回目',
    AbLoop(a: _?) => 'B を設定',
    _ => 'A を設定',
  };

  static String _speedText(double s) =>
      s.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');

  static Future<void> _showSpeedSheet(
    BuildContext context,
    WidgetRef ref,
    double current,
  ) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              for (final s in speeds)
                RoundButton(
                  text: _speedText(s),
                  size: 56,
                  filled: s == current,
                  onPressed: () {
                    ref.read(playerHandlerProvider).setSpeed(s);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// アイコン + 小さい文字の控えめなボタン
class _SmallAction extends StatelessWidget {
  const _SmallAction({
    this.icon,
    this.text,
    required this.label,
    required this.onPressed,
    this.selected = false,
  }) : assert(icon != null || text != null);

  final IconData? icon;

  /// アイコンの代わりに表示する短い文字 (例: "A-B", "1.25x")
  final String? text;
  final String label;
  final VoidCallback? onPressed;

  /// ON 状態 (背景を塗る)
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onPressed == null ? scheme.outlineVariant : scheme.primary;
    final fg = selected ? scheme.onPrimary : color;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 28,
              constraints: const BoxConstraints(minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? scheme.primary : null,
                borderRadius: BorderRadius.circular(14),
              ),
              child: icon != null
                  ? Icon(icon, size: 22, color: fg)
                  : Text(
                      text!,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: fg,
                      ),
                    ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 字幕を表示している時の再生画面。操作を2段にまとめて字幕を広く見せる。
class _CompactBody extends ConsumerWidget {
  const _CompactBody({required this.item, required this.subtitles});

  final MediaItem item;
  final Subtitles subtitles;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);
    final state = ref.watch(playbackStateProvider).value ?? PlaybackState();
    final queueLength = ref.watch(queueProvider).value?.length ?? 0;
    final ab = ref.watch(abLoopProvider).value ?? AbLoop.none;
    final repeat =
        ref.watch(abRepeatProvider).value ?? const AbRepeatSettings();
    final scheme = Theme.of(context).colorScheme;
    final index = (state.queueIndex ?? 0) + 1;
    final digits = queueLength.toString().length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text:
                      '${index.toString().padLeft(digits, '0')}/$queueLength  ',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                TextSpan(text: item.title),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: SubtitlePanel(subtitles: subtitles, duration: item.duration),
          ),
          _SeekBar(duration: item.duration, ab: ab),
          const SizedBox(height: 4),
          // -10s / 前 / 再生 / 次 / +10s
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              RoundButton(
                icon: Icons.replay_10,
                size: 48,
                tooltip: '10秒戻る',
                onPressed: handler.rewind,
              ),
              RoundButton(
                icon: Icons.skip_previous,
                size: 48,
                tooltip: '前の曲 (3秒以上再生中は曲の頭へ)',
                onPressed: handler.skipToPrevious,
              ),
              RoundButton(
                icon: state.playing ? Icons.pause : Icons.play_arrow,
                size: 64,
                filled: true,
                tooltip: state.playing ? '一時停止' : '再生',
                onPressed: state.playing ? handler.pause : handler.play,
              ),
              RoundButton(
                icon: Icons.skip_next,
                size: 48,
                tooltip: '次の曲',
                onPressed: handler.skipToNext,
              ),
              RoundButton(
                icon: Icons.forward_10,
                size: 48,
                tooltip: '10秒進む',
                onPressed: handler.fastForward,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // A-B / 速度 / 区間を保存 / 繰り返し設定 / その他
          // 狭い画面でもはみ出さないよう等幅で並べる
          Row(
            children: [
              for (final action in [
                _SmallAction(
                  text: 'A-B',
                  label: PlayerScreen._abLabel(ab, repeat),
                  selected: ab.a != null,
                  onPressed: handler.cycleAbLoop,
                ),
                _SmallAction(
                  text: '${PlayerScreen._speedText(state.speed)}x',
                  label: '速度',
                  selected: state.speed != 1.0,
                  onPressed: () =>
                      PlayerScreen._showSpeedSheet(context, ref, state.speed),
                ),
                _SmallAction(
                  icon: Icons.bookmark_add_outlined,
                  label: '区間を保存',
                  onPressed: ab.isActive
                      ? () => saveCurrentAbLoop(context, ref)
                      : null,
                ),
                _SmallAction(
                  icon: Icons.tune,
                  label: abRepeatText(repeat),
                  onPressed: () => showAbRepeatSheet(context),
                ),
                _SmallAction(
                  icon: Icons.more_horiz,
                  label: 'その他',
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => _MoreSheet(trackPath: item.id),
                  ),
                ),
              ])
                Expanded(child: action),
            ],
          ),
        ],
      ),
    );
  }
}

/// コンパクト表示で入りきらない操作 (リピート / シャッフル / 保存区間 / 字幕)
class _MoreSheet extends ConsumerWidget {
  const _MoreSheet({required this.trackPath});

  final String trackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);
    final state = ref.watch(playbackStateProvider).value ?? PlaybackState();
    final savedCount = ref
        .watch(bookmarksProvider)
        .where((b) => b.trackPath == trackPath)
        .length;
    final shuffleOn = state.shuffleMode != AudioServiceShuffleMode.none;
    final (repeatIcon, repeatText, nextRepeat) = _RepeatButton.describe(
      state.repeatMode,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(repeatIcon),
              title: const Text('リピート'),
              trailing: Text(repeatText),
              onTap: () => handler.setRepeatMode(nextRepeat),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.shuffle),
              title: const Text('シャッフル'),
              value: shuffleOn,
              onChanged: (v) => handler.setShuffleMode(
                v ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.bookmarks_outlined),
              title: Text('この曲の保存区間 ($savedCount)'),
              onTap: () {
                Navigator.pop(context);
                showTrackBookmarksSheet(context, trackPath);
              },
            ),
            ListTile(
              leading: const Icon(Icons.subtitles),
              title: const Text('字幕の設定'),
              onTap: () {
                Navigator.pop(context);
                showSubtitleSheet(context, trackPath);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// OFF → 全曲 → 1曲 → OFF ... と切り替える
class _RepeatButton extends ConsumerWidget {
  const _RepeatButton({required this.mode});

  final AudioServiceRepeatMode mode;

  /// (アイコン, 表示, 次のモード)
  static (IconData, String, AudioServiceRepeatMode) describe(
    AudioServiceRepeatMode mode,
  ) => switch (mode) {
    AudioServiceRepeatMode.none => (
      Icons.repeat,
      'OFF',
      AudioServiceRepeatMode.all,
    ),
    AudioServiceRepeatMode.one => (
      Icons.repeat_one,
      '1曲',
      AudioServiceRepeatMode.none,
    ),
    _ => (Icons.repeat, '全曲', AudioServiceRepeatMode.one),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (icon, label, next) = describe(mode);
    return RoundButton(
      icon: icon,
      size: 52,
      label: label,
      filled: mode != AudioServiceRepeatMode.none,
      onPressed: () => ref.read(playerHandlerProvider).setRepeatMode(next),
    );
  }
}

/// シークバー (A-B 区間を背景に表示)
class _SeekBar extends ConsumerStatefulWidget {
  const _SeekBar({required this.duration, required this.ab});

  final Duration? duration;
  final AbLoop ab;

  @override
  ConsumerState<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<_SeekBar> {
  /// ドラッグ中の値 (ms)。ドラッグしていない時は null
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final maxMs = (widget.duration?.inMilliseconds ?? 0).toDouble();
    final value = (_dragValue ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      maxMs,
    );
    final ab = widget.ab;

    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _AbPainter(
                    a: ab.a,
                    b: ab.b,
                    duration: widget.duration,
                    color: scheme.primary,
                  ),
                ),
              ),
              Slider(
                value: value,
                max: maxMs > 0 ? maxMs : 1,
                onChanged: maxMs > 0
                    ? (v) => setState(() => _dragValue = v)
                    : null,
                onChangeEnd: (v) {
                  ref
                      .read(playerHandlerProvider)
                      .seek(Duration(milliseconds: v.round()));
                  setState(() => _dragValue = null);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kSliderPadding),
          child: Row(
            children: [
              Text(formatDuration(Duration(milliseconds: value.round()))),
              Expanded(
                child: Text(
                  ab.a == null
                      ? ''
                      : 'A ${formatDuration(ab.a)}'
                            '${ab.b == null ? '' : ' - B ${formatDuration(ab.b)}'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Text(formatDuration(widget.duration)),
            ],
          ),
        ),
      ],
    );
  }
}

class _AbPainter extends CustomPainter {
  _AbPainter({
    required this.a,
    required this.b,
    required this.duration,
    required this.color,
  });

  final Duration? a;
  final Duration? b;
  final Duration? duration;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final total = duration?.inMilliseconds ?? 0;
    if (a == null || total <= 0) return;
    final width = size.width - kSliderPadding * 2;
    double x(Duration d) =>
        kSliderPadding + width * (d.inMilliseconds / total).clamp(0.0, 1.0);
    final cy = size.height / 2;
    final line = Paint()
      ..color = color
      ..strokeWidth = 2;

    final ax = x(a!);
    canvas.drawLine(Offset(ax, cy - 10), Offset(ax, cy + 10), line);
    if (b != null) {
      final bx = x(b!);
      canvas.drawLine(Offset(bx, cy - 10), Offset(bx, cy + 10), line);
      canvas.drawRect(
        Rect.fromLTRB(ax, cy - 6, bx, cy + 6),
        Paint()..color = color.withValues(alpha: 0.2),
      );
    }
  }

  @override
  bool shouldRepaint(_AbPainter old) =>
      old.a != a ||
      old.b != b ||
      old.duration != duration ||
      old.color != color;
}

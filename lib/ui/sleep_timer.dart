import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/player_handler.dart';
import '../providers.dart';
import 'widgets.dart';

/// タイマーの選択肢 (分)
const sleepMinutesOptions = [5, 15, 30, 45, 60, 90];

/// 残り時間の表示 (切り上げ。残り 0.4秒を "00:00" と出さないため)
String formatSleepRemaining(Duration d) =>
    formatDuration(Duration(seconds: (d.inMilliseconds / 1000).ceil()));

/// AppBar に置くタイマーボタン。動いている間は残り時間を表示する。
class SleepTimerAction extends ConsumerWidget {
  const SleepTimerAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timer = ref.watch(sleepTimerProvider).value ?? SleepTimer.off;
    final remaining = ref.watch(sleepRemainingProvider).value;
    final scheme = Theme.of(context).colorScheme;

    if (!timer.isActive) {
      return IconButton(
        icon: const Icon(Icons.bedtime_outlined),
        tooltip: 'スリープタイマー',
        onPressed: () => showSleepTimerSheet(context),
      );
    }
    return TextButton.icon(
      icon: Icon(Icons.bedtime, color: scheme.primary),
      label: Text(
        timer.endOfTrack
            ? '曲の終わり'
            : formatSleepRemaining(remaining ?? Duration.zero),
        style: TextStyle(
          color: scheme.primary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      onPressed: () => showSleepTimerSheet(context),
    );
  }
}

Future<void> showSleepTimerSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _SleepTimerSheet(),
    );

class _SleepTimerSheet extends ConsumerWidget {
  const _SleepTimerSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);
    final timer = ref.watch(sleepTimerProvider).value ?? SleepTimer.off;
    final remaining = ref.watch(sleepRemainingProvider).value;
    final scheme = Theme.of(context).colorScheme;

    final status = switch (timer) {
      SleepTimer(endOfTrack: true) => 'この曲が終わったら停止します',
      SleepTimer(isActive: true) =>
        'あと ${formatSleepRemaining(remaining ?? Duration.zero)} で停止します',
      _ => '指定した時間がたつと、音量を下げてから停止します',
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('スリープタイマー', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(status, style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final m in sleepMinutesOptions)
                  RoundButton(
                    text: '$m分',
                    size: 56,
                    onPressed: () {
                      handler.setSleepTimer(Duration(minutes: m));
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.music_off_outlined),
              label: const Text('この曲が終わったら'),
              onPressed: () {
                handler.setSleepAtEndOfTrack();
                Navigator.pop(context);
              },
            ),
            if (timer.isActive) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('タイマーを解除'),
                onPressed: () {
                  handler.cancelSleepTimer();
                  Navigator.pop(context);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

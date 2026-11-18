import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 画面下部に常に表示する小さなプレーヤー。タップで再生画面を開く。
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(mediaItemProvider).value;
    if (item == null) return const SizedBox.shrink();

    final handler = ref.read(playerHandlerProvider);
    final playing = ref.watch(
      playbackStateProvider.select((s) => s.value?.playing ?? false),
    );
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = item.duration;
    final progress = (duration == null || duration == Duration.zero)
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surface,
      child: InkWell(
        onTap: () => PlayerScreen.open(context),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress, minHeight: 2),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${formatDuration(position)} / '
                            '${formatDuration(duration)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    RoundButton(
                      icon: Icons.skip_previous,
                      size: 44,
                      tooltip: '前へ',
                      onPressed: handler.skipToPrevious,
                    ),
                    const SizedBox(width: 8),
                    RoundButton(
                      icon: playing ? Icons.pause : Icons.play_arrow,
                      size: 52,
                      filled: true,
                      tooltip: playing ? '一時停止' : '再生',
                      onPressed: playing ? handler.pause : handler.play,
                    ),
                    const SizedBox(width: 8),
                    RoundButton(
                      icon: Icons.skip_next,
                      size: 44,
                      tooltip: '次へ',
                      onPressed: handler.skipToNext,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

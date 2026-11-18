import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../audio/player_handler.dart';
import '../data/audio_library.dart';
import '../data/bookmark.dart';
import '../providers.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 区間の表示名 (名前が無ければ時刻)。
String bookmarkTitle(AbBookmark b) => b.label.isNotEmpty
    ? b.label
    : '${formatDuration(b.a)} - ${formatDuration(b.b)}';

String _repeatCountText(int count) => count == 0 ? '∞' : '$count回';

String _gapText(Duration gap) => '${gap.inSeconds}秒';

/// 繰り返し設定の短い表示 (例: "3回・2秒")
String abRepeatText(AbRepeatSettings s) =>
    '${_repeatCountText(s.count)}・${_gapText(s.gap)}';

/// 保存した区間を再生する。別の曲ならその曲のフォルダを読み込んでから。
/// ファイルが見つからなければ false。
Future<bool> playBookmark(WidgetRef ref, AbBookmark b) async {
  final handler = ref.read(playerHandlerProvider);
  if (handler.mediaItem.value?.id == b.trackPath) {
    await handler.startAbLoop(b.a, b.b);
    return true;
  }
  final folder = p.dirname(b.trackPath);
  final FolderContents contents;
  try {
    contents = await ref.read(audioLibraryProvider).list(folder);
  } on Exception {
    return false;
  }
  final index = contents.tracks.indexOf(b.trackPath);
  if (index < 0) return false;
  await handler.playFolder(
    folder,
    contents.tracks,
    startIndex: index,
    startPosition: b.a,
    abLoop: AbLoop(a: b.a, b: b.b),
  );
  return true;
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 再生中の A-B 区間を保存する。
Future<void> saveCurrentAbLoop(BuildContext context, WidgetRef ref) async {
  final handler = ref.read(playerHandlerProvider);
  final ab = handler.abLoop.value;
  final track = handler.mediaItem.value?.id;
  if (!ab.isActive || track == null) return;
  // 字幕の行から作った区間なら、その文を名前にする
  final cues = ref.read(subtitlesProvider(track)).value?.subtitles?.cues;
  final cue = cues?.where((c) => c.start == ab.a).firstOrNull;
  final label = cue == null
      ? ''
      : cue.text.replaceAll('\n', ' ').characters.take(100).toString();
  final added = await ref
      .read(bookmarksProvider.notifier)
      .add(track, ab.a!, ab.b!, label: label);
  if (context.mounted) {
    _showSnack(context, added ? '区間を保存しました' : 'この区間は保存済みです');
  }
}

// ---------------------------------------------------------------------------
// 繰り返し設定
// ---------------------------------------------------------------------------

Future<void> showAbRepeatSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => const _AbRepeatSheet(),
    );

class _AbRepeatSheet extends ConsumerWidget {
  const _AbRepeatSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);
    final current =
        ref.watch(abRepeatProvider).value ?? const AbRepeatSettings();
    final scheme = Theme.of(context).colorScheme;

    Widget section(String title, String note, List<Widget> buttons) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          note,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: buttons),
      ],
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            section('繰り返す回数', '指定回数を再生したら区間を解除して先へ進みます', [
              for (final c in AbRepeatSettings.countOptions)
                RoundButton(
                  text: _repeatCountText(c),
                  size: 52,
                  filled: c == current.count,
                  onPressed: () => handler.setAbRepeat(
                    AbRepeatSettings(count: c, gap: current.gap),
                  ),
                ),
            ]),
            const SizedBox(height: 24),
            section('間の無音', '1回ごとに一時停止して、声に出す時間を作ります', [
              for (final g in AbRepeatSettings.gapOptions)
                RoundButton(
                  text: _gapText(g),
                  size: 52,
                  filled: g == current.gap,
                  onPressed: () => handler.setAbRepeat(
                    AbRepeatSettings(count: current.count, gap: g),
                  ),
                ),
            ]),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 再生中の曲の保存区間 (再生画面から開くシート)
// ---------------------------------------------------------------------------

Future<void> showTrackBookmarksSheet(BuildContext context, String trackPath) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TrackBookmarksSheet(trackPath: trackPath),
    );

class _TrackBookmarksSheet extends ConsumerWidget {
  const _TrackBookmarksSheet({required this.trackPath});

  final String trackPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = [
      for (final b in ref.watch(bookmarksProvider))
        if (b.trackPath == trackPath) b,
    ]..sort((x, y) => x.a.compareTo(y.a));
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                'この曲の保存区間',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Text(
                  'まだありません。\nA-B で区間を作って「区間を保存」を押してください。',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in list)
                      _BookmarkTile(
                        bookmark: b,
                        onTap: () {
                          ref.read(playerHandlerProvider).startAbLoop(b.a, b.b);
                          Navigator.pop(context);
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 全曲の保存区間 (復習リスト)
// ---------------------------------------------------------------------------

class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => const BookmarksScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(audioLibraryProvider);
    final scheme = Theme.of(context).colorScheme;

    // 曲ごとにまとめ、フォルダ → ファイル名 → 開始位置 の順に並べる
    final byTrack = <String, List<AbBookmark>>{};
    for (final b in ref.watch(bookmarksProvider)) {
      (byTrack[b.trackPath] ??= []).add(b);
    }
    final tracks = byTrack.keys.toList()
      ..sort((x, y) {
        final c = naturalCompare(p.dirname(x), p.dirname(y));
        return c != 0 ? c : naturalCompare(p.basename(x), p.basename(y));
      });

    return Scaffold(
      appBar: AppBar(title: const Text('保存した区間')),
      body: tracks.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'まだありません。\n'
                '再生画面で A-B 区間を作り「区間を保存」を押すと、ここに集まります。',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            )
          : ListView(
              children: [
                for (final track in tracks) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Text(
                      p.basenameWithoutExtension(track),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
                    child: Text(
                      '~/${library.displayPath(p.dirname(track))}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final b
                      in byTrack[track]!..sort((x, y) => x.a.compareTo(y.a)))
                    _BookmarkTile(
                      bookmark: b,
                      onTap: () async {
                        final ok = await playBookmark(ref, b);
                        if (!context.mounted) return;
                        if (ok) {
                          await PlayerScreen.open(context);
                        } else {
                          _showSnack(context, 'ファイルが見つかりません (移動・削除された可能性)');
                        }
                      },
                    ),
                  const Divider(),
                ],
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// 共通部品
// ---------------------------------------------------------------------------

class _BookmarkTile extends ConsumerWidget {
  const _BookmarkTile({required this.bookmark, required this.onTap});

  final AbBookmark bookmark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = bookmark;
    final length = b.b - b.a;
    return ListTile(
      leading: const Icon(Icons.repeat),
      title: Text(
        bookmarkTitle(b),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        b.label.isEmpty
            ? '${length.inSeconds}秒'
            : '${formatDuration(b.a)} - ${formatDuration(b.b)}'
                  ' (${length.inSeconds}秒)',
      ),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        onSelected: (action) async {
          final notifier = ref.read(bookmarksProvider.notifier);
          if (action == 'delete') {
            await notifier.remove(b.id);
          } else {
            final label = await showDialog<String>(
              context: context,
              builder: (_) => _RenameDialog(initial: b.label),
            );
            if (label != null) await notifier.rename(b.id, label);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('名前を変更')),
          PopupMenuItem(value: 'delete', child: Text('削除')),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('区間の名前'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(hintText: '例: 早口の部分'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

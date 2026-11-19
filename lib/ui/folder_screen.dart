import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../data/audio_library.dart';
import '../providers.dart';
import 'bookmarks.dart';
import 'mini_player.dart';
import 'player_screen.dart';
import 'widgets.dart';

/// 起動画面: 権限とルートフォルダを確認してからフォルダ一覧を表示する。
class RootScreen extends ConsumerWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 前回の続きを読み込む (結果は使わないので watch するだけ)
    ref.watch(restoreSessionProvider);
    ref.watch(subtitleCleanupProvider);

    final library = ref.watch(audioLibraryProvider);
    final permission = ref.watch(storagePermissionProvider);
    final rootReady = ref.watch(rootReadyProvider);

    return switch ((permission, rootReady)) {
      (AsyncData(value: false), _) => _MessageScreen(
        message: '音声ファイルを読み込むため\nオーディオへのアクセスを許可してください。',
        actionLabel: '許可する',
        onAction: () => ref.read(storagePermissionProvider.notifier).request(),
      ),
      (_, AsyncData(value: false)) => _MessageScreen(
        message:
            'ルートフォルダを作成できませんでした。\n'
            'ファイルアプリ等で次のフォルダを作成してください。\n\n'
            '${library.rootPath}',
        actionLabel: '再確認',
        onAction: () => ref.invalidate(rootReadyProvider),
      ),
      (_, AsyncData(value: true)) => FolderScreen(path: library.rootPath),
      (AsyncError(:final error), _) ||
      (_, AsyncError(:final error)) => _MessageScreen(message: 'エラー: $error'),
      _ => const Scaffold(body: Center(child: Text('loading...'))),
    };
  }
}

/// フォルダの中身 (サブフォルダ + 音声ファイル) を表示する。
class FolderScreen extends ConsumerWidget {
  const FolderScreen({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(audioLibraryProvider);
    final contents = ref.watch(folderContentsProvider(path));
    final tracks = contents.value?.tracks ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(
          '~/${library.displayPath(path)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '保存した区間',
            onPressed: () => BookmarksScreen.open(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(folderContentsProvider(path).future),
        child: switch (contents) {
          AsyncData(:final value) => _FolderList(path: path, contents: value),
          AsyncError(:final error) => ListView(
            children: [ListTile(title: Text('読み込みエラー: $error'))],
          ),
          _ => const Center(child: Text('loading...')),
        },
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tracks.isNotEmpty) _PlayAllBar(path: path, tracks: tracks),
          const Divider(),
          const MiniPlayer(),
        ],
      ),
    );
  }
}

class _FolderList extends ConsumerWidget {
  const _FolderList({required this.path, required this.contents});

  final String path;
  final FolderContents contents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final currentId = ref.watch(mediaItemProvider).value?.id;
    final store = ref.watch(settingsStoreProvider);

    if (contents.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '(empty)\n\nこのフォルダに音声ファイル(mp3, m4a, aac, wav, '
            'ogg, opus, flac)やサブフォルダをコピーしてください。\n'
            '下に引っ張ると再読み込みします。',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${contents.folders.length} dirs, ${contents.tracks.length} files',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        for (final folder in contents.folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text('${p.basename(folder)}/'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FolderScreen(path: folder),
              ),
            ),
          ),
        for (final (i, track) in contents.tracks.indexed)
          _TrackTile(
            path: track,
            isCurrent: track == currentId,
            savedPosition: store.positionFor(track),
            onTap: () async {
              await ref
                  .read(playerHandlerProvider)
                  .playFolder(path, contents.tracks, startIndex: i);
              if (context.mounted) PlayerScreen.open(context);
            },
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.path,
    required this.isCurrent,
    required this.savedPosition,
    required this.onTap,
  });

  final String path;
  final bool isCurrent;
  final Duration? savedPosition;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        isCurrent ? Icons.play_arrow : Icons.music_note_outlined,
        color: isCurrent ? scheme.primary : null,
      ),
      title: Text(
        p.basename(path),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: savedPosition == null
          ? null
          : Text(
              'resume @ ${formatDuration(savedPosition)}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
      onTap: onTap,
    );
  }
}

/// 「順番再生」「シャッフル再生」ボタン
class _PlayAllBar extends ConsumerWidget {
  const _PlayAllBar({required this.path, required this.tracks});

  final String path;
  final List<String> tracks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final handler = ref.read(playerHandlerProvider);

    Future<void> start({required bool shuffle}) async {
      await handler.playFolder(
        path,
        tracks,
        startIndex: shuffle ? null : 0,
        shuffle: shuffle,
        resume: false,
      );
      if (context.mounted) PlayerScreen.open(context);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _PillButton(
              icon: Icons.play_arrow,
              label: '順番再生',
              onPressed: () => start(shuffle: false),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _PillButton(
              icon: Icons.shuffle,
              label: 'シャッフル',
              onPressed: () => start(shuffle: true),
            ),
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        side: BorderSide(color: scheme.primary, width: 1.5),
        shape: const StadiumBorder(),
        minimumSize: const Size.fromHeight(48),
      ),
    );
  }
}

class _MessageScreen extends StatelessWidget {
  const _MessageScreen({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('~/LangPlayer')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            if (actionLabel != null) ...[
              const SizedBox(height: 24),
              _PillButton(
                icon: Icons.chevron_right,
                label: actionLabel!,
                onPressed: onAction!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

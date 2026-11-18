import 'package:audio_service/audio_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';

import 'audio/player_handler.dart';
import 'data/audio_library.dart';
import 'data/bookmark.dart';
import 'data/settings_store.dart';
import 'data/subtitles.dart';

// ---------------------------------------------------------------------------
// 依存オブジェクト (main.dart で overrideWithValue して注入する)
// ---------------------------------------------------------------------------

final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw UnimplementedError('main.dart で override する'),
);

final playerHandlerProvider = Provider<PlayerHandler>(
  (ref) => throw UnimplementedError('main.dart で override する'),
);

final subtitleStoreProvider = Provider<SubtitleStore>(
  (ref) => throw UnimplementedError('main.dart で override する'),
);

final audioLibraryProvider = Provider<AudioLibrary>(
  (ref) => AudioLibrary(rootPath: AudioLibrary.defaultRootPath),
);

// ---------------------------------------------------------------------------
// ストレージ権限 (AsyncNotifier の例)
// ---------------------------------------------------------------------------

class StoragePermissionNotifier extends AsyncNotifier<bool> {
  Future<Permission> _permission() async {
    final info = await DeviceInfoPlugin().androidInfo;
    // Android 13 (API 33) 以降は READ_MEDIA_AUDIO、それ以前は READ_EXTERNAL_STORAGE
    return info.version.sdkInt >= 33 ? Permission.audio : Permission.storage;
  }

  @override
  Future<bool> build() async => (await _permission()).isGranted;

  Future<void> request() async {
    final permission = await _permission();
    final status = await permission.request();
    if (status.isPermanentlyDenied) await openAppSettings();
    state = AsyncData(status.isGranted);
  }
}

final storagePermissionProvider =
    AsyncNotifierProvider<StoragePermissionNotifier, bool>(
      StoragePermissionNotifier.new,
    );

// ---------------------------------------------------------------------------
// ライブラリ
// ---------------------------------------------------------------------------

/// ルートフォルダの準備 (無ければ作成)。作成できなければ false。
final rootReadyProvider = FutureProvider<bool>((ref) async {
  final granted = await ref.watch(storagePermissionProvider.future);
  if (!granted) return false;
  return ref.watch(audioLibraryProvider).ensureRoot();
});

/// 指定フォルダの中身。画面を閉じたら破棄し、次回は読み直す。
final folderContentsProvider = FutureProvider.autoDispose
    .family<FolderContents, String>((ref, path) {
      return ref.watch(audioLibraryProvider).list(path);
    });

/// 起動時に前回の続き (一時停止状態) を読み込む。
final restoreSessionProvider = FutureProvider<void>((ref) async {
  final ready = await ref.watch(rootReadyProvider.future);
  if (!ready) return;
  final handler = ref.read(playerHandlerProvider);
  if (handler.queue.value.isNotEmpty) return;
  final session = ref.read(settingsStoreProvider).lastSession;
  if (session == null) return;
  try {
    final contents = await ref.read(audioLibraryProvider).list(session.folder);
    final index = contents.tracks.indexOf(session.trackPath);
    if (index < 0) return;
    await handler.playFolder(
      session.folder,
      contents.tracks,
      startIndex: index,
      startPosition: session.position,
      autoplay: false,
    );
  } on Exception {
    // フォルダが消えている等。何もしない
  }
});

// ---------------------------------------------------------------------------
// 再生状態 (audio_service のストリームを StreamProvider で公開)
// ---------------------------------------------------------------------------

final playbackStateProvider = StreamProvider<PlaybackState>(
  (ref) => ref.watch(playerHandlerProvider).playbackState,
);

final mediaItemProvider = StreamProvider<MediaItem?>(
  (ref) => ref.watch(playerHandlerProvider).mediaItem,
);

final queueProvider = StreamProvider<List<MediaItem>>(
  (ref) => ref.watch(playerHandlerProvider).queue,
);

final positionProvider = StreamProvider<Duration>(
  (ref) => ref.watch(playerHandlerProvider).positionStream,
);

final abLoopProvider = StreamProvider<AbLoop>(
  (ref) => ref.watch(playerHandlerProvider).abLoop,
);

final currentFolderProvider = StreamProvider<String?>(
  (ref) => ref.watch(playerHandlerProvider).currentFolder,
);

final abRepeatProvider = StreamProvider<AbRepeatSettings>(
  (ref) => ref.watch(playerHandlerProvider).abRepeat,
);

// ---------------------------------------------------------------------------
// 保存した区間
// ---------------------------------------------------------------------------

class BookmarksNotifier extends Notifier<List<AbBookmark>> {
  @override
  List<AbBookmark> build() => ref.read(settingsStoreProvider).bookmarks;

  Future<void> _save(List<AbBookmark> list) async {
    state = list;
    await ref.read(settingsStoreProvider).saveBookmarks(list);
  }

  /// 同じ曲・同じ区間が既にあれば追加しない。追加したら true。
  Future<bool> add(
    String trackPath,
    Duration a,
    Duration b, {
    String label = '',
  }) async {
    final dup = state.any(
      (x) => x.trackPath == trackPath && x.a == a && x.b == b,
    );
    if (dup) return false;
    await _save([
      ...state,
      AbBookmark(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        trackPath: trackPath,
        a: a,
        b: b,
        label: label,
      ),
    ]);
    return true;
  }

  Future<void> rename(String id, String label) => _save([
    for (final x in state) x.id == id ? x.copyWith(label: label.trim()) : x,
  ]);

  Future<void> remove(String id) => _save([
    for (final x in state)
      if (x.id != id) x,
  ]);
}

final bookmarksProvider = NotifierProvider<BookmarksNotifier, List<AbBookmark>>(
  BookmarksNotifier.new,
);

// ---------------------------------------------------------------------------
// 字幕
// ---------------------------------------------------------------------------

/// 曲ごとの字幕。字幕を選び直したら invalidate する。
final subtitlesProvider = FutureProvider.autoDispose
    .family<SubtitleLoad, String>(
      (ref, trackPath) => ref.watch(subtitleStoreProvider).load(trackPath),
    );

class ShowSubtitlesNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(settingsStoreProvider).showSubtitles;

  Future<void> set(bool v) async {
    state = v;
    await ref.read(settingsStoreProvider).setShowSubtitles(v);
  }
}

final showSubtitlesProvider = NotifierProvider<ShowSubtitlesNotifier, bool>(
  ShowSubtitlesNotifier.new,
);

// ---------------------------------------------------------------------------
// スリープタイマー
// ---------------------------------------------------------------------------

final sleepTimerProvider = StreamProvider<SleepTimer>(
  (ref) => ref.watch(playerHandlerProvider).sleepTimer,
);

/// 停止までの残り時間 (1秒ごとに更新)。時刻指定のタイマーでなければ null。
final sleepRemainingProvider = StreamProvider.autoDispose<Duration?>((ref) {
  final timer = ref.watch(sleepTimerProvider).value ?? SleepTimer.off;
  if (timer.endsAt == null) return Stream.value(null);
  Duration? left() => timer.remaining(DateTime.now());
  return Stream.periodic(
    const Duration(seconds: 1),
    (_) => left(),
  ).startWith(left());
});

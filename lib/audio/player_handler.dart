import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';

import '../data/bookmark.dart';
import '../data/settings_store.dart';

/// A-B 区間リピートの状態。
class AbLoop {
  const AbLoop({this.a, this.b, this.passes = 0, this.waiting = false});

  static const none = AbLoop();

  final Duration? a;
  final Duration? b;

  /// 区間を最後まで再生し終えた回数
  final int passes;

  /// 繰り返しの間の無音で待機中か
  final bool waiting;

  bool get isActive => a != null && b != null;

  AbLoop copyWith({int? passes, bool? waiting}) => AbLoop(
    a: a,
    b: b,
    passes: passes ?? this.passes,
    waiting: waiting ?? this.waiting,
  );
}

/// スリープタイマーの状態。
class SleepTimer {
  const SleepTimer({this.endsAt, this.endOfTrack = false});

  static const off = SleepTimer();

  /// この時刻に停止する
  final DateTime? endsAt;

  /// 再生中の曲が終わったら停止する
  final bool endOfTrack;

  bool get isActive => endsAt != null || endOfTrack;

  /// 停止までの残り時間 (時刻指定でなければ null)
  Duration? remaining(DateTime now) {
    final end = endsAt;
    if (end == null) return null;
    final d = end.difference(now);
    return d.isNegative ? Duration.zero : d;
  }
}

/// B 地点に達した時にすること。
enum AbStep {
  /// まだ B に達していない / 区間が無い
  none,

  /// A に戻ってもう一度
  loop,

  /// 指定回数を終えたので区間を解除してそのまま先へ
  finish,
}

/// [pos] での A-B 区間の次の動作を決める。[count] が 0 なら無制限。
AbStep nextAbStep(AbLoop ab, Duration pos, int count) {
  if (!ab.isActive || pos < ab.b!) return AbStep.none;
  final passes = ab.passes + 1;
  return count > 0 && passes >= count ? AbStep.finish : AbStep.loop;
}

/// バックグラウンド再生の本体。
///
/// audio_service の [BaseAudioHandler] として登録されるので、
/// 通知・ロック画面・イヤホンのボタン操作もここに届く。
class PlayerHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  PlayerHandler(this._store) {
    _init();
  }

  /// 早送り/巻き戻しの秒数
  static const skipInterval = Duration(seconds: 10);

  /// 「前へ」押下時、この時間以上再生していたら曲の頭に戻る
  static const restartThreshold = Duration(seconds: 3);

  /// 曲の最初/最後のこの範囲は「再生位置の記憶」をしない
  static const _resumeMargin = Duration(seconds: 5);

  final SettingsStore _store;
  final _player = AudioPlayer();

  /// A-B 区間リピートの状態
  final abLoop = BehaviorSubject<AbLoop>.seeded(AbLoop.none);

  /// 現在再生中のフォルダ
  final currentFolder = BehaviorSubject<String?>.seeded(null);

  /// スリープタイマー
  final sleepTimer = BehaviorSubject<SleepTimer>.seeded(SleepTimer.off);

  /// スリープタイマーで止める前に音量を下げていく時間
  static const sleepFade = Duration(seconds: 10);

  /// 区間リピートの回し方 (回数・無音)
  late final abRepeat = BehaviorSubject<AbRepeatSettings>.seeded(
    _store.abRepeat,
  );

  /// 再生位置 (UI 用)
  Stream<Duration> get positionStream => _player.positionStream;

  String? _lastPath;
  Duration _lastPosition = Duration.zero;
  Duration? _lastDuration;
  bool _abSeeking = false;
  Timer? _saveTimer;
  Timer? _gapTimer;
  Timer? _sleepTicker;

  /// スリープタイマーの世代。解除・再設定で進め、古いフェードを止める
  int _sleepGen = 0;
  bool _fading = false;

  /// playFolder で開始曲に設定する A-B 区間 (曲の切り替え後に反映)
  ({String path, AbLoop loop})? _pendingAb;

  void _init() {
    Rx.merge([
      _player.playbackEventStream,
      _player.playingStream,
      _player.loopModeStream,
      _player.shuffleModeEnabledStream,
      _player.speedStream,
    ]).listen((_) => _broadcastState());

    _player.currentIndexStream.listen(_onIndexChanged);
    _player.durationStream.listen((d) {
      _lastDuration = d;
      final item = mediaItem.value;
      if (item != null && d != null && item.duration != d) {
        mediaItem.add(item.copyWith(duration: d));
      }
    });

    // A-B 判定のため細かめの間隔で位置を監視する
    _player
        .createPositionStream(
          minPeriod: const Duration(milliseconds: 50),
          maxPeriod: const Duration(milliseconds: 200),
        )
        .listen(_onPosition);

    // 「曲が終わったら停止」: 曲が最後まで再生されて次へ進んだ (スキップ等は除く)
    _player.positionDiscontinuityStream.listen((d) {
      if (d.reason == PositionDiscontinuityReason.autoAdvance &&
          sleepTimer.value.endOfTrack) {
        cancelSleepTimer();
        _player.pause();
        _player.seek(Duration.zero); // 次回は次の曲の頭から
      }
    });
    _player.processingStateStream.listen((state) {
      // キューの最後まで再生し終えたら、曲の終わり待ちは不要
      if (state == ProcessingState.completed && sleepTimer.value.endOfTrack) {
        cancelSleepTimer();
      }
    });

    _player.playingStream.listen((playing) {
      _saveTimer?.cancel();
      if (playing) {
        _saveTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _saveProgress(),
        );
      } else {
        _saveProgress();
      }
    });

    // 保存済みの設定を反映
    _player.setSpeed(_store.speed);
    _player.setLoopMode(_toLoopMode(_store.repeatMode));
    _player.setShuffleModeEnabled(_store.shuffle);
  }

  // ------------------------------------------------------------------
  // フォルダの読み込み
  // ------------------------------------------------------------------

  /// [tracks] をキューに積んで再生する。
  ///
  /// [startIndex] が null かつシャッフル ON の場合はランダムな曲から開始。
  /// [resume] が true なら、開始曲の前回の再生位置から再開する。
  Future<void> playFolder(
    String folder,
    List<String> tracks, {
    int? startIndex,
    bool? shuffle,
    bool resume = true,
    Duration? startPosition,
    bool autoplay = true,
    AbLoop? abLoop,
  }) async {
    if (tracks.isEmpty) return;
    _cancelGap();
    await _saveProgress();

    final shuffleOn = shuffle ?? _player.shuffleModeEnabled;
    final index =
        startIndex ?? (shuffleOn ? Random().nextInt(tracks.length) : 0);
    final position =
        startPosition ?? (resume ? _store.positionFor(tracks[index]) : null);

    final items = [
      for (final t in tracks)
        MediaItem(
          id: t,
          title: p.basenameWithoutExtension(t),
          album: p.basename(folder),
        ),
    ];
    queue.add(items);
    currentFolder.add(folder);
    this.abLoop.add(AbLoop.none);
    _pendingAb = abLoop == null ? null : (path: tracks[index], loop: abLoop);
    _lastPath = null;

    if (shuffle != null) await _setShuffle(shuffle);
    await _player.setAudioSources(
      [for (final t in tracks) AudioSource.file(t)],
      initialIndex: index,
      initialPosition: position,
    );
    // 開始曲が直前と同じで index の通知が来なかった場合の保険
    _applyPendingAb(_lastPath);
    if (autoplay) unawaited(_player.play());
  }

  // ------------------------------------------------------------------
  // audio_service の操作 (通知・ロック画面・イヤホンからも呼ばれる)
  // ------------------------------------------------------------------

  @override
  Future<void> play() {
    _cancelGap();
    if (_fading) cancelSleepTimer(); // フェード中の操作は「まだ聞く」とみなす
    return _player.play();
  }

  @override
  Future<void> pause() {
    _cancelGap();
    if (_fading) cancelSleepTimer();
    return _player.pause();
  }

  @override
  Future<void> stop() async {
    _cancelGap();
    cancelSleepTimer();
    await _saveProgress();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) {
    _resumeAfterGap();
    return _player.seek(position);
  }

  @override
  Future<void> rewind() => _seekRelative(-skipInterval);

  @override
  Future<void> fastForward() => _seekRelative(skipInterval);

  /// 再生中の曲の頭に戻る
  Future<void> restartTrack() {
    _resumeAfterGap();
    return _player.seek(Duration.zero);
  }

  /// 再生開始から [restartThreshold] 以上経っていれば曲の頭へ、
  /// そうでなければ前の曲へ。
  @override
  Future<void> skipToPrevious() async {
    _resumeAfterGap();
    if (_player.position > restartThreshold || !_player.hasPrevious) {
      await restartTrack();
    } else {
      await _player.seekToPrevious();
    }
  }

  @override
  Future<void> skipToNext() async {
    _resumeAfterGap();
    if (_player.hasNext) await _player.seekToNext();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    // 外部アプリ (MediaController) からも呼べるので範囲外は無視する
    if (index < 0 || index >= queue.value.length) return;
    _resumeAfterGap();
    await _player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _player.setLoopMode(_toLoopMode(repeatMode));
    await _store.setRepeatMode(repeatMode);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setSpeed(double speed) async {
    // 外部アプリから 0・負数・NaN 等が来ても再生不能/起動時クラッシュにしない
    final safe = SettingsStore.sanitizeSpeed(speed);
    await _player.setSpeed(safe);
    await _store.setSpeed(safe);
  }

  @override
  Future<void> onTaskRemoved() async {
    // アプリをタスク一覧から消した時、停止中ならサービスも終了する
    if (!_player.playing) await stop();
  }

  // ------------------------------------------------------------------
  // スリープタイマー
  // ------------------------------------------------------------------

  /// [duration] 後に停止する (最後の [sleepFade] で音量を下げていく)。
  void setSleepTimer(Duration duration) {
    _resetSleep();
    sleepTimer.add(SleepTimer(endsAt: DateTime.now().add(duration)));
    final fade = duration < sleepFade ? duration : sleepFade;
    final gen = _sleepGen;
    _sleepTicker = Timer(duration - fade, () => _fadeOutAndPause(gen, fade));
  }

  /// 再生中の曲が終わったら停止する。
  void setSleepAtEndOfTrack() {
    _resetSleep();
    sleepTimer.add(const SleepTimer(endOfTrack: true));
  }

  void cancelSleepTimer() {
    _resetSleep();
    sleepTimer.add(SleepTimer.off);
  }

  void _resetSleep() {
    _sleepTicker?.cancel();
    _sleepTicker = null;
    _sleepGen++;
    if (_fading) {
      _fading = false;
      _player.setVolume(1.0);
    }
  }

  Future<void> _fadeOutAndPause(int gen, Duration fade) async {
    // A-B の無音で一時停止中なら、待ち明けの自動再開を取りやめる
    if (!_player.playing) _cancelGap();
    if (_player.playing) {
      _fading = true;
      const steps = 20;
      for (var i = steps - 1; i >= 0; i--) {
        await Future<void>.delayed(fade ~/ steps);
        if (gen != _sleepGen) return; // 解除された (音量は _resetSleep で戻す)
        await _player.setVolume(i / steps);
      }
      _fading = false;
      _cancelGap();
      await _player.pause();
      await _player.setVolume(1.0);
    }
    if (gen == _sleepGen) {
      _sleepTicker = null;
      sleepTimer.add(SleepTimer.off);
    }
  }

  // ------------------------------------------------------------------
  // A-B 区間リピート
  // ------------------------------------------------------------------

  /// 1ボタンで A設定 → B設定 → 解除 を切り替える
  void cycleAbLoop() {
    _resumeAfterGap();
    final ab = abLoop.value;
    final pos = _player.position;
    if (ab.a == null) {
      abLoop.add(AbLoop(a: pos));
    } else if (ab.b == null) {
      if (pos <= ab.a!) {
        // B が A より前なら A を設定し直す
        abLoop.add(AbLoop(a: pos));
      } else {
        abLoop.add(AbLoop(a: ab.a, b: pos));
        _player.seek(ab.a);
      }
    } else {
      abLoop.add(AbLoop.none);
    }
  }

  void clearAbLoop() {
    _resumeAfterGap();
    abLoop.add(AbLoop.none);
  }

  /// 再生中の曲に A-B 区間を設定し、A から再生する (保存した区間の呼び出し)。
  Future<void> startAbLoop(Duration a, Duration b) async {
    _cancelGap();
    abLoop.add(AbLoop(a: a, b: b));
    await _player.seek(a);
    unawaited(_player.play());
  }

  Future<void> setAbRepeat(AbRepeatSettings s) async {
    abRepeat.add(s);
    await _store.setAbRepeat(s);
  }

  void _onPosition(Duration pos) {
    _lastPosition = pos;
    if (_abSeeking) return;
    final ab = abLoop.value;
    switch (nextAbStep(ab, pos, abRepeat.value.count)) {
      case AbStep.none:
        return;
      case AbStep.finish:
        abLoop.add(AbLoop.none);
      case AbStep.loop:
        _loopBack(ab.copyWith(passes: ab.passes + 1));
    }
  }

  /// A に戻る。無音が設定されていれば一時停止して待ってから再開する。
  void _loopBack(AbLoop ab) {
    _abSeeking = true;
    final gap = abRepeat.value.gapAfter(ab.b! - ab.a!, _player.speed);
    if (gap <= Duration.zero) {
      abLoop.add(ab);
      _player.seek(ab.a).whenComplete(() => _abSeeking = false);
      return;
    }
    abLoop.add(ab.copyWith(waiting: true));
    _player.pause().then((_) => _player.seek(ab.a)).whenComplete(() {
      _abSeeking = false;
      // 待機中にユーザーが操作していたら自動再開しない
      if (!abLoop.value.waiting) return;
      _gapTimer = Timer(gap, () {
        _gapTimer = null;
        _setWaiting(false);
        _player.play();
      });
    });
  }

  /// 無音の待機を取りやめる (再生/停止はユーザー操作に任せる)。
  void _cancelGap() {
    _gapTimer?.cancel();
    _gapTimer = null;
    _setWaiting(false);
  }

  /// 待機中にシーク等をされたら、待たずに再生を再開する。
  void _resumeAfterGap() {
    final wasWaiting = abLoop.value.waiting;
    _cancelGap();
    if (wasWaiting) unawaited(_player.play());
  }

  void _setWaiting(bool waiting) {
    final ab = abLoop.value;
    if (ab.waiting != waiting) abLoop.add(ab.copyWith(waiting: waiting));
  }

  void _applyPendingAb(String? path) {
    final pending = _pendingAb;
    if (pending == null || path != pending.path) return;
    _pendingAb = null;
    abLoop.add(pending.loop);
  }

  // ------------------------------------------------------------------
  // 内部処理
  // ------------------------------------------------------------------

  Future<void> _seekRelative(Duration offset) async {
    var target = _player.position + offset;
    if (target < Duration.zero) target = Duration.zero;
    final d = _player.duration;
    if (d != null && target > d) target = d;
    await _player.seek(target);
  }

  Future<void> _setShuffle(bool enabled) async {
    if (enabled) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabled);
    await _store.setShuffle(enabled);
  }

  void _onIndexChanged(int? index) {
    // 直前の曲の再生位置を記録
    final prev = _lastPath;
    if (prev != null) _savePositionFor(prev, _lastPosition, _lastDuration);

    final items = queue.value;
    if (index == null || index >= items.length) return;
    final item = items[index];
    if (item.id != _lastPath) {
      _cancelGap();
      abLoop.add(AbLoop.none); // 曲が変わったら A-B は解除
      _applyPendingAb(item.id);
    }
    _lastPath = item.id;
    mediaItem.add(item.copyWith(duration: _player.duration));
  }

  Future<void> _saveProgress() async {
    final path = _lastPath;
    final folder = currentFolder.value;
    if (path == null || folder == null) return;
    final pos = _player.position;
    await _store.saveSession(
      LastSession(folder: folder, trackPath: path, position: pos),
    );
    await _savePositionFor(path, pos, _player.duration);
  }

  Future<void> _savePositionFor(
    String path,
    Duration pos,
    Duration? duration,
  ) async {
    final nearEnd = duration != null && pos > duration - _resumeMargin;
    if (pos < _resumeMargin || nearEnd) {
      await _store.clearPosition(path);
    } else {
      await _store.savePosition(path, pos);
    }
  }

  static LoopMode _toLoopMode(AudioServiceRepeatMode m) => switch (m) {
    AudioServiceRepeatMode.none => LoopMode.off,
    AudioServiceRepeatMode.one => LoopMode.one,
    AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => LoopMode.all,
  };

  void _broadcastState() {
    final playing = _player.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 2, 4],
        processingState: switch (_player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
        repeatMode: switch (_player.loopMode) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
        shuffleMode: _player.shuffleModeEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }
}

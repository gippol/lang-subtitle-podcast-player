import 'package:flutter_test/flutter_test.dart';
import 'package:lang_player/audio/player_handler.dart';
import 'package:lang_player/ui/sleep_timer.dart';

void main() {
  final now = DateTime(2026, 1, 1, 23);

  test('SleepTimer.off は無効', () {
    expect(SleepTimer.off.isActive, isFalse);
    expect(SleepTimer.off.remaining(now), isNull);
  });

  test('時刻指定の残り時間 (過ぎたら 0)', () {
    final t = SleepTimer(endsAt: now.add(const Duration(minutes: 30)));
    expect(t.isActive, isTrue);
    expect(t.remaining(now), const Duration(minutes: 30));
    expect(t.remaining(now.add(const Duration(hours: 1))), Duration.zero);
  });

  test('曲の終わり指定は残り時間なし', () {
    const t = SleepTimer(endOfTrack: true);
    expect(t.isActive, isTrue);
    expect(t.remaining(now), isNull);
  });

  test('残り時間は秒を切り上げて表示する', () {
    expect(formatSleepRemaining(const Duration(milliseconds: 400)), '00:01');
    expect(
      formatSleepRemaining(const Duration(minutes: 29, seconds: 59)),
      '29:59',
    );
    expect(formatSleepRemaining(Duration.zero), '00:00');
  });
}

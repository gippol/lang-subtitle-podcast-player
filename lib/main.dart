import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'audio/player_handler.dart';
import 'data/settings_store.dart';
import 'data/subtitles.dart';
import 'providers.dart';
import 'ui/folder_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 音声コンテンツ向けのオーディオフォーカス設定
  // (通知音で一時停止、イヤホンを抜いたら停止 など)
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());

  final store = await SettingsStore.load();
  final supportDir = await getApplicationSupportDirectory();
  final handler = await AudioService.init(
    builder: () => PlayerHandler(store),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.langplayer.playback',
      androidNotificationChannelName: '再生',
      // 一時停止中もフォアグラウンドを維持し、イヤホンからの再開を確実にする
      androidStopForegroundOnPause: false,
      fastForwardInterval: PlayerHandler.skipInterval,
      rewindInterval: PlayerHandler.skipInterval,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        playerHandlerProvider.overrideWithValue(handler),
        subtitleStoreProvider.overrideWithValue(
          SubtitleStore(Directory(p.join(supportDir.path, 'subtitles'))),
        ),
      ],
      child: const LangPlayerApp(),
    ),
  );
}

class LangPlayerApp extends StatelessWidget {
  const LangPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LangPlayer',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const RootScreen(),
    );
  }
}

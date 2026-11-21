# LangPlayer

歩きながら語学用の音声 (podcast 等) を聞き続けるための Android アプリ。Flutter + Riverpod。

## 使い方

1. 内部ストレージの `Music/LangPlayer/` に音声ファイルやフォルダをコピーする
   (初回起動時に自動作成。作成できない場合はファイルアプリで作成)
2. フォルダをたどって「順番再生」「シャッフル」、または曲をタップして再生

対応形式: mp3 / m4a / m4b / aac / wav / ogg / opus / flac

## 機能

| 機能 | 操作 |
| --- | --- |
| バックグラウンド再生 | 通知・ロック画面・Bluetooth イヤホンから操作可 |
| リピート | OFF → 全曲(フォルダ) → 1曲 を切替 |
| A-B 区間リピート | A-B ボタン: 1回目 A 設定 → 2回目 B 設定 → 3回目 解除。曲が変わると解除 |
| 頭出し / 前 / 次 | 「前」は 3 秒以上再生中なら曲の頭、それ以外は前の曲 |
| ±10 秒 | 聞き逃しの聞き直し |
| 再生速度 | 0.5x〜2.0x |
| 再生位置の記憶 | 曲ごとに途中位置を保存 (曲をタップすると続きから)。起動時は前回の曲を一時停止状態で復元 |

## 構成

```
lib/
  main.dart                 AudioService 初期化、ProviderScope
  providers.dart            Riverpod プロバイダ一覧
  audio/player_handler.dart 再生本体 (just_audio + audio_service)
  data/audio_library.dart   フォルダ走査・自然順ソート
  data/settings_store.dart  設定・再生位置の保存 (shared_preferences)
  ui/                       画面 (フォルダ一覧 / 再生画面 / ミニプレーヤー)
```

## 開発環境

| 項目 | バージョン |
| --- | --- |
| Dart SDK | ^3.13.3 |
| Gradle | 9.5.0 |
| Android Gradle Plugin | 9.3.1 |
| Kotlin | 2.4.20 |

## ビルド

```bash
flutter build apk --release
```

`build/app/outputs/flutter-apk/app-release.apk` を端末にインストール (デバッグ署名)。

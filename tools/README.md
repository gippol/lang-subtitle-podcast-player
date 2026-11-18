# 字幕作成スクリプト (Mac)

`make_subtitles.py` は、音声ファイルから字幕 (`.srt`) を作るスクリプトです。
音声と同じフォルダに同じ名前で保存するので、音声と一緒に端末へコピーすれば LangPlayer で字幕が表示されます。

```
English/
  lesson01.mp3
  lesson01.srt   ← 作られる
```

文字起こしには Whisper を使います。処理はすべて Mac の中で行い、音声をネットに送ることはありません
(初回だけモデルをダウンロードします)。

## 準備 (初回だけ)

### Apple Silicon (M1 以降) の Mac

```sh
brew install ffmpeg
python3 -m venv ~/.venvs/whisper
source ~/.venvs/whisper/bin/activate
pip install mlx-whisper
```

### Intel Mac

```sh
python3 -m venv ~/.venvs/whisper
source ~/.venvs/whisper/bin/activate
pip install faster-whisper
```

Homebrew が無い場合は https://brew.sh を参照してください。

## 使い方

```sh
source ~/.venvs/whisper/bin/activate   # 新しいターミナルを開いた時
python3 tools/make_subtitles.py ~/Music/LangPlayer --language en
```

- フォルダを指定すると、サブフォルダも含めて全部の音声を処理します。ファイルを直接指定することもできます。
- すでに字幕 (`.srt` / `.lrc`) がある音声はスキップします。作り直すときは `--overwrite` を付けます。
- 途中で止めても (Ctrl+C)、それまでに作った字幕は残ります。もう一度実行すると続きから処理します。

| オプション | 説明 |
|---|---|
| `-l`, `--language` | 音声の言語 (`en`, `ja`, `zh`, `ko` など)。省略すると自動判定 |
| `-m`, `--model` | モデル名。精度を上げたい/速くしたい時に変更 |
| `--engine` | `mlx` / `faster` を強制する (普通は自動でよい) |
| `--overwrite` | 既存の字幕も作り直す |
| `--dry-run` | 対象ファイルの確認だけして何も作らない |

### モデルの選び方

| エンジン | 既定 | 速さ重視 | 精度重視 |
|---|---|---|---|
| mlx (Apple Silicon) | `mlx-community/whisper-large-v3-turbo` | `mlx-community/whisper-small-mlx` | `mlx-community/whisper-large-v3-mlx` |
| faster (Intel) | `small` | `base` | `medium` |

初回はモデルのダウンロードに時間がかかります (数百MB〜数GB)。

## 端末へのコピー

作った `.srt` を音声と同じフォルダにコピーします (例: Android File Transfer や USB 接続)。

端末によっては、アプリが同じフォルダの字幕を自動で読めないことがあります (Android の権限の仕組みのため)。
その場合は再生画面の「字幕」→「ファイルを選ぶ」から `.srt` を選んでください。

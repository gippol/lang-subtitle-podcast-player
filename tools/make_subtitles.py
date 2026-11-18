#!/usr/bin/env python3
"""音声ファイルから字幕 (.srt) を作る (Mac 用)。

LangPlayer は音声と同じフォルダにある同名の .srt を自動で読み込むので、
ここで作った .srt を音声と一緒に端末へコピーすれば字幕が表示される。

使い方:
    python3 make_subtitles.py ~/Music/LangPlayer --language en
    python3 make_subtitles.py lesson01.mp3 lesson02.mp3 --language en
    python3 make_subtitles.py ~/Music/LangPlayer --dry-run   # 対象の確認だけ

エンジン (自動で選ぶ):
    - Apple Silicon: mlx-whisper   (pip install mlx-whisper, 要 ffmpeg)
    - Intel Mac 等:  faster-whisper (pip install faster-whisper)

詳しくは tools/README.md を参照。
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Iterator, List, Optional

# アプリ (lib/data/audio_library.dart) と同じ対象拡張子
AUDIO_EXTENSIONS = {
    ".mp3", ".m4a", ".m4b", ".aac", ".wav", ".ogg", ".oga", ".opus", ".flac",
}
SUBTITLE_EXTENSIONS = (".srt", ".lrc")

DEFAULT_MLX_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_FASTER_MODEL = "small"


@dataclass
class Segment:
    start: float  # 秒
    end: float
    text: str


# 音声ファイルのパス -> 字幕の行
Transcriber = Callable[[Path], List[Segment]]


# ---------------------------------------------------------------------------
# 対象ファイルの列挙
# ---------------------------------------------------------------------------

def is_audio(path: Path) -> bool:
    return path.suffix.lower() in AUDIO_EXTENSIONS and not path.name.startswith(".")


def find_audio(inputs: Iterable[Path]) -> Iterator[Path]:
    """ファイル/フォルダの指定から音声ファイルを列挙する (隠しファイルは除外)。"""
    for item in inputs:
        if item.is_dir():
            for root, dirs, files in os.walk(item):
                dirs[:] = sorted(d for d in dirs if not d.startswith("."))
                for name in sorted(files):
                    path = Path(root) / name
                    if is_audio(path):
                        yield path
        elif item.is_file() and is_audio(item):
            yield item
        else:
            print(f"スキップ (音声ファイルではありません): {item}", file=sys.stderr)


def existing_subtitle(audio: Path) -> Optional[Path]:
    """同名の字幕が既にあればそのパス (アプリが読むものと同じ規則)。"""
    for ext in SUBTITLE_EXTENSIONS:
        for e in (ext, ext.upper()):
            candidate = audio.with_suffix(e)
            if candidate.exists():
                return candidate
    return None


# ---------------------------------------------------------------------------
# SRT の書き出し
# ---------------------------------------------------------------------------

def srt_time(seconds: float) -> str:
    ms = max(0, round(seconds * 1000))
    h, ms = divmod(ms, 3_600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def to_srt(segments: Iterable[Segment]) -> str:
    blocks = []
    for seg in segments:
        text = " ".join(seg.text.split())  # 改行・連続空白を1つに
        if not text or seg.end <= seg.start:
            continue
        n = len(blocks) + 1
        blocks.append(f"{n}\n{srt_time(seg.start)} --> {srt_time(seg.end)}\n{text}\n")
    return "\n".join(blocks)


def write_atomic(path: Path, text: str) -> None:
    """途中で止めても壊れたファイルが残らないよう、一時ファイル経由で書く。"""
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


# ---------------------------------------------------------------------------
# 文字起こしエンジン
# ---------------------------------------------------------------------------

def is_apple_silicon() -> bool:
    return sys.platform == "darwin" and platform.machine() == "arm64"


def make_mlx(model: str, language: Optional[str]) -> Transcriber:
    import mlx_whisper  # noqa: PLC0415

    if shutil.which("ffmpeg") is None:
        sys.exit("ffmpeg が見つかりません。`brew install ffmpeg` でインストールしてください。")

    def run(audio: Path) -> List[Segment]:
        result = mlx_whisper.transcribe(
            str(audio),
            path_or_hf_repo=model,
            language=language,
            # 長い音声で同じ文を繰り返し出力する現象を抑える
            condition_on_previous_text=False,
        )
        return [
            Segment(float(s["start"]), float(s["end"]), str(s["text"]))
            for s in result.get("segments", [])
        ]

    return run


def make_faster(model: str, language: Optional[str]) -> Transcriber:
    from faster_whisper import WhisperModel  # noqa: PLC0415

    whisper = WhisperModel(model, device="cpu", compute_type="int8")

    def run(audio: Path) -> List[Segment]:
        segments, _info = whisper.transcribe(
            str(audio),
            language=language,
            vad_filter=True,  # 無音部分を飛ばして誤認識を減らす
            condition_on_previous_text=False,
        )
        return [Segment(s.start, s.end, s.text) for s in segments]

    return run


def make_transcriber(engine: str, model: Optional[str], language: Optional[str]) -> Transcriber:
    if engine == "auto":
        engine = "mlx" if is_apple_silicon() else "faster"
    try:
        if engine == "mlx":
            return make_mlx(model or DEFAULT_MLX_MODEL, language)
        return make_faster(model or DEFAULT_FASTER_MODEL, language)
    except ImportError:
        package = "mlx-whisper" if engine == "mlx" else "faster-whisper"
        sys.exit(
            f"{package} がインストールされていません。\n"
            f"  pip install {package}\n"
            "詳しくは tools/README.md を参照してください。"
        )


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def process(
    files: List[Path],
    transcribe: Optional[Transcriber],
    overwrite: bool,
    dry_run: bool,
) -> int:
    """字幕を作る。失敗した件数を返す。"""
    failed = 0
    total = len(files)
    for i, audio in enumerate(files, 1):
        prefix = f"[{i}/{total}] {audio}"
        out = audio.with_suffix(".srt")
        existing = existing_subtitle(audio)
        if existing and not overwrite:
            print(f"{prefix}\n    スキップ (字幕あり: {existing.name})")
            continue
        if dry_run:
            print(f"{prefix}\n    → {out.name} を作成予定")
            continue

        print(prefix, flush=True)
        started = time.monotonic()
        try:
            segments = transcribe(audio)  # type: ignore[misc]
        except Exception as e:  # noqa: BLE001 - 1ファイルの失敗で全体を止めない
            failed += 1
            print(f"    失敗: {e}", file=sys.stderr)
            continue
        srt = to_srt(segments)
        if not srt:
            print("    音声を認識できませんでした (字幕は作りません)")
            continue
        write_atomic(out, srt)
        lines = srt.count(" --> ")
        print(f"    → {out.name} ({lines}行, {time.monotonic() - started:.0f}秒)")
    return failed


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="音声ファイルから LangPlayer 用の字幕 (.srt) を作ります。",
    )
    parser.add_argument("inputs", nargs="+", type=Path, help="音声ファイルまたはフォルダ")
    parser.add_argument(
        "-l", "--language",
        help="音声の言語 (en, ja, zh, ko など)。省略すると自動判定 (少し遅く、誤判定もあり)",
    )
    parser.add_argument(
        "-m", "--model",
        help=f"モデル名 (既定: mlx={DEFAULT_MLX_MODEL}, faster={DEFAULT_FASTER_MODEL})",
    )
    parser.add_argument(
        "--engine", choices=["auto", "mlx", "faster"], default="auto",
        help="文字起こしエンジン (既定: Apple Silicon なら mlx、それ以外は faster)",
    )
    parser.add_argument("--overwrite", action="store_true", help="既存の字幕も作り直す")
    parser.add_argument("--dry-run", action="store_true", help="対象の確認だけして何も作らない")
    args = parser.parse_args(argv)

    files = list(dict.fromkeys(find_audio(args.inputs)))  # 重複を除く
    if not files:
        print("音声ファイルが見つかりませんでした。", file=sys.stderr)
        return 1

    transcribe = None if args.dry_run else make_transcriber(args.engine, args.model, args.language)
    try:
        failed = process(files, transcribe, args.overwrite, args.dry_run)
    except KeyboardInterrupt:
        print("\n中断しました (作成済みの字幕はそのまま残ります)。", file=sys.stderr)
        return 130
    if failed:
        print(f"\n{failed}件失敗しました。", file=sys.stderr)
        return 1
    print("\n完了しました。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

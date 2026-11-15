#!/usr/bin/env python3
"""Transcribe a wav file with sherpa-onnx.

Called by voiceinput.nvim with a python interpreter that has the
sherpa_onnx package installed (e.g. the venv created by bootstrap.sh).

Presets:
  zh-en-zipformer: streaming transducer (encoder/decoder/joiner int8)
  sensevoice:      offline SenseVoice model (model.int8.onnx), zh/en/ja/ko/yue
"""
import argparse
import array
import re
import sys
import wave

import sherpa_onnx

TAG_RE = re.compile(r"<\|[^|]*\|>")


def read_wav(path):
    with wave.open(path, "rb") as f:
        assert f.getnchannels() == 1, "mono expected"
        assert f.getsampwidth() == 2, "16-bit expected"
        sample_rate = f.getframerate()
        samples = array.array("h", f.readframes(f.getnframes()))
        if sys.byteorder == "big":
            samples.byteswap()
        samples = [s / 32768.0 for s in samples]
    return sample_rate, samples


def transcribe_zipformer(args, sample_rate, samples):
    recognizer = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=args.tokens,
        encoder=args.encoder,
        decoder=args.decoder,
        joiner=args.joiner,
        provider=args.provider,
        num_threads=args.num_threads,
        sample_rate=16000,
        feature_dim=80,
        decoding_method="greedy_search",
    )
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples)
    while recognizer.is_ready(stream):
        recognizer.decode_stream(stream)
    return recognizer.get_result(stream)


def transcribe_sensevoice(args, sample_rate, samples):
    recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=args.model,
        tokens=args.tokens,
        provider=args.provider,
        num_threads=args.num_threads,
        use_itn=True,
        language="auto",
    )
    stream = recognizer.create_stream()
    stream.accept_waveform(sample_rate, samples)
    recognizer.decode_stream(stream)
    return stream.result.text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--preset", choices=["zh-en-zipformer", "sensevoice"],
                   default="zh-en-zipformer")
    # zipformer 四件套
    p.add_argument("--encoder")
    p.add_argument("--decoder")
    p.add_argument("--joiner")
    # sensevoice 单模型
    p.add_argument("--model")
    p.add_argument("--tokens", required=True)
    p.add_argument("--wav", required=True)
    p.add_argument("--provider", default="cpu")
    p.add_argument("--num-threads", type=int, default=2)
    a = p.parse_args()

    sample_rate, samples = read_wav(a.wav)
    if a.preset == "sensevoice":
        if not a.model:
            p.error("sensevoice 需要 --model")
        text = transcribe_sensevoice(a, sample_rate, samples)
        text = TAG_RE.sub("", text).strip()  # 去掉 <|zh|><|EMO_UNKNOWN|> 等标记
    else:
        if not (a.encoder and a.decoder and a.joiner):
            p.error("zh-en-zipformer 需要 --encoder/--decoder/--joiner")
        text = transcribe_zipformer(a, sample_rate, samples).strip()

    if not text:
        sys.exit(3)  # empty transcription
    print(text)


if __name__ == "__main__":
    main()

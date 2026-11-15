#!/bin/sh
# voiceinput.nvim bootstrap:
#   1. 创建 venv（优先 uv，否则 python3 -m venv），安装 sherpa-onnx + click
#   2. 按 preset 下载模型并归一化为标准文件名
# 用法: bootstrap.sh [data_dir] [preset]
#   preset = zh-en-zipformer (默认, 流式, 快) | sensevoice (离线, 更准)
#   data_dir 默认 ~/.local/share/nvim/voiceinput
set -e

DATA_DIR="${1:-$HOME/.local/share/nvim/voiceinput}"
PRESET="${2:-zh-en-zipformer}"
VENV="$DATA_DIR/venv"
BASE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"

case "$PRESET" in
  zh-en-zipformer)
    MODEL=sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20
    ;;
  sensevoice)
    MODEL=sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
    ;;
  *)
    echo "未知 preset: $PRESET (可用: zh-en-zipformer, sensevoice)"
    exit 1
    ;;
esac

mkdir -p "$DATA_DIR"

echo "==> [1/2] venv: $VENV"
if [ -x "$VENV/bin/python" ]; then
  echo "    已存在，跳过创建"
elif command -v uv >/dev/null 2>&1; then
  uv venv "$VENV"
  uv pip install --python "$VENV/bin/python" "sherpa-onnx>=2.0.1" click
else
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install -U pip
  "$VENV/bin/python" -m pip install "sherpa-onnx>=2.0.1" click
fi

"$VENV/bin/python" - <<'EOF'
import sherpa_onnx
print("    sherpa_onnx", sherpa_onnx.__version__, "OK")
EOF

echo "==> [2/2] 模型($PRESET): $MODEL -> $DATA_DIR"
cd "$DATA_DIR"
fetch() {
  # fetch <url> <output>
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 -o "$2" "$1"
  else
    wget -O "$2" "$1"
  fi
}

if [ "$PRESET" = "zh-en-zipformer" ]; then
  READY="[ -f encoder.int8.onnx ] && [ -f decoder.onnx ] && [ -f joiner.int8.onnx ] && [ -f tokens.txt ]"
else
  READY="[ -f model.int8.onnx ] && [ -f tokens_sensevoice.txt ]"
fi
if sh -c "$READY"; then
  echo "    模型已就绪，跳过下载"
else
  try_hf_mirror() {
    # 优先 hf-mirror 镜像按文件下载（GitHub release 在国内往往极慢）
    local base="https://hf-mirror.com/csukuangfj/$MODEL/resolve/main"
    if [ "$PRESET" = "zh-en-zipformer" ]; then
      fetch "$base/tokens.txt"                        "tokens.txt" || return 1
      fetch "$base/encoder-epoch-99-avg-1.int8.onnx"  "encoder.int8.onnx" || return 1
      fetch "$base/decoder-epoch-99-avg-1.int8.onnx"  "decoder.onnx" || return 1
      fetch "$base/joiner-epoch-99-avg-1.int8.onnx"   "joiner.int8.onnx" || return 1
    else
      fetch "$base/tokens.txt"       "tokens_sensevoice.txt" || return 1
      fetch "$base/model.int8.onnx"  "model.int8.onnx" || return 1
    fi
  }
  try_github_tarball() {
    # 回退：GitHub release 完整 tarball，下载后归一化
    local TARBALL="$MODEL.tar.bz2"
    fetch "$BASE_URL/$TARBALL" "$TARBALL" || return 1
    rm -rf "$MODEL"
    tar xjf "$TARBALL" || return 1
    pick() {
      src=$(find "$MODEL" -name "$1" | sort | head -n 1)
      [ -n "$src" ] || return 1
      cp "$src" "$2"
    }
    if [ "$PRESET" = "zh-en-zipformer" ]; then
      pick "tokens.txt"          "tokens.txt" || return 1
      pick "encoder*.int8.onnx"  "encoder.int8.onnx" || return 1
      pick "decoder*.onnx"       "decoder.onnx" || return 1
      pick "joiner*.int8.onnx"   "joiner.int8.onnx" || return 1
    else
      pick "tokens.txt"       "tokens.txt" || return 1
      pick "model.int8.onnx"  "model.int8.onnx" || return 1
    fi
  }
  echo "    尝试 hf-mirror 镜像…"
  if try_hf_mirror; then
    echo "    镜像下载完成"
  else
    echo "    镜像失败，回退 GitHub release tarball…"
    try_github_tarball
  fi
  echo "    模型文件: $(ls -lh *.onnx tokens.txt | awk '{print $5, $9}')"
fi

echo
echo "bootstrap 完成 ($PRESET)。nvim 里用 :VoiceInputHealth 检查。"

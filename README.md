# voiceinput.nvim

Voice input for Neovim: press a key to start recording, press it again to stop
and transcribe — the recognized text is inserted at the cursor.

Built for **Chinese + English** speech, fully cross-platform (macOS / Linux /
Windows). It never touches OS-native speech services: everything shells out to
regular programs — recording via a system CLI (`sox` by default), transcription
via a python venv with the `sherpa_onnx` package (auto-created) or any external
command you configure.

## Layout

```
lua/voiceinput/init.lua        setup / toggle / recording / text insertion / commands
lua/voiceinput/transcriber.lua builds the transcribe command and runs it async
lua/voiceinput/health.lua      self-check (:VoiceInputHealth)
scripts/transcribe.py          transcribes one wav via sherpa_onnx
scripts/bootstrap.sh           creates the venv and downloads the model
plugin/voiceinput.lua          :VoiceInputHealth / :VoiceInputBootstrap (usable before setup)
```

## Installation (lazy.nvim)

```lua
{
  dir = "~/software/nvim/voiceinput.nvim/",
  keys = { { "<C-/>", desc = "voiceinput" } },
  -- Auto-install after lazy.nvim clones/updates the plugin:
  -- downloads the model and builds the venv.
  build = ":VoiceInputBootstrap",
  opts = {
    keys = { toggle = "<C-/>", modes = { "n" } },
    data_dir = "~/data/nvimvoice", -- default: stdpath("data")/voiceinput
  },
}
```

If `opts.data_dir` is not the default, set the same path for the build phase:

```lua
vim.g.voiceinput_data_dir = "~/data/nvimvoice"
```

`:VoiceInputBootstrap` opens a terminal tab and runs `scripts/bootstrap.sh`,
which:

1. Creates a venv at `<data_dir>/venv` — `uv venv` when `uv` is available,
   otherwise `python3 -m venv` — and installs `sherpa-onnx` + `click`.
2. Downloads the model selected by `model_preset` (see below), preferring the
   hf-mirror.com mirror (much faster in mainland China) with a GitHub-release
   fallback.

Then run `:VoiceInputHealth` to verify everything is in place.

## Dependencies

| What | Why | Install |
|---|---|---|
| Neovim ≥ 0.10 | plugin host | — |
| a recording CLI | captures mic audio | macOS: `brew install sox` · Linux: `apt install sox` (or use `arecord`/`ffmpeg` via `record_cmd`) |
| python 3.x | venv creation (only if `uv` is absent) | any system python |
| `uv` (optional) | faster venv + pip | https://docs.astral.sh/uv/ |
| model files | downloaded automatically by bootstrap | ~100–230 MB per model |

Windows: `bootstrap.sh` needs WSL or Git Bash; or create the venv manually
(`python -m venv <data_dir>/venv`, then install `sherpa-onnx` — the plugin looks
for `venv/Scripts/python.exe`).

## Models (`model_preset`)

| preset | model | traits |
|---|---|---|
| `zh-en-zipformer` (default) | sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20 | streaming, fastest; moderate accuracy |
| `sensevoice` | sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17 (int8) | offline, notably more accurate (case, punctuation, ITN, zh-en code-switching); just as fast on CPU; also ja/ko/yue |

Switching: set `model_preset = "sensevoice"` in `opts`, re-run
`:VoiceInputBootstrap`. Both presets can coexist in the same `data_dir`
(filenames don't collide).

Measured on the same test clip (M-series Mac, CPU):

| preset | output | time |
|---|---|---|
| `zh-en-zipformer` | 昨天是 MONDAY TODAY IS LIBR THE DAY AFTER TOMORROW是星期三 | 1.20s |
| `sensevoice` | 昨天是monday，today is礼拜2，the day after tomorrow是星期三。 | 1.13s |

## Configuration

All options are optional; defaults shown.

```lua
opts = {
  keys = { toggle = "<C-/>", modes = { "n" } },
  data_dir = vim.fn.stdpath("data") .. "/voiceinput",
  model_preset = "zh-en-zipformer", -- or "sensevoice"
  model = nil,     -- defaults per preset; relative to data_dir, absolute paths kept as-is
  python = nil,    -- default: <data_dir>/venv/bin/python (Windows: venv/Scripts/python.exe)
  script = nil,    -- default: this plugin's scripts/transcribe.py
  record_cmd = "sox -d -r 16000 -c 1 -b 16 -t wav {output}", -- {output} → temp wav path
  transcribe_cmd = nil, -- custom transcribe command template (see below)
  env = {},        -- extra environment variables for the transcribe process
  insert_opts = { prefix = "", suffix = "" },
}
```

`model` defaults per preset:

| preset | files in `data_dir` |
|---|---|
| `zh-en-zipformer` | `tokens.txt`, `encoder.int8.onnx`, `decoder.onnx`, `joiner.int8.onnx` |
| `sensevoice` | `tokens_sensevoice.txt`, `model.int8.onnx` |

## Customization

The presets are conveniences, not limits. Three levels of customization:

### 1. Swap model files (no code changes)

Any sherpa-onnx model of the same decoding family works — point `model.*` at
your files:

```lua
model_preset = "zh-en-zipformer", -- keep the transducer decoding path
model = {
  tokens  = "~/mymodels/tokens.txt",
  encoder = "~/mymodels/encoder.int8.onnx",
  decoder = "~/mymodels/decoder.onnx",
  joiner  = "~/mymodels/joiner.int8.onnx",
},
```

### 2. Use any external transcriber (bypass sherpa_onnx entirely)

Set `transcribe_cmd` and the plugin will run *that* instead of the built-in
script. Available placeholders: `{wav}` `{tokens}` `{encoder}` `{decoder}`
`{joiner}` `{model}` `{python}` `{script}` `{preset}`. The command receives a
wav path and must print the recognized text to stdout.

```lua
-- whisper.cpp
transcribe_cmd = "whisper-cli -m ~/data/whisper/ggml-base.bin -nt -f {wav}",
-- your own script
transcribe_cmd = "{python} -m my_module --audio {wav} --dir " .. data_dir,
```

Recording is equally swappable:

```lua
record_cmd = "ffmpeg -y -f avfoundation -i ':0' -ar 16000 -ac 1 -t wav {output}", -- macOS
record_cmd = "arecord -r 16000 -c 1 -f S16_LE -t wav {output}",                   -- Linux
```

### 3. Add a new preset (small code changes)

- `scripts/bootstrap.sh`: add a `case` branch mapping the preset to an
  hf-repo name and file list.
- `lua/voiceinput/init.lua` → `preset_models`: default filenames for the preset.
- `scripts/transcribe.py`: only if the decoding API differs (e.g.
  `OfflineRecognizer.from_paraformer`), add a transcribe function.

## Usage

- `<C-/>` starts recording (`● recording…` notification); press again to stop
  and transcribe — text is inserted at the cursor.
- Failed or empty transcriptions show a `[voiceinput]` notification; exit code
  3 means "no speech recognized".
- `:VoiceInputStatus` — current state · `:VoiceInputHealth` — self-check ·
  `:VoiceInputBootstrap` — (re)install venv/model.

## Acknowledgements

- [GLM-5.3-flash](https://open.bigmodel.cn/) — this plugin was built with the
  [AtomCode](https://atomgit.com) AI coding agent running on GLM-5.3-flash.
- [AtomCode](https://atomgit.com/atomcode/atomcode) — the agent harness used to
  design, implement and verify this plugin.
- [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) and the
  [k2-fsa](https://github.com/k2-fsa) team — the ASR engine and pretrained
  models (zipformer, SenseVoice).
- [hf-mirror.com](https://hf-mirror.com) — fast model download mirror.

## License

MIT

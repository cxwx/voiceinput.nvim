local M = {}

-- 默认 data 目录：nvim 数据目录下的 voiceinput（跨平台），可覆盖
local function default_data_dir()
  return vim.fn.stdpath("data") .. "/voiceinput"
end

-- 各 preset 的默认模型文件名
local preset_models = {
  ["zh-en-zipformer"] = {
    tokens = "tokens.txt",
    encoder = "encoder.int8.onnx",
    decoder = "decoder.onnx",
    joiner = "joiner.int8.onnx",
  },
  sensevoice = {
    tokens = "tokens_sensevoice.txt",
    model = "model.int8.onnx",
  },
}

-- 默认配置：data 目录、模型文件名、录音/转写命令全部可覆盖
local defaults = {
  -- 按键与模式
  keys = { toggle = "<C-/>", modes = { "n" } },
  -- 模型数据目录（可任意定制；模型文件名相对此目录，绝对路径则原样使用）
  -- :VoiceInputBootstrap 会把 venv 和模型下载到这里
  data_dir = nil, -- setup 时取 default_data_dir()
  -- 模型选择：
  --   "zh-en-zipformer" 流式 zipformer（快，精度一般）
  --   "sensevoice"      离线 SenseVoice（中英日韩粤，明显更准，CPU int8 也快）
  -- 切换后需重跑 :VoiceInputBootstrap 下载对应模型
  model_preset = "zh-en-zipformer",
  model = nil, -- 默认随 model_preset，见 preset_models
  -- 转写用的 python（需装有 sherpa_onnx 包）。
  -- 默认取 data_dir/venv/bin/python（Windows: venv/Scripts/python.exe），
  -- 即 :VoiceInputBootstrap 创建的 venv；也可指向任何已有解释器。
  python = nil,
  -- 转写脚本（插件自带，也可换成自己的）
  script = nil, -- 默认取插件目录下 scripts/transcribe.py
  -- 录音命令模板，{output} 会被替换为临时 wav 路径
  -- macOS: sox / rec；Linux 可换 arecord；或 ffmpeg
  record_cmd = "sox -d -r 16000 -c 1 -b 16 -t wav {output}",
  -- 完全自定义转写命令模板（可选）。可用占位符:
  --   {wav} {tokens} {encoder} {decoder} {joiner} {python} {script}
  -- 设置后优先于默认的 python+script 组合
  transcribe_cmd = nil,
  -- 插入转写结果后在文本前后加空格/换行的处理
  insert_opts = { prefix = "", suffix = "" },
  -- 转写命令的额外环境变量
  env = {},
}

M.opts = nil

local function resolve(name)
  local p = M.opts.model[name]
  if not p then
    return ""
  end
  if p:sub(1, 1) == "~" or p:sub(1, 1) == "/" then
    return vim.fn.expand(p)
  end
  return M.opts.data_dir .. "/" .. p
end

local function resolve_record()
  local cmd = M.opts.record_cmd:gsub("{output}", function()
    return M.wav_path
  end)
  return cmd
end

function M.setup(opts)
  opts = opts or {}
  M.opts = vim.tbl_deep_extend("force", defaults, opts)
  if not M.opts.model then
    M.opts.model = preset_models[M.opts.model_preset] or preset_models["zh-en-zipformer"]
  end
  if not M.opts.data_dir then
    M.opts.data_dir = default_data_dir()
  end
  if M.opts.data_dir:sub(1, 1) == "~" then
    M.opts.data_dir = vim.fn.expand(M.opts.data_dir)
  end

  -- python：未指定时用 data_dir/venv（bootstrap.sh 创建的）
  if not M.opts.python then
    local py = M.opts.data_dir .. "/venv/bin/python"
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
      py = M.opts.data_dir .. "/venv/Scripts/python.exe"
    end
    M.opts.python = py
  end

  if not M.opts.script then
    local source = debug.getinfo(1, "S").source:sub(2) -- .../lua/voiceinput/init.lua
    -- :h→lua/voiceinput :h:h→lua :h:h:h→插件根目录
    M.opts.script = vim.fn.fnamemodify(source, ":h:h:h") .. "/scripts/transcribe.py"
  end

  M.wav_path = vim.fn.tempname() .. ".wav"

  vim.keymap.set(M.opts.keys.modes, M.opts.keys.toggle, function()
    require("voiceinput").toggle()
  end, { desc = "voiceinput: toggle" })

  vim.api.nvim_create_user_command("VoiceInput", function()
    require("voiceinput").toggle()
  end, {})
  vim.api.nvim_create_user_command("VoiceInputStatus", function()
    require("voiceinput").status()
  end, {})
end

function M.bootstrap(data_dir)
  data_dir = data_dir
    or (M.opts and M.opts.data_dir)
    or vim.g.voiceinput_data_dir
    or default_data_dir()
  local preset = (M.opts and M.opts.model_preset) or "zh-en-zipformer"
  if data_dir:sub(1, 1) == "~" then
    data_dir = vim.fn.expand(data_dir)
  end
  local source = debug.getinfo(1, "S").source:sub(2)
  local sh = vim.fn.fnamemodify(source, ":h:h:h") .. "/scripts/bootstrap.sh"
  vim.cmd("tabnew | terminal sh " .. vim.fn.shellescape(sh) .. " "
    .. vim.fn.shellescape(data_dir) .. " " .. vim.fn.shellescape(preset))
end

function M.toggle()
  if M.recording then
    M.stop_and_transcribe()
  else
    M.start_recording()
  end
end

local function notify(msg, level)
  vim.notify("[voiceinput] " .. msg, level or vim.log.levels.INFO)
end

function M.start_recording()
  if M.recording then
    return
  end
  if vim.fn.executable(M.opts.record_cmd:match("^%S+")) ~= 1 then
    notify("录音程序不存在: " .. M.opts.record_cmd:match("^%S+"), vim.log.levels.ERROR)
    return
  end
  M.wav_path = vim.fn.tempname() .. ".wav"
  local cmd = resolve_record()
  M.recording = vim.fn.jobstart(cmd, {
    on_stderr = function(_, data)
      -- sox 会往 stderr 打印进度，忽略常见噪音
      local line = table.concat(data or {}, "")
      if line:find("can't open") or line:find("No such") then
        notify("录音失败: " .. line, vim.log.levels.ERROR)
        M.recording = nil
      end
    end,
    on_exit = function()
      M.recording = nil
    end,
  })
  if M.recording <= 0 then
    notify("录音进程启动失败", vim.log.levels.ERROR)
    M.recording = nil
    return
  end
  notify("● 录音中… 再按一次 " .. M.opts.keys.toggle .. " 结束并转写")
end

function M.stop_and_transcribe()
  if not M.recording then
    return
  end
  vim.fn.jobstop(M.recording)
  M.recording = nil
  notify("…转写中")
  require("voiceinput.transcriber").transcribe(M.wav_path, function(text, err)
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    M.insert_text(text)
    notify("✓ " .. text)
  end)
end

function M.insert_text(text)
  text = M.opts.insert_opts.prefix .. text .. M.opts.insert_opts.suffix
  if text == "" then
    return
  end
  local lines = vim.split(text, "\n")
  vim.api.nvim_put(lines, "c", true, true)
end

function M.status()
  if M.recording then
    notify("● 录音中 → " .. M.wav_path)
  else
    notify("空闲")
  end
end

function M.resolve_model(name)
  return resolve(name)
end

return M

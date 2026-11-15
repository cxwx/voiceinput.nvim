local M = {}

local function check(pipeline, name)
  if vim.fn.executable(pipeline) == 1 then
    return nil, name .. ": " .. vim.fn.exepath(pipeline)
  end
  return name .. " 未找到（需要安装，或用 record_cmd/transcribe_cmd 配置替换）"
end

function M.check()
  local init = require("voiceinput")
  if not init.opts then
    -- 未 setup（如 lazy.nvim build 阶段）：只报告需要先 bootstrap
    local gdir = vim.g.voiceinput_data_dir
      or (vim.fn.stdpath("data") .. "/voiceinput")
    vim.notify(
      "[voiceinput] 尚未 setup，数据目录将是: " .. gdir
        .. "\n运行 :VoiceInputBootstrap 安装 venv 和模型，再重启/加载插件。",
      vim.log.levels.INFO)
    return false, {}
  end
  local opts = init.opts
  local report = {}

  -- python 与转写脚本
  local py_ok = vim.fn.filereadable(opts.python) == 1 or vim.fn.executable(opts.python) == 1
  table.insert(report, { "python", py_ok, opts.python .. (py_ok and "" or " 不存在") })
  if not py_ok then
    table.insert(report, { "提示", false, "先运行 :VoiceInputBootstrap 创建 venv 并下载模型" })
  end
  table.insert(report, {
    "transcribe script",
    vim.fn.filereadable(opts.script) == 1,
    opts.script,
  })
  -- sherpa_onnx 包
  local out = ""
  if py_ok then
    out = vim.fn.system(opts.python .. " -c 'import sherpa_onnx; print(sherpa_onnx.__version__)'")
  end
  table.insert(report, {
    "sherpa_onnx (python pkg)",
    py_ok and vim.v.shell_error == 0,
    py_ok and vim.trim(tostring(out)) or "python 不可用，跳过",
  })
  -- 模型文件
  for _, name in ipairs({ "tokens", "encoder", "decoder", "joiner" }) do
    local path = init.resolve_model(name)
    table.insert(report, { "model." .. name, vim.fn.filereadable(path) == 1, path })
  end
  -- 录音程序
  local rec_bin = opts.record_cmd:match("^%S+")
  local r_err = check(rec_bin, "record (" .. rec_bin .. ")")
  table.insert(report, { "record program", r_err == nil, r_err or rec_bin })

  local lines = { "", "voiceinput health:" }
  local ok = true
  for _, it in ipairs(report) do
    local mark = it[2] and "✓" or "✗"
    if not it[2] then
      ok = false
    end
    table.insert(lines, string.format("  %s %-26s %s", mark, it[1], it[3]))
  end
  vim.notify(table.concat(lines, "\n"), ok and vim.log.levels.INFO or vim.log.levels.WARN)
  return ok, report
end

return M

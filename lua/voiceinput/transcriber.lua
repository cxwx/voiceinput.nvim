local M = {}

-- 构建转写命令。优先用用户自定义 transcribe_cmd 模板，
-- 否则用 {python} {script} --wav … --tokens … 组合。
function M.build_cmd(wav_path)
  local opts = require("voiceinput").opts
  local init = require("voiceinput")
  local subs = {
    wav = wav_path,
    tokens = init.resolve_model("tokens"),
    encoder = init.resolve_model("encoder"),
    decoder = init.resolve_model("decoder"),
    joiner = init.resolve_model("joiner"),
    model = init.resolve_model("model"),
    python = opts.python,
    script = opts.script,
    preset = opts.model_preset,
  }
  local template = opts.transcribe_cmd
  if not template then
    if opts.model_preset == "sensevoice" then
      template = "{python} {script} --preset sensevoice --model {model} --tokens {tokens} --wav {wav}"
    else
      template = "{python} {script} --preset zh-en-zipformer"
        .. " --tokens {tokens} --encoder {encoder} --decoder {decoder} --joiner {joiner}"
        .. " --wav {wav}"
    end
  end
  local cmd = template:gsub("{(%w+)}", function(name)
    return subs[name] or ""
  end)
  return vim.fn.shellescape(cmd, true) -- 作为整条 shell 命令执行
end

function M.transcribe(wav_path, callback)
  local opts = require("voiceinput").opts
  local cmd = M.build_cmd(wav_path)
  local out = {}
  local errout = {}
  local job_opts = {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(out, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(errout, data or {})
    end,
    on_exit = function(_, code)
      local text = vim.trim(table.concat(out, "\n"))
      if code == 0 and text ~= "" then
        callback(text, nil)
      elseif code == 3 then
        callback(nil, "转写结果为空（没有识别到语音？）")
      else
        callback(nil, "转写失败 (exit "
          .. code .. "): " .. vim.trim(table.concat(errout, "\n")))
      end
    end,
  }
  -- env 仅在配置了非空条目时传递；jobstart 的 env 要求全部为字符串
  if opts.env and not vim.tbl_isempty(opts.env) then
    local env = {}
    for k, v in pairs(opts.env) do
      env[tostring(k)] = tostring(v)
    end
    job_opts.env = env
  end
  vim.fn.jobstart("/bin/sh -c " .. cmd, job_opts)
end

return M

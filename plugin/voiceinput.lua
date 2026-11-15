-- 未 setup 时也可用：bootstram 读 vim.g.voiceinput_data_dir，
-- 否则默认 stdpath("data")/voiceinput
vim.api.nvim_create_user_command("VoiceInputHealth", function()
  require("voiceinput.health").check()
end, {})

vim.api.nvim_create_user_command("VoiceInputBootstrap", function()
  require("voiceinput").bootstrap()
end, {})

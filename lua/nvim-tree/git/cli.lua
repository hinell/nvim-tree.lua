local notify = require "nvim-tree.notify"
local log = require "nvim-tree.log"
-- vim.loop got renamed in 0.10.0
-- ref: https://github.com/neovim/neovim/pull/22846
local uv = vim.loop or vim.uv

local M = {}

--- See h `uv.spawn-options` for full list of props
--- @class vim.uv.SpawnOptions
--- @field args string[] args to be passed to git command e.g. -C
--- @field env table|nil
--- @field cwd table|nil
--- @field detached boolean|nil detach process from parent
--- @field timeout number|nil timeout before hanged git process gets killed

--- A very lightweight generic git cli command wrapper powered by libuv;
--- it's probably worth to consider to import another library
--- @param uv_spawn_opts vim.uv.SpawnOptions uv.spaw like options
--- @param on_err_or_data fun(err: string|nil, data: string|nil) error handler callback
--- @param on_exit? fun(code: number, signal: number) error handler callback
--- @param on_timeout? fun(): nil called if process timedout
function M.cli(uv_spawn_opts, on_err_or_data, on_exit, on_timeout)

  if type(uv_spawn_opts) ~= "table" then
    error("uv_spawn_opts table is required", 2)
  end

  if type(uv_spawn_opts.args) ~= "table" then
    error("uv_spawn_opts.args table is required", 2)
  end

  if type(uv_spawn_opts.timeout) ~= "number" then
    uv_spawn_opts.timeout = 8000
  end

  local on_err_cb_type = type(on_err_or_data)
  if on_err_cb_type ~= "function" then
    error("on_err_or_data callback is required, got " .. on_err_cb_type, 2)
  end

  local process
  local process_exited = false
  local process_exit_code = 0
  local stdin = uv.new_pipe()
  local stdout = uv.new_pipe()
  local stderr = uv.new_pipe()

  uv_spawn_opts = vim.tbl_extend("keep", uv_spawn_opts, {
    stdio = { stdin, stdout, stderr },
  })

  local stream_context = { failed = false }
  local on_data = function(err, data)
    local failed = stream_context.failed or false
    if err then
      if not failed then
        stream_context.failed = err
        on_err_or_data(err, data)
      end
      ---@diagnostic disable-next-line: ambiguity-1
      notify.error("git" .. table.concat(uv_spawn_opts.args) .. " job has failed: " .. err or "")
    else
      on_err_or_data(nil, data)
    end
  end

  -- default exit handler; just reporting
  ---@diagnostic disable-next-line: redefined-local
  local _on_exit = function(process_exit_code, signal)
    process_exited = true
    if process_exit_code ~= 0 then
      log.line("git", "git " .. table.concat(uv_spawn_opts.args) .. " job has failed with %s exit code", process_exit_code)
    end
    -- Free FIFOs: uv library requires for handles to be closed upon exit
    -- Ref: https://docs.libuv.org/en/v1.x/guide/processes.html#spawning-child-processes
    stdin:shutdown(function()
      process:close()
    end)
    stdout:shutdown()
    stderr:shutdown()

    if on_exit then
      on_exit(process_exit_code, signal)
    end
  end

  process = uv.spawn("git", uv_spawn_opts, _on_exit)
  uv.read_start(stdout, vim.schedule_wrap(on_data))
  uv.read_start(stderr, vim.schedule_wrap(on_data))

  -- If git command takes too long to run, kill the process
  -- the option .timeout have to be explicitly set to activate this featureg;
  vim.defer_fn(function()
    if process_exited or stream_context.failed or (process and process:is_closing()) then
      return
    end
    local kill_exit_code = process:kill()
    if kill_exit_code == 0 then
      if on_timeout then
        on_timeout()
      end
    end
  end, uv_spawn_opts.timeout)
end

-- note: keep this in sync with M.cli

M.git = M.cli
-- This enables lua_lsp_server to provide the M.cli luadoc signature to M.git
do
  M.git = setmetatable({}, {
    ---@diagnostic disable-next-line: unused-local
    __call = function(_, ...)
      return M.cli(...)
    end,
  })
end

--- @class gitDefaultErrorHandlerOpts
--- @field name string
--- @param opts gitDefaultErrorHandlerOpts
function M.default_error_handler(opts)
  local name = opts and (" " .. opts.name .. " " ) or ""
  return function(err, data)
    if err then
      notify.error(("git" .. name .. "failed %s: %s"):format(err, data or ""))
    elseif not err and data then
      if data:match "^error:.*" or data:match "^fatal:.*" then
        notify.error(("git" .. name .. "failed %s"):format(data))
      end
    end
  end
end

--- @class gitOptions: vim.uv.SpawnOptions
--- @field args? string[]

--- Check if given path is tracked relative to cwd
--- @param path string file path
--- @param opts gitOptions
--- @param cb? fun(err: string|nil, data: string|nil): nil a callback
--- @param on_exit? fun(code, signal): nil
--- @param on_timeout? fun(): nil called if process timedout
function M.git.is_tracked(path, opts, cb, on_exit, on_timeout)
  local cwd = vim.fn.getcwd()
  local timeout = opts and opts.timeout or error "uv_spawn_opts is required"
  cb = cb or M.default_error_handler({ name = "is_tracked" })
  return M.cli({
    cwd = cwd,
    args = { "ls-files", "--error-unmatch", path },
    timeout = timeout,
  }, cb, on_exit, on_timeout)
end

--- git mv - move tracked path; call callback if successful
--- @param path_src string file to move; path may be cwd-relative 
--- @param path_dst string file desination path; may be cwd-relative
--- @param opts gitOptions
--- @param cb? fun(err, data): nil
--- @param on_exit? fun(code, signal): nil
--- @param on_timeout? fun(): nil called if process timedout
function M.git.mv(path_src, path_dst, opts, cb, on_exit, on_timeout)
  local timeout = opts and opts.timeout or error "uv_spawn_opts is required"
  local cwd = vim.fn.getcwd()
  cb = cb or M.default_error_handler({ name = "mv" })
  return M.cli({
    cwd = cwd,
    args = { "mv", path_src, path_dst },
    timeout = timeout,
  }, cb, on_exit, on_timeout)
end

--- git rm - remove tracked path; call callback if successful
--- @param path_src string file path to remove
--- @param opts gitOptions
--- @param cb? fun(err, data): nil
--- @param on_exit? fun(code, signal): nil
--- @param on_timeout? fun(): nil called if process timedout
function M.git.rm(path_src, opts, cb, on_exit, on_timeout)
  local timeout = opts and opts.timeout or error "uv_spawn_opts is required"
  local cwd = vim.fn.getcwd()
  cb = cb or M.default_error_handler({ name = "rm" })
  return M.cli({
    cwd = cwd,
    args = { "rm", path_src },
    timeout = timeout,
  },
  cb, on_exit, on_timeout)
end

return M

--!strict

local omp_process = {}

local MAX_RESPONSE_BYTES = 8 * 1024 * 1024
local LAUNCH_OVERHEAD_MS = 15000

local pending: { [string]: boolean } = {}

local function sweep()
   -- A plugin reload drops the callbacks of runs in flight, so their output files are removed here instead
   local ok, names = pcall(tern.fs.list, tern.plugin.data)
   if not ok then return end
   for _, name in names do
      local path = tern.plugin.data .. "\\" .. name
      if string.match(name, "^usage%-.+%.json$") and not pending[path] then
         pcall(tern.fs.remove, path)
      end
   end
end

function omp_process.run(argv: { string }, timeout_ms: number, callback: (ProcessResult, WindowCx?) -> ())
   if tern.runtime.os ~= "windows" then
      tern.process.run(argv, { timeout_ms = timeout_ms }, callback)
      return
   end

   local token = string.format("%d-%d", os.time(), math.random(1, 1000000000))
   local output = tern.plugin.data .. "\\usage-" .. token .. ".json"
   sweep()
   pending[output] = true
   local root = tern.getenv("SystemRoot") or "C:\\Windows"
   local helpers = tern.plugin.dir .. "\\helpers\\windows\\"
   local launcher = {
      root .. "\\System32\\wscript.exe",
      "//B",
      "//Nologo",
      helpers .. "launch-hidden.js",
      root .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      helpers .. "usage.ps1",
      "-Bin",
      argv[1],
      "-Action",
      if argv[3] == "invalidate" then "invalidate" else "usage",
      "-Output",
      output,
      "-TimeoutMs",
      tostring(timeout_ms),
   }
   tern.process.run(launcher, { timeout_ms = timeout_ms + LAUNCH_OVERHEAD_MS }, function(result: ProcessResult, cx: WindowCx?)
      local ok, text = pcall(tern.fs.read, output, MAX_RESPONSE_BYTES)
      pending[output] = nil
      pcall(tern.fs.remove, output)
      if result.timed_out or result.status ~= 0 or not ok then
         callback({ status = -1, stdout = "", stderr = "", timed_out = result.timed_out }, cx)
         return
      end
      local decoded, payload = pcall(tern.json.decode, text)
      if
         not decoded
         or type(payload) ~= "table"
         or type(payload.status) ~= "number"
         or type(payload.stdout) ~= "string"
         or type(payload.stderr) ~= "string"
         or type(payload.timed_out) ~= "boolean"
      then
         callback({ status = -1, stdout = "", stderr = "", timed_out = false }, cx)
         return
      end
      callback({ status = payload.status, stdout = payload.stdout, stderr = payload.stderr, timed_out = payload.timed_out }, cx)
   end)
end

return omp_process

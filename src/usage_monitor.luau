--!strict

local omp_process = require("./omp_process")

local usage_monitor = {}

export type Limit = {
   id: string,
   label: string,
   used_fraction: number?,
   amount: string,
   reset_at: number?,
   status: string,
   error: string?,
}

export type Account = {
   id: string,
   provider: string,
   label: string,
   plan: string?,
   fetched_at: number?,
   limits: { Limit },
   error: string?,
   disabled: boolean,
   reset_credits: number?,
}

export type Snapshot = {
   generated_at: number,
   accounts: { Account },
}

usage_monitor.KIND = "usage-monitor.usage"

local MAX_BYTES = 4 * 1024 * 1024
local MAX_ERROR_CHARS = 160
local USAGE_TIMEOUT_MS = 45000
local INVALIDATE_TIMEOUT_MS = 45000

local UNIT_SUFFIX: { [string]: string } = {
   tokens = " tokens",
   requests = " requests",
   credits = " credits",
   minutes = " min",
   bytes = " bytes",
   percent = "",
   usd = "",
   unknown = "",
}

local CODEX_PLANS: { [string]: string } = {
   free = "Free",
   plus = "Plus",
   pro = "Pro",
   prolite = "Pro Lite",
   team = "Team",
   business = "Business",
   enterprise = "Enterprise",
   edu = "Edu",
}

local PROVIDER_NAMES: { [string]: string } = {
   ["openai-codex"] = "OpenAI Codex",
   ["openai"] = "OpenAI",
   ["anthropic"] = "Anthropic",
   ["opencode-go"] = "OpenCode Go",
   ["opencode"] = "OpenCode",
   ["google"] = "Google",
   ["gemini"] = "Gemini",
   ["google-antigravity"] = "Google Antigravity",
   ["github-copilot"] = "GitHub Copilot",
   ["xai-oauth"] = "xAI",
   ["xai"] = "xAI",
   ["zai"] = "Z.ai",
   ["kimi"] = "Kimi",
   ["kimi-code"] = "Kimi Code",
   ["minimax-code"] = "MiniMax Code",
   ["muse-code"] = "Muse Code",
   ["cursor"] = "Cursor",
   ["devin"] = "Devin",
   ["factory-droid"] = "Factory Droid",
   ["cline-pass"] = "Cline Pass",
   ["charm-hyper"] = "Charm Hyper",
   ["synthetic"] = "Synthetic",
   ["umans"] = "Umans",
   ["ollama"] = "Ollama",
   ["commandcode"] = "CommandCode",
   ["alibaba-token-plan"] = "Alibaba Token Plan",
}

local function as_table(value: any): { [any]: any }?
   if type(value) ~= "table" then return nil end
   return (value :: { [any]: any })
end

local function as_array(value: any): { any }?
   if type(value) ~= "table" then return nil end
   return (value :: { any })
end

local function as_string(value: any): string?
   if type(value) == "string" and value ~= "" then return value end
   return nil
end

local function as_number(value: any): number?
   if type(value) ~= "number" then return nil end
   if value ~= value or value == math.huge or value == -math.huge then return nil end
   return value
end

local function sanitize(text: string): string
   local cleaned = (text:gsub("\27%[[%d;]*[A-Za-z]", ""))
   cleaned = (cleaned:gsub("%c", " "))
   cleaned = (cleaned:gsub("%s+", " "))
   cleaned = (cleaned:gsub("^%s+", ""))
   cleaned = (cleaned:gsub("%s+$", ""))
   if #cleaned > MAX_ERROR_CHARS then
      cleaned = string.sub(cleaned, 1, MAX_ERROR_CHARS - 1) .. "…"
   end
   return cleaned
end

local function duration_label(seconds: number): string
   local whole = math.max(0, math.floor(seconds))
   if whole < 60 then return tostring(whole) .. "s" end
   local minutes = whole // 60
   if minutes < 60 then return tostring(minutes) .. "m" end
   local hours = minutes // 60
   local rest_minutes = minutes % 60
   if hours < 24 then return if rest_minutes > 0 then tostring(hours) .. "h " .. tostring(rest_minutes) .. "m" else tostring(hours) .. "h" end
   local days = hours // 24
   local rest_hours = hours % 24
   if days < 7 and rest_hours > 0 then return tostring(days) .. "d " .. tostring(rest_hours) .. "h" end
   return tostring(days) .. "d"
end

local function compact_number(value: number): string
   local magnitude = math.abs(value)
   if magnitude >= 1e9 then return string.format("%.2fB", value / 1e9) end
   if magnitude >= 1e6 then return string.format("%.1fM", value / 1e6) end
   if magnitude >= 1e3 then return string.format("%.1fk", value / 1e3) end
   if value == math.floor(value) then return string.format("%d", value) end
   return string.format("%.2f", value)
end

local function format_amount(value: number, unit: string): string
   if unit == "usd" then return string.format("$%.2f", value) end
   return compact_number(value)
end

local function resolve_fraction(amount: { [any]: any }?): number?
   if not amount then return nil end
   local used_fraction = as_number(amount.usedFraction)
   if used_fraction then return used_fraction end
   local used = as_number(amount.used)
   local limit = as_number(amount.limit)
   if used and limit and limit > 0 then return used / limit end
   if as_string(amount.unit) == "percent" and used then return used / 100 end
   local remaining_fraction = as_number(amount.remainingFraction)
   if remaining_fraction then return math.max(0, 1 - remaining_fraction) end
   return nil
end

local function resolve_status(source: { [any]: any }, fraction: number?): string
   local raw = as_string(source.status)
   if raw and raw ~= "unknown" then return raw end
   if not fraction then return "unknown" end
   if fraction >= 1 then return "exhausted" end
   if fraction >= 0.8 then return "warning" end
   return "ok"
end

local function describe_amount(amount: { [any]: any }?, unit: string, fraction: number?): string
   if not amount then return "" end
   local suffix = UNIT_SUFFIX[unit] or ""
   local absolute = unit ~= "percent" and unit ~= "unknown"
   if not absolute then return "" end
   local used = as_number(amount.used)
   local limit = as_number(amount.limit)
   local remaining = as_number(amount.remaining)
   if used and limit then return format_amount(used, unit) .. " / " .. format_amount(limit, unit) .. suffix end
   if remaining then return format_amount(remaining, unit) .. suffix .. " left" end
   if used and not fraction then return format_amount(used, unit) .. suffix .. " used" end
   return ""
end

local function limit_title(source: { [any]: any }, window: { [any]: any }?, scope: { [any]: any }?, fallback: string): string
   local label = as_string(source.label) or as_string(window and window.label) or as_string(scope and scope.windowId) or fallback
   local lower = string.lower(label)
   local tier = as_string(scope and scope.tier)
   if tier and not string.find(lower, string.lower(tier), 1, true) then
      label = label .. " (" .. tier .. ")"
      lower = string.lower(label)
   end
   local window_label = as_string(window and window.label) or as_string(scope and scope.windowId)
   if window_label and string.lower(window_label) ~= "quota window" and not string.find(lower, string.lower(window_label), 1, true) then
      label = label .. " (" .. window_label .. ")"
   end
   return label
end

local function tolerant_error(value: any): string?
   if type(value) == "string" and value ~= "" then return sanitize(value) end
   if type(value) == "table" then
      local message = as_string((value :: { [any]: any }).message)
      if message then return sanitize(message) end
   end
   return nil
end

local function report_error(report: { [any]: any }): string?
   local single = tolerant_error(report.error)
   if single then return single end
   local many = as_array(report.errors)
   if not many then return nil end
   local parts: { string } = {}
   for index = 1, #many do
      local item = tolerant_error(many[index])
      if item then
         parts[#parts + 1] = item
      end
   end
   if #parts == 0 then return nil end
   return sanitize(table.concat(parts, " · "))
end

local function short_cause(cause: string): string
   local description = string.match(cause, 'error_description[^:]*:%s*\\?"([^"\\]+)')
   if description then return description end
   local stripped = (cause:gsub("^%s*[Oo]auth refresh failed:%s*", ""))
   return string.match(stripped, "^[^;\r\n]*") or stripped
end

local function unique_id(seen: { [string]: number }, base: string): string
   local count = seen[base] or 0
   seen[base] = count + 1
   if count == 0 then return base end
   return base .. " #" .. tostring(count + 1)
end

local function identity_base(source: { [any]: any }): string?
   return as_string(source.accountId) or as_string(source.email) or as_string(source.projectId) or as_string(source.enterpriseUrl) or as_string(source.orgId)
end

local function account_label(source: { [any]: any }, index: number): string
   local base = as_string(source.email) or as_string(source.accountId) or as_string(source.projectId)
   local org = as_string(source.orgName) or as_string(source.orgId)
   if base and org and org ~= base then return base .. " · " .. org end
   if base then return base end
   if org then return org end
   return "Account " .. tostring(index)
end

local function build_limit(raw: any, index: number): Limit?
   local source = as_table(raw)
   if not source then return nil end
   local window = as_table(source.window)
   local scope = as_table(source.scope)
   local amount = as_table(source.amount)
   local id = as_string(source.id) or as_string(window and window.id) or ("limit-" .. tostring(index))
   local fraction = resolve_fraction(amount)
   local unit = as_string(amount and amount.unit) or "unknown"
   return {
      id = id,
      label = limit_title(source, window, scope, id),
      used_fraction = fraction,
      amount = describe_amount(amount, unit, fraction),
      reset_at = as_number(window and window.resetsAt),
      status = resolve_status(source, fraction),
      error = tolerant_error(source.error),
   }
end

local function account_plan(provider: string, metadata: { [any]: any }): string?
   local plan = as_string(metadata.planType)
   if provider == "openai-codex" then
      -- Codex can report planType "free" for a paid plan, so prefer the plan named in orgName
      local subscription = as_string(metadata.orgName)
      if subscription then
         local known = CODEX_PLANS[string.lower(subscription)]
         if known then return known end
      end
      if plan then return CODEX_PLANS[string.lower(plan)] or plan end
   end
   return plan
end

local function build_report_account(raw: any, index: number, seen: { [string]: number }): Account?
   local report = as_table(raw)
   if not report then return nil end
   local provider = as_string(report.provider)
   if not provider then return nil end
   local meta: { [any]: any } = as_table(report.metadata) or {}
   local limits: { Limit } = {}
   local raw_limits = as_array(report.limits)
   if raw_limits then
      for position = 1, #raw_limits do
         local limit = build_limit(raw_limits[position], position)
         if limit then
            limits[#limits + 1] = limit
         end
      end
   end
   local identity = as_string(meta.accountId) or as_string(meta.email) or as_string(meta.projectId)
   local base = provider .. ":" .. (identity or ("account-" .. tostring(index)))
   local credits = as_table(report.resetCredits)
   return {
      id = unique_id(seen, base),
      provider = provider,
      label = account_label(meta, index),
      plan = account_plan(provider, meta),
      fetched_at = as_number(report.fetchedAt),
      limits = limits,
      error = report_error(report),
      disabled = false,
      reset_credits = as_number(credits and credits.availableCount),
   }
end

local function build_identity_account(raw: any, index: number, seen: { [string]: number }): Account?
   local source = as_table(raw)
   if not source then return nil end
   local provider = as_string(source.provider)
   if not provider then return nil end
   local kind = as_string(source.type)
   local identity = identity_base(source)
   local base = provider .. ":" .. (identity or (if kind == "api_key" then "api-key-" else "account-") .. tostring(index))
   return {
      id = unique_id(seen, base),
      provider = provider,
      label = if kind == "api_key" and not identity then "API key" else account_label(source, index),
      limits = {},
      error = nil,
      disabled = false,
   }
end

local function build_disabled_account(raw: any, index: number, seen: { [string]: number }): Account?
   local source = as_table(raw)
   if not source then return nil end
   local provider = as_string(source.provider)
   if not provider then return nil end
   local identity = identity_base(source)
   local base = provider .. ":" .. (identity or ("disabled-" .. tostring(index)))
   local cause = as_string(source.cause)
   return {
      id = unique_id(seen, base),
      provider = provider,
      label = account_label(source, index),
      limits = {},
      error = if cause then sanitize(short_cause(cause)) else "Sign in again to restore this account.",
      disabled = true,
   }
end

local function distinct_labels(accounts: { Account })
   local totals: { [string]: number } = {}
   for _, account in accounts do
      local key = account.provider .. "\1" .. account.label
      totals[key] = (totals[key] or 0) + 1
   end
   local used: { [string]: number } = {}
   for _, account in accounts do
      local key = account.provider .. "\1" .. account.label
      if (totals[key] or 0) > 1 then
         local count = (used[key] or 0) + 1
         used[key] = count
         account.label = account.label .. " #" .. tostring(count)
      end
   end
end

local function decode_payload(text: string): any
   local body = text
   if string.sub(body, 1, 3) == "\239\187\191" then
      body = string.sub(body, 4)
   end
   body = string.match(body, "^%s*(.*%S)") or body
   local ok, decoded = pcall(tern.json.decode, body)
   if ok then return decoded end
   return nil
end

function usage_monitor.parse(text: string): (Snapshot?, string?)
   if type(text) ~= "string" or text == "" then return nil, "omp returned no usage data." end
   if #text > MAX_BYTES then return nil, "omp returned more data than expected." end
   local payload = as_table(decode_payload(text))
   if not payload then return nil, "omp returned data that couldn't be read." end
   local reports = as_array(payload.reports)
   if not reports then
      local message = as_string(payload.error) or as_string(payload.message)
      if message then return nil, sanitize(message) end
      return nil, "omp returned an unexpected usage shape."
   end

   local seen: { [string]: number } = {}
   local accounts: { Account } = {}
   for index = 1, #reports do
      local account = build_report_account(reports[index], index, seen)
      if account then
         accounts[#accounts + 1] = account
      end
   end
   local unreported = as_array(payload.accountsWithoutUsage)
   if unreported then
      for index = 1, #unreported do
         local account = build_identity_account(unreported[index], index, seen)
         if account then
            accounts[#accounts + 1] = account
         end
      end
   end
   local disabled = as_array(payload.disabledCredentials)
   if disabled then
      for index = 1, #disabled do
         local account = build_disabled_account(disabled[index], index, seen)
         if account then
            accounts[#accounts + 1] = account
         end
      end
   end

   distinct_labels(accounts)
   table.sort(accounts, function(left: Account, right: Account): boolean
      if left.provider ~= right.provider then return left.provider < right.provider end
      if left.label ~= right.label then return left.label < right.label end
      return left.id < right.id
   end)

   return {
      generated_at = as_number(payload.generatedAt) or (os.time() * 1000),
      accounts = accounts,
   }
end

local function omp_bin(): string
   local override = tern.getenv("OMP_USAGE_BIN")
   if type(override) == "string" and override ~= "" then return override end
   return if tern.runtime.os == "windows" then "omp.exe" else "omp"
end

local function usage_failure_message(result: ProcessResult): string
   local stderr = if type(result.stderr) == "string" then result.stderr else ""
   if string.find(stderr, "No credentials found", 1, true) then return "No omp accounts found. Sign in with omp, then refresh." end
   if string.find(stderr, "providers without a usage endpoint", 1, true) then return "Your omp accounts don't support usage reporting." end
   if result.status == 0 then return "omp reported no usage data." end
   return "omp usage failed (exit " .. tostring(result.status) .. "). Check your accounts in omp and try again."
end

local function start_failure_message(err: any): string
   local text = if type(err) == "string" then string.lower(err) else ""
   if string.find(text, "ios", 1, true) or string.find(text, "not available", 1, true) then return "omp usage isn't available on this device." end
   if
      string.find(text, "cannot find", 1, true)
      or string.find(text, "no such file", 1, true)
      or string.find(text, "not found", 1, true)
   then
      return "omp wasn't found. Install omp, or set OMP_USAGE_BIN to its path."
   end
   return "Couldn't start omp usage."
end

function usage_monitor.fetch(force: boolean, done: (Snapshot?, string?) -> ()): ()
   local finished = false
   local function finish(snapshot: Snapshot?, message: string?)
      if finished then return end
      finished = true
      done(snapshot, message)
   end

   local bin = omp_bin()

   local function run_usage()
      local argv = { bin, "usage", "--json", "--no-extensions" }
      local ok, err = pcall(function()
         omp_process.run(argv, USAGE_TIMEOUT_MS, function(result: ProcessResult, _cx: WindowCx?)
            if result.timed_out then
               finish(nil, "omp usage took too long to answer. Try again.")
               return
            end
            local stdout = if type(result.stdout) == "string" then result.stdout else ""
            if result.status ~= 0 or stdout == "" then
               finish(nil, usage_failure_message(result))
               return
            end
            local snapshot, message = usage_monitor.parse(stdout)
            finish(snapshot, message)
         end)
      end)
      if not ok then
         finish(nil, start_failure_message(err))
      end
   end

   if not force then
      run_usage()
      return
   end

   local argv = { bin, "usage", "invalidate", "--no-extensions" }
   local ok, err = pcall(function()
      omp_process.run(argv, INVALIDATE_TIMEOUT_MS, function(result: ProcessResult, _cx: WindowCx?)
         if result.timed_out or result.status ~= 0 then
            finish(nil, "Couldn't invalidate omp's usage cache. Refresh failed; try again.")
            return
         end
         run_usage()
      end)
   end)
   if not ok then
      finish(nil, start_failure_message(err))
   end
end

function usage_monitor.age(timestamp_ms: number?, now_s: number): string
   if not timestamp_ms or timestamp_ms <= 0 then return "never" end
   local seconds = now_s - timestamp_ms / 1000
   if seconds < 5 then return "just now" end
   return duration_label(seconds) .. " ago"
end

function usage_monitor.reset(timestamp_ms: number?, now_s: number): string
   if not timestamp_ms or timestamp_ms <= 0 then return "" end
   local seconds = timestamp_ms / 1000 - now_s
   if seconds <= 0 then return "" end
   return "resets in " .. duration_label(seconds)
end

function usage_monitor.percent(fraction: number?): string
   if not fraction then return "" end
   return tostring(math.floor(fraction * 100 + 0.5)) .. "%"
end

function usage_monitor.provider_name(id: string): string
   local known = PROVIDER_NAMES[id]
   if known then return known end
   local parts: { string } = {}
   for part in string.gmatch(id, "[^-_]+") do
      parts[#parts + 1] = string.upper(string.sub(part, 1, 1)) .. string.sub(part, 2)
   end
   if #parts == 0 then return id end
   return table.concat(parts, " ")
end

function usage_monitor.cut(text: string, width: number): string
   if width < 1 then return "" end
   local length = utf8.len(text)
   if not length or length <= width then return text end
   local stop = utf8.offset(text, width) or #text
   return string.sub(text, 1, stop - 1) .. "…"
end

return usage_monitor

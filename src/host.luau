--!strict

local settings = require("./settings")
local usage_monitor = require("./usage_monitor")

local ui = tern.ui

type Snapshot = usage_monitor.Snapshot
type Account = usage_monitor.Account
type Limit = usage_monitor.Limit
type Settings = settings.Settings

type Block = {
   context: BlockCx,
   account: string,
   compact: boolean,
   settings_open: boolean,
   rendered: string?,
}

type Entry = {
   account: Account,
   ordinal: number,
   index: number,
   name: string,
   peak: number,
}

type LimitModel = {
   id: string,
   label: string,
   percent: string,
   usage: string,
   amount: string,
   reset: string,
   fraction: number?,
   shown: number?,
   tone: string?,
   error: string?,
}

type AccountModel = {
   id: string,
   name: string,
   label: string,
   display_name: string,
   plan: string?,
   age: string,
   error: string?,
   reset_credits: number?,
   disabled: boolean,
   empty: boolean,
   selected: boolean,
   limits: { LimitModel },
}

type Model = {
   state: string,
   message: string?,
   stale: string?,
   fetching: boolean,
   generated: string?,
   total: number,
   shown: number,
   selected: string,
   compact: boolean,
   settings_open: boolean,
   all_hidden: boolean,
   settings: Settings,
   accounts: { AccountModel },
}

local TICK_MS = 1000
local WARN_FRACTION = 0.75
local BAD_FRACTION = 0.9
local NARROW_COLS = 60
local ALL = "all"
local INTERVAL_LABELS: { [number]: string } = { [30] = "30s", [60] = "1m", [120] = "2m", [300] = "5m", [900] = "15m", [0] = "Manual" }
local ORDER_LABELS: { [string]: string } = { omp = "omp order", usage = "Highest usage", name = "Name" }

local blocks: { [number]: Block } = {}

local snapshot: Snapshot? = nil
local refresh_error: string? = nil
local fetching = false
local last_attempt = -math.huge
local loop: TimerHandle? = nil

local function with(node: Node, props: { [string]: any }): Node
   local merged: { [string]: any } = node.p or {}
   for name, prop in props do
      merged[name] = prop
   end
   node.p = merged
   return node
end

local function link(key: string, label: string, act: string, title: string, on: boolean?): Node
   local role = "usage-monitor-usage__link"
   if on then
      role ..= " usage-monitor-usage__link--on"
   end
   return with(ui.text(label), { key = key, role = role, title = title, actions = { click = act } })
end

local function limit_tone(limit: Limit): string?
   local fraction = limit.used_fraction
   if not fraction then return nil end
   if fraction >= BAD_FRACTION then return "error" end
   if fraction >= WARN_FRACTION then return "warning" end
   return nil
end

local function display_name(account: Account, ordinal: number): string
   local provider = usage_monitor.provider_name(account.provider)
   local display = if account.provider == "openai-codex" then "Codex" else provider
   local plan = account.plan
   if plan and string.lower(plan) ~= string.lower(provider) then
      display ..= " " .. string.upper(string.sub(plan, 1, 1)) .. string.sub(plan, 2)
   end
   return display .. " · Account " .. tostring(ordinal)
end

local function peak(account: Account): number
   local highest = -1
   for _, limit in account.limits do
      local fraction = limit.used_fraction
      if fraction and fraction > highest then
         highest = fraction
      end
   end
   return highest
end

local function entries(options: Settings, with_hidden: boolean): { Entry }
   local listed: { Entry } = {}
   if not snapshot then return listed end
   local counts: { [string]: number } = {}
   for index, account in snapshot.accounts do
      local ordinal = (counts[account.provider] or 0) + 1
      counts[account.provider] = ordinal
      if with_hidden or not options.hidden[account.id] then
         listed[#listed + 1] = { account = account, ordinal = ordinal, index = index, name = display_name(account, ordinal), peak = peak(account) }
      end
   end
   return listed
end

local function ordered(options: Settings): { Entry }
   local listed = entries(options, false)
   if options.order == "usage" then
      table.sort(listed, function(a: Entry, b: Entry): boolean
         if a.peak ~= b.peak then return a.peak > b.peak end
         return a.index < b.index
      end)
   elseif options.order == "name" then
      table.sort(listed, function(a: Entry, b: Entry): boolean
         local left, right = string.lower(a.name), string.lower(b.name)
         if left ~= right then return left < right end
         return a.index < b.index
      end)
   end
   return listed
end

local function resolve(selected: string, listed: { Entry }): string
   for _, entry in listed do
      if entry.account.id == selected then return selected end
   end
   return ALL
end

local function limit_model(limit: Limit, now_s: number, remaining: boolean): LimitModel
   local used = limit.used_fraction
   local shown = if used and remaining then math.max(0, 1 - used) else used
   local percent = usage_monitor.percent(shown)
   local usage = if percent == "" then "usage unknown" elseif remaining then percent .. " left" else percent .. " used"
   return {
      id = limit.id,
      label = limit.label,
      percent = percent,
      usage = usage,
      amount = limit.amount,
      reset = usage_monitor.reset(limit.reset_at, now_s),
      fraction = used,
      shown = shown,
      tone = limit_tone(limit),
      error = limit.error,
   }
end

local function account_model(entry: Entry, selected: string, now_s: number, remaining: boolean): AccountModel
   local account = entry.account
   local current: AccountModel = {
      id = account.id,
      name = usage_monitor.provider_name(account.provider),
      label = account.label,
      display_name = entry.name,
      plan = account.plan,
      age = usage_monitor.age(account.fetched_at, now_s),
      error = account.error,
      disabled = account.disabled,
      reset_credits = account.reset_credits,
      empty = false,
      selected = account.id == selected,
      limits = {},
   }
   for _, limit in account.limits do
      current.limits[#current.limits + 1] = limit_model(limit, now_s, remaining)
   end
   current.empty = #current.limits == 0 and not account.error and not account.disabled
   return current
end

local function model(block: Block, options: Settings): Model
   local now_s = os.time()
   local listed = ordered(options)
   local selected = resolve(block.account, listed)
   local current: Model = {
      state = "empty",
      message = nil,
      stale = nil,
      fetching = fetching,
      generated = nil,
      total = 0,
      shown = 0,
      selected = selected,
      compact = block.compact,
      settings_open = block.settings_open,
      all_hidden = false,
      settings = options,
      accounts = {},
   }

   if not snapshot then
      if refresh_error then
         current.state = "error"
         current.message = refresh_error
      else
         current.state = "loading"
      end
      return current
   end

   current.generated = usage_monitor.age(snapshot.generated_at, now_s)
   current.stale = refresh_error
   current.total = #snapshot.accounts
   for _, entry in listed do
      if selected == ALL or entry.account.id == selected then
         current.accounts[#current.accounts + 1] = account_model(entry, selected, now_s, options.remaining)
      end
   end
   current.shown = #current.accounts
   if current.shown == 0 then
      current.state = "empty"
      current.all_hidden = current.total > 0 and #listed == 0
      current.message = if current.total == 0 then "No accounts reported." elseif current.all_hidden then "All accounts are hidden." else "That account is no longer reported."
   else
      current.state = "data"
   end
   return current
end

local function signature(current: Model): string
   local parts: { string } = {
      current.state,
      current.selected,
      tostring(current.compact),
      tostring(current.settings_open),
      tostring(current.all_hidden),
      settings.signature(current.settings),
      tostring(current.fetching),
      current.message or "",
      current.stale or "",
      current.generated or "",
      tostring(current.total),
      tostring(current.shown),
   }
   for _, account in current.accounts do
      parts[#parts + 1] = table.concat({
         account.id,
         account.name,
         account.label,
         account.display_name,
         account.plan or "",
         account.age,
         account.error or "",
         tostring(account.reset_credits),
         tostring(account.disabled),
         tostring(account.empty),
         tostring(account.selected),
      }, "\1")
      for _, limit in account.limits do
         parts[#parts + 1] = table.concat({
            limit.id,
            limit.label,
            limit.percent,
            limit.usage,
            limit.amount,
            limit.reset,
            limit.tone or "",
            limit.error or "",
            tostring(limit.fraction),
            tostring(limit.shown),
         }, "\1")
      end
   end
   return table.concat(parts, "\2")
end

local function render_all()
   local options = settings.load()
   for _, block in blocks do
      local current = signature(model(block, options))
      if block.rendered ~= current then
         block.rendered = current
         block.context:render()
      end
   end
end

local function refresh(force: boolean)
   if fetching then return end
   fetching = true
   last_attempt = tern.now()
   render_all()

   local ok = pcall(function()
      usage_monitor.fetch(force, function(next_snapshot: Snapshot?, message: string?)
         fetching = false
         last_attempt = tern.now()
         if next_snapshot then
            snapshot = next_snapshot
            refresh_error = nil
         else
            refresh_error = message or "Couldn't read usage."
         end
         render_all()
      end)
   end)
   if not ok then
      fetching = false
      refresh_error = "Couldn't start the usage check."
      render_all()
   end
end

local function cycle(block: Block, delta: number)
   local order: { string } = { ALL }
   for _, entry in ordered(settings.load()) do
      order[#order + 1] = entry.account.id
   end
   local index = 1
   for position, id in order do
      if id == block.account then
         index = position
      end
   end
   index = ((index - 1 + delta) % #order) + 1
   block.account = order[index]
end

local function act(block: Block, name: string, value: string?)
   if name == "refresh" then
      refresh(true)
   elseif name == "all" then
      block.account = ALL
   elseif name == "compact" then
      block.compact = not block.compact
   elseif name == "options" then
      block.settings_open = not block.settings_open
   elseif name == "prev" then
      cycle(block, -1)
   elseif name == "next" then
      cycle(block, 1)
   elseif name == "pick" and value and value ~= "" then
      block.account = value
   end
end

local function change(block: Block, name: string, value: string, checked: boolean)
   local options = settings.load()
   if name == "account" then
      if checked then
         options.hidden[value] = nil
      else
         options.hidden[value] = true
      end
   elseif name == "interval" then
      local seconds = tonumber(value)
      if not seconds then return end
      options.interval_s = seconds
   elseif name == "usage" then
      options.remaining = value == "remaining"
   elseif name == "bar_colors" then
      options.bar_colors = checked
   elseif name == "percent_colors" then
      options.percent_colors = checked
   elseif name == "show_age" then
      options.show_age = checked
   elseif name == "view" then
      options.compact = value == "compact"
      block.compact = options.compact
   elseif name == "order" then
      options.order = value
   else
      return
   end
   if not settings.save(options) then
      block.context:toast("error", "Usage Monitor", "Couldn't save settings.")
   end
   render_all()
end

local function tick()
   loop = nil
   local live: { [number]: boolean } = {}
   for _, pane in tern.pane.list() do
      live[pane.pane] = true
   end
   for pane in blocks do
      if not live[pane] then
         blocks[pane] = nil
      end
   end
   if not next(blocks) then return end
   local interval_ms = settings.load().interval_s * 1000
   local due = if interval_ms > 0 then tern.now() - last_attempt >= interval_ms else not snapshot and not refresh_error
   if not fetching and due then
      refresh(false)
   end
   render_all()
   loop = tern.timer(TICK_MS, tick)
end

local function start_loop()
   if not loop then
      loop = tern.timer(0, tick)
   end
end

local function selection_label(current: Model): string
   if current.selected == ALL then return "All" end
   for _, entry in entries(current.settings, false) do
      if entry.account.id == current.selected then
         local name = if entry.account.provider == "openai-codex" then "Codex" else usage_monitor.provider_name(entry.account.provider)
         return name .. " " .. tostring(entry.ordinal)
      end
   end
   return "All"
end

local function tone_token(tone: string?): string?
   return if tone == "error" or tone == "warning" then tone else nil
end

local function short_limit_label(label: string): string
   local text = string.lower(label)
   text = string.gsub(text, "^claude%s+", "")
   text = string.gsub(text, "%s+limit$", "")
   text = string.gsub(text, "(%d+)%s*hours?", "%1h")
   text = string.gsub(text, "(%d+)%s*days?", "%1d")
   text = string.gsub(text, "^weekly$", "7d")
   text = string.gsub(text, "^monthly$", "month")
   return usage_monitor.cut(text, 12)
end

local function short_reset(reset: string): string
   return (string.gsub(reset, "^resets in ", ""))
end

local function limit_tooltip(limit: LimitModel): string
   local tooltip = limit.label .. " · " .. limit.usage
   if limit.amount ~= "" then
      tooltip ..= "\n" .. limit.amount
   end
   if limit.reset ~= "" then
      tooltip ..= "\n" .. limit.reset
   end
   if limit.error then
      tooltip ..= "\n" .. limit.error
   end
   return tooltip
end

local function account_tooltip(account: AccountModel): string
   local tooltip = account.name .. " · " .. account.label .. "\nChecked " .. account.age
   if account.reset_credits and account.reset_credits > 0 then
      tooltip ..= "\n" .. tostring(account.reset_credits) .. (if account.reset_credits == 1 then " reset credit" else " reset credits")
   end
   return tooltip
end

local function account_problem(account: AccountModel): string?
   if account.error and account.error ~= "" then return account.error end
   if account.disabled then return "Account disabled" end
   if account.empty then return "No usage reported" end
   return nil
end

local function meter(limit: LimitModel, colors: boolean): Node
   -- Tern's meter sweeps from 0 whenever it mounts, so draw a plain bar that only eases on change
   local shown, used = limit.shown, limit.fraction
   if not shown or not used then return with(ui.text(""), { key = "bar", role = "usage-monitor-usage__bar usage-monitor-usage__bar--unknown", grow = 1 }) end
   local tint = if colors then "usage-monitor-usage__fill--l" .. tostring(math.clamp(math.floor(used * 10), 0, 10)) else "usage-monitor-usage__fill--plain"
   return ui.el("div", { key = "bar", role = "usage-monitor-usage__bar", grow = 1 }, {
      ui.el("div", {
         key = "fill",
         role = "usage-monitor-usage__fill " .. tint,
         basis = math.clamp(shown, 0, 1),
      }),
   })
end

local function percent_text(limit: LimitModel, colors: boolean, long: boolean): Span
   if limit.percent == "" then return ui.span("—", "dim") end
   local text = if long then limit.usage else limit.percent
   local token = if colors then tone_token(limit.tone) else nil
   return if token then ui.span(text, token) else ui.span(text)
end

local function compact_limit(limit: LimitModel, options: Settings): Node
   return with(ui.col({
      with(ui.text({ ui.span(short_limit_label(limit.label) .. " ", "dim"), percent_text(limit, options.percent_colors, false) }), {
         key = "value",
         role = "usage-monitor-usage__quota-value",
         truncate = "end",
      }),
      meter(limit, options.bar_colors),
   }), { key = "lim-" .. limit.id, role = "usage-monitor-usage__quota", title = limit_tooltip(limit), grow = 1, basis = 0 })
end

local function compact_account(account: AccountModel, options: Settings): Node
   local children: { Node } = {
      with(ui.text(account.display_name), { key = "identity", role = "usage-monitor-usage__name", truncate = "end" }),
   }
   local limits: { Node } = {}
   for _, limit in account.limits do
      limits[#limits + 1] = compact_limit(limit, options)
   end
   if #limits > 0 then
      children[#children + 1] = with(ui.row(limits), { key = "limits", role = "usage-monitor-usage__quotas" })
   end
   local problem = account_problem(account)
   if problem then
      children[#children + 1] = with(ui.text(ui.span(problem, "dim")), { key = "problem", truncate = "end", title = problem })
   end
   return with(ui.col(children), {
      key = "summary-" .. account.id,
      role = "usage-monitor-usage__summary",
      title = account_tooltip(account),
      actions = { click = "pick=" .. account.id },
   })
end

local function detail_limit(limit: LimitModel, narrow: boolean, options: Settings): Node
   local pct_role = "usage-monitor-usage__cell-pct"
   if options.remaining then
      pct_role ..= " usage-monitor-usage__cell-pct--wide"
   end
   local cells: { Node } = {
      with(ui.text(ui.span(short_limit_label(limit.label), "dim")), { key = "label", role = "usage-monitor-usage__cell-label" }),
      meter(limit, options.bar_colors),
      with(ui.text(percent_text(limit, options.percent_colors, options.remaining)), { key = "pct", role = pct_role }),
   }
   if not narrow then
      cells[#cells + 1] = with(ui.text(ui.span(short_reset(limit.reset), "dim")), { key = "reset", role = "usage-monitor-usage__cell-reset" })
   end
   return with(ui.row(cells), { key = "lim-" .. limit.id, role = "usage-monitor-usage__limit", title = limit_tooltip(limit) })
end

local function detail_account(account: AccountModel, narrow: boolean, options: Settings): Node
   local meta = account.age
   if account.reset_credits and account.reset_credits > 0 then
      meta ..= " · " .. tostring(account.reset_credits) .. (if account.reset_credits == 1 then " reset credit" else " reset credits")
   end
   local children: { Node } = {
      with(ui.row({
         with(ui.text(account.display_name), { key = "name", role = "usage-monitor-usage__name", grow = 1, truncate = "end" }),
         with(ui.text(ui.span(meta, "dim")), { key = "meta", role = "usage-monitor-usage__meta" }),
      }), { key = "head", role = "usage-monitor-usage__account-head" }),
   }
   for _, limit in account.limits do
      children[#children + 1] = detail_limit(limit, narrow, options)
   end
   local problem = account_problem(account)
   if problem then
      children[#children + 1] = with(ui.text(ui.span(problem, "dim")), { key = "problem", title = problem })
   end
   return with(ui.col(children), {
      key = "acct-" .. account.id,
      role = "usage-monitor-usage__account",
      title = account_tooltip(account),
      actions = { click = "pick=" .. account.id },
   })
end

local function notice(current: Model): Node?
   local stale = current.stale
   if not stale or not current.generated then return nil end
   return with(ui.row({
      with(ui.text(ui.span("Couldn't refresh · showing data from " .. current.generated, "warning")), {
         key = "text",
         grow = 1,
         truncate = "end",
         title = stale,
      }),
      link("retry", "Retry", "refresh", "Try again"),
   }), { key = "notice", role = "usage-monitor-usage__notice" })
end

local function body(current: Model, narrow: boolean): Node
   if current.state == "loading" then
      return with(ui.col({
         with(ui.text(ui.span("Checking usage…", "dim")), { key = "message" }),
      }), { key = "body", role = "usage-monitor-usage__state" })
   end

   if current.state == "error" then
      return with(ui.col({
         with(ui.text(ui.span("Couldn't load usage", "error")), { key = "title" }),
         with(ui.text(ui.span(current.message or "The usage check failed.", "dim")), { key = "message" }),
         with(ui.row({ link("retry", "Retry", "refresh", "Try again") }), { key = "actions" }),
      }), { key = "body", role = "usage-monitor-usage__state" })
   end

   if current.state == "empty" then
      local action = if current.all_hidden then link("settings", "Settings", "options", "Choose accounts to show (s)") else link("check", "Check now", "refresh", "Check usage")
      return with(ui.col({
         with(ui.text(ui.span(current.message or "No usage data yet.", "dim")), { key = "message" }),
         with(ui.row({ action }), { key = "actions" }),
      }), { key = "body", role = "usage-monitor-usage__state" })
   end

   local rows: { Node } = {}
   for _, account in current.accounts do
      rows[#rows + 1] = compact_account(account, current.settings)
      if not current.compact then
         rows[#rows + 1] = detail_account(account, narrow, current.settings)
      end
   end
   return with(ui.col(rows), { key = "body", role = "usage-monitor-usage__accounts" })
end

local function option(key: string, kind: string, name: string, value: string, label: string, checked: boolean): Node
   return ui.el("label", { key = key, role = "usage-monitor-usage__option" }, {
      ui.el("input", { key = "control", type = kind, name = name, value = value, checked = checked }),
      ui.el("span", { key = "text", text = label }),
   })
end

local function group(key: string, title: string, options: { Node }, stacked: boolean?): Node
   local list = if stacked then ui.col(options) else with(ui.row(options), { wrap = true })
   return with(ui.col({
      with(ui.text(ui.span(title, "dim")), { key = "title" }),
      with(list, { key = "options", role = "usage-monitor-usage__options" }),
   }), { key = key, role = "usage-monitor-usage__group" })
end

local function settings_page(current: Model): Node
   local options = current.settings
   local accounts: { Node } = {}
   for _, entry in entries(options, true) do
      local id = entry.account.id
      accounts[#accounts + 1] = option("acct-" .. id, "checkbox", "account", id, entry.name, not options.hidden[id])
   end
   if #accounts == 0 then
      accounts[1] = with(ui.text(ui.span("No accounts reported yet.", "dim")), { key = "none" })
   end
   local intervals: { Node } = {}
   for _, seconds in settings.INTERVALS do
      intervals[#intervals + 1] = option("every-" .. tostring(seconds), "radio", "interval", tostring(seconds), INTERVAL_LABELS[seconds], options.interval_s == seconds)
   end
   local orders: { Node } = {}
   for _, order in settings.ORDERS do
      orders[#orders + 1] = option("order-" .. order, "radio", "order", order, ORDER_LABELS[order], options.order == order)
   end
   return with(ui.col({
      group("accounts", "Accounts", accounts, true),
      group("refresh", "Refresh every", intervals),
      group("usage", "Show", {
         option("used", "radio", "usage", "used", "Used", not options.remaining),
         option("remaining", "radio", "usage", "remaining", "Remaining", options.remaining),
      }),
      group("colors", "Colors", {
         option("bars", "checkbox", "bar_colors", "on", "Bars", options.bar_colors),
         option("percent", "checkbox", "percent_colors", "on", "Percentages", options.percent_colors),
      }),
      group("view", "Default view", {
         option("compact", "radio", "view", "compact", "Compact", options.compact),
         option("detailed", "radio", "view", "detailed", "Detailed", not options.compact),
      }),
      group("order", "Order", orders),
      group("footer", "Footer", {
         option("age", "checkbox", "show_age", "on", "Time since update", options.show_age),
      }),
   }), { key = "settings", role = "usage-monitor-usage__settings" })
end

local function status_text(current: Model): Node
   local text: Span
   if current.fetching then
      text = ui.span("updating…", "dim")
   elseif current.stale then
      text = ui.span("stale", "warning")
   elseif current.generated and current.settings.show_age then
      text = ui.span(current.generated, "dim")
   else
      text = ui.span("")
   end
   return with(ui.text(text), { key = "status", role = "usage-monitor-usage__status" })
end

local function controls(current: Model): Node
   if current.settings_open then
      return with(ui.row({
         with(ui.text("Settings"), { key = "heading", role = "usage-monitor-usage__heading", grow = 1 }),
         link("done", "Done", "options", "Back to usage (Esc)"),
      }), { key = "controls", role = "usage-monitor-usage__controls" })
   end
   return with(ui.row({
      link("prev", "‹", "prev", "Previous account (←)"),
      link("all", selection_label(current), "all", "Show all accounts (a)", current.selected == ALL),
      link("next", "›", "next", "Next account (→)"),
      with(ui.row({}), { key = "gap", grow = 1 }),
      status_text(current),
      link("compact", if current.compact then "Detailed" else "Compact", "compact", "Toggle compact view (c)"),
      link("refresh", "Refresh", "refresh", "Refresh usage (r)"),
      link("settings", "Settings", "options", "Settings (s)"),
   }), { key = "controls", role = "usage-monitor-usage__controls" })
end

local function view(block: Block, context: BlockCx): BlockView
   local current = model(block, settings.load())
   local narrow = context.cols < NARROW_COLS
   local rows: { Node } = {}
   if current.settings_open then
      rows[1] = settings_page(current)
   else
      local problem = notice(current)
      if problem then
         rows[#rows + 1] = problem
      end
      rows[#rows + 1] = body(current, narrow)
   end

   local suffix = if current.compact then " usage-monitor-usage__dense" else ""
   return {
      main = with(ui.col(rows), { role = "usage-monitor-usage__main" .. suffix }),
      dock = with(ui.col({ controls(current) }), { role = "usage-monitor-usage__dock" .. suffix }),
   }
end

local function saved_snapshot(saved: any): Snapshot?
   if type(saved) ~= "table" or saved.snapshot_version ~= 1 or type(saved.snapshot) ~= "table" then return nil end
   local cached = saved.snapshot
   if type(cached.generated_at) ~= "number" or type(cached.accounts) ~= "table" then return nil end
   for _, account in cached.accounts do
      if type(account) ~= "table" or type(account.limits) ~= "table" or type(account.disabled) ~= "boolean" then return nil end
      for _, field in { "id", "provider", "label" } do
         if type(account[field]) ~= "string" then return nil end
      end
      for _, field in { "plan", "error" } do
         if account[field] ~= nil and type(account[field]) ~= "string" then return nil end
      end
      for _, field in { "fetched_at", "reset_credits" } do
         if account[field] ~= nil and type(account[field]) ~= "number" then return nil end
      end
      for _, limit in account.limits do
         if type(limit) ~= "table" then return nil end
         for _, field in { "id", "label", "amount", "status" } do
            if type(limit[field]) ~= "string" then return nil end
         end
         for _, field in { "used_fraction", "reset_at" } do
            if limit[field] ~= nil and type(limit[field]) ~= "number" then return nil end
         end
         if limit.error ~= nil and type(limit.error) ~= "string" then return nil end
      end
   end
   return cached :: Snapshot
end

tern.block.define("usage", {
   init = function(context: BlockCx, _args: { string }, saved: any): Block
      local account = ALL
      local compact = settings.load().compact
      local settings_open = false
      if type(saved) == "table" then
         if type(saved.account) == "string" and saved.account ~= "" then
            account = saved.account
         end
         if type(saved.compact) == "boolean" then
            compact = saved.compact
         end
         settings_open = saved.settings_open == true
         if not snapshot then
            snapshot = saved_snapshot(saved)
         end
      end
      local block: Block = {
         context = context,
         account = account,
         compact = compact,
         settings_open = settings_open,
      }
      blocks[context.pane] = block
      start_loop()
      return block
   end,

   title = function(block: Block): string?
      if block.account ~= ALL and snapshot then
         for _, account in snapshot.accounts do
            if account.id == block.account then return "Usage · " .. usage_monitor.provider_name(account.provider) end
         end
      end
      return "Usage"
   end,

   view = function(block: Block, context: BlockCx): BlockView
      return view(block, context)
   end,

   key = function(block: Block, key: Key, _context: BlockCx): boolean?
      if key.ctrl or key.alt or key.meta then return false end
      if key.name == "left" then
         act(block, "prev")
      elseif key.name == "right" then
         act(block, "next")
      elseif key.name == "a" then
         act(block, "all")
      elseif key.name == "r" then
         act(block, "refresh")
      elseif key.name == "c" then
         act(block, "compact")
      elseif key.name == "s" then
         act(block, "options")
      elseif (key.name == "escape" or key.name == "esc") and block.settings_open then
         act(block, "options")
      else
         return false
      end
      return true
   end,

   event = function(block: Block, ui_event: UiEvent, _context: BlockCx)
      if ui_event.ev == "action" and type(ui_event.act) == "string" then
         act(block, ui_event.act, ui_event.value)
      elseif ui_event.ev == "change" and type(ui_event.name) == "string" then
         change(block, ui_event.name, if type(ui_event.value) == "string" then ui_event.value else "", ui_event.checked == true)
      end
   end,

   save = function(block: Block): any
      if snapshot then
         snapshot.accounts = tern.json.array(snapshot.accounts)
         for _, account in snapshot.accounts do
            account.limits = tern.json.array(account.limits)
         end
      end
      return {
         account = block.account,
         compact = block.compact,
         settings_open = block.settings_open,
         snapshot_version = 1,
         snapshot = snapshot,
      }
   end,
})

--!strict

local usage_monitor = require("./usage_monitor")

local ui = tern.ui

type Snapshot = usage_monitor.Snapshot
type Account = usage_monitor.Account
type Limit = usage_monitor.Limit

type Block = {
   context: BlockCx,
   account: string,
   compact: boolean,
   rendered: string?,
}

type LimitModel = {
   id: string,
   label: string,
   percent: string,
   amount: string,
   reset: string,
   fraction: number?,
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
   accounts: { AccountModel },
}

local POLL_MS = usage_monitor.POLL_MS
local TICK_MS = 1000
local WARN_FRACTION = 0.75
local BAD_FRACTION = 0.9
local NARROW_COLS = 60
local ALL = "all"

local blocks: { [number]: Block } = {}

local snapshot: Snapshot? = nil
local refresh_error: string? = nil
local fetching = false
local last_attempt = 0
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

local function resolve(selected: string): string
   if selected == ALL or not snapshot then return ALL end
   for _, account in snapshot.accounts do
      if account.id == selected then return selected end
   end
   return ALL
end

local function limit_model(limit: Limit, now_s: number): LimitModel
   return {
      id = limit.id,
      label = limit.label,
      percent = usage_monitor.percent(limit.used_fraction),
      amount = limit.amount,
      reset = usage_monitor.reset(limit.reset_at, now_s),
      fraction = limit.used_fraction,
      tone = limit_tone(limit),
      error = limit.error,
   }
end

local function account_model(account: Account, selected: string, now_s: number, ordinal: number): AccountModel
   local provider = usage_monitor.provider_name(account.provider)
   local display = if account.provider == "openai-codex" then "Codex" else provider
   local plan = account.plan
   if plan and string.lower(plan) ~= string.lower(provider) then
      display ..= " " .. string.upper(string.sub(plan, 1, 1)) .. string.sub(plan, 2)
   end
   local current: AccountModel = {
      id = account.id,
      name = usage_monitor.provider_name(account.provider),
      label = account.label,
      display_name = display .. " · Account " .. tostring(ordinal),
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
      current.limits[#current.limits + 1] = limit_model(limit, now_s)
   end
   current.empty = #current.limits == 0 and not account.error and not account.disabled
   return current
end

local function model(block: Block): Model
   local now_s = os.time()
   local selected = resolve(block.account)
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
   local counts: { [string]: number } = {}
   for _, account in snapshot.accounts do
      local ordinal = (counts[account.provider] or 0) + 1
      counts[account.provider] = ordinal
      if selected == ALL or account.id == selected then
         current.accounts[#current.accounts + 1] = account_model(account, selected, now_s, ordinal)
      end
   end
   current.shown = #current.accounts
   if current.shown == 0 then
      current.state = "empty"
      current.message = if current.total == 0 then "No accounts reported." else "That account is no longer reported."
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
            limit.amount,
            limit.reset,
            limit.tone or "",
            limit.error or "",
            tostring(limit.fraction),
         }, "\1")
      end
   end
   return table.concat(parts, "\2")
end

local function render_all()
   for _, block in blocks do
      local current = signature(model(block))
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
   if snapshot then
      for _, account in snapshot.accounts do
         order[#order + 1] = account.id
      end
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
   elseif name == "prev" then
      cycle(block, -1)
   elseif name == "next" then
      cycle(block, 1)
   elseif name == "pick" and value and value ~= "" then
      block.account = value
   end
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
   if not fetching and tern.now() - last_attempt >= POLL_MS then
      refresh(false)
   end
   render_all()
   loop = tern.timer(TICK_MS, tick)
end

local function start_loop()
   if not loop then
      last_attempt = tern.now() - POLL_MS
      loop = tern.timer(0, tick)
   end
end

local function selection_label(current: Model): string
   if current.selected == ALL or not snapshot then return "All" end
   local counts: { [string]: number } = {}
   for _, account in snapshot.accounts do
      counts[account.provider] = (counts[account.provider] or 0) + 1
      if account.id == current.selected then
         local name = if account.provider == "openai-codex" then "Codex" else usage_monitor.provider_name(account.provider)
         return name .. " " .. tostring(counts[account.provider])
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
   local percent = if limit.percent ~= "" then limit.percent .. " used" else "usage unknown"
   local tooltip = limit.label .. " · " .. percent
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

local function meter(limit: LimitModel): Node
   -- Tern's meter sweeps from 0 whenever it mounts, so draw a plain bar that only eases on change
   local fraction = limit.fraction
   if not fraction then return with(ui.text(""), { key = "bar", role = "usage-monitor-usage__bar usage-monitor-usage__bar--unknown", grow = 1 }) end
   local level = math.clamp(math.floor(fraction * 10), 0, 10)
   return ui.el("div", { key = "bar", role = "usage-monitor-usage__bar", grow = 1 }, {
      ui.el("div", {
         key = "fill",
         role = "usage-monitor-usage__fill usage-monitor-usage__fill--l" .. tostring(level),
         basis = math.clamp(fraction, 0, 1),
      }),
   })
end

local function percent_text(limit: LimitModel): Span
   if limit.percent == "" then return ui.span("—", "dim") end
   local token = tone_token(limit.tone)
   return if token then ui.span(limit.percent, token) else ui.span(limit.percent)
end

local function compact_limit(limit: LimitModel): Node
   return with(ui.col({
      with(ui.text({ ui.span(short_limit_label(limit.label) .. " ", "dim"), percent_text(limit) }), {
         key = "value",
         role = "usage-monitor-usage__quota-value",
         truncate = "end",
      }),
      meter(limit),
   }), { key = "lim-" .. limit.id, role = "usage-monitor-usage__quota", title = limit_tooltip(limit), grow = 1, basis = 0 })
end

local function compact_account(account: AccountModel): Node
   local children: { Node } = {
      with(ui.text(account.display_name), { key = "identity", role = "usage-monitor-usage__name", truncate = "end" }),
   }
   local limits: { Node } = {}
   for _, limit in account.limits do
      limits[#limits + 1] = compact_limit(limit)
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

local function detail_limit(limit: LimitModel, narrow: boolean): Node
   local cells: { Node } = {
      with(ui.text(ui.span(short_limit_label(limit.label), "dim")), { key = "label", role = "usage-monitor-usage__cell-label" }),
      meter(limit),
      with(ui.text(percent_text(limit)), { key = "pct", role = "usage-monitor-usage__cell-pct" }),
   }
   if not narrow then
      cells[#cells + 1] = with(ui.text(ui.span(short_reset(limit.reset), "dim")), { key = "reset", role = "usage-monitor-usage__cell-reset" })
   end
   return with(ui.row(cells), { key = "lim-" .. limit.id, role = "usage-monitor-usage__limit", title = limit_tooltip(limit) })
end

local function detail_account(account: AccountModel, narrow: boolean): Node
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
      children[#children + 1] = detail_limit(limit, narrow)
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
      return with(ui.col({
         with(ui.text(ui.span(current.message or "No usage data yet.", "dim")), { key = "message" }),
         with(ui.row({ link("check", "Check now", "refresh", "Check usage") }), { key = "actions" }),
      }), { key = "body", role = "usage-monitor-usage__state" })
   end

   local rows: { Node } = {}
   for _, account in current.accounts do
      rows[#rows + 1] = compact_account(account)
      if not current.compact then
         rows[#rows + 1] = detail_account(account, narrow)
      end
   end
   return with(ui.col(rows), { key = "body", role = "usage-monitor-usage__accounts" })
end

local function status_text(current: Model): Node
   local text: Span
   if current.fetching then
      text = ui.span("updating…", "dim")
   elseif current.stale then
      text = ui.span("stale", "warning")
   elseif current.generated then
      text = ui.span(current.generated, "dim")
   else
      text = ui.span("")
   end
   return with(ui.text(text), { key = "status", role = "usage-monitor-usage__status" })
end

local function controls(current: Model): Node
   return with(ui.row({
      link("prev", "‹", "prev", "Previous account (←)"),
      link("all", selection_label(current), "all", "Show all accounts (a)", current.selected == ALL),
      link("next", "›", "next", "Next account (→)"),
      with(ui.row({}), { key = "gap", grow = 1 }),
      status_text(current),
      link("compact", if current.compact then "Detailed" else "Compact", "compact", "Toggle compact view (c)"),
      link("refresh", "Refresh", "refresh", "Refresh usage (r)"),
   }), { key = "controls", role = "usage-monitor-usage__controls" })
end

local function view(block: Block, context: BlockCx): BlockView
   local current = model(block)
   local narrow = context.cols < NARROW_COLS
   local rows: { Node } = {}
   local problem = notice(current)
   if problem then
      rows[#rows + 1] = problem
   end
   rows[#rows + 1] = body(current, narrow)

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
      local compact = false
      if type(saved) == "table" then
         if type(saved.account) == "string" and saved.account ~= "" then
            account = saved.account
         end
         compact = saved.compact == true
         if not snapshot then
            snapshot = saved_snapshot(saved)
         end
      end
      local block: Block = {
         context = context,
         account = account,
         compact = compact,
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
      else
         return false
      end
      return true
   end,

   event = function(block: Block, ui_event: UiEvent, _context: BlockCx)
      if ui_event.ev == "action" and type(ui_event.act) == "string" then
         act(block, ui_event.act, ui_event.value)
      end
   end,

   save = function(block: Block): any
      if snapshot then
         snapshot.accounts = tern.json.array(snapshot.accounts)
         for _, account in snapshot.accounts do
            account.limits = tern.json.array(account.limits)
         end
      end
      return { account = block.account, compact = block.compact, snapshot_version = 1, snapshot = snapshot }
   end,
})

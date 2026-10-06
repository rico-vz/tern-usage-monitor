--!strict

export type Settings = {
   hidden: { [string]: boolean },
   interval_s: number,
   remaining: boolean,
   bar_colors: boolean,
   percent_colors: boolean,
   compact: boolean,
   show_age: boolean,
   order: string,
}

local settings = {}

local KEY = "settings"
local VERSION = 1

settings.INTERVALS = { 30, 60, 120, 300, 900, 0 }
settings.ORDERS = { "omp", "usage", "name" }

local function flag(value: any, fallback: boolean): boolean
   if type(value) == "boolean" then return value end
   return fallback
end

function settings.defaults(): Settings
   return {
      hidden = {},
      interval_s = 60,
      remaining = false,
      bar_colors = true,
      percent_colors = true,
      compact = false,
      show_age = true,
      order = "omp",
   }
end

function settings.load(): Settings
   local current = settings.defaults()
   local ok, stored = pcall(tern.kv.get, KEY)
   if not ok or type(stored) ~= "table" or stored.version ~= VERSION then return current end
   if type(stored.hidden) == "table" then
      for _, id in stored.hidden do
         if type(id) == "string" then
            current.hidden[id] = true
         end
      end
   end
   if table.find(settings.INTERVALS, stored.interval_s) then
      current.interval_s = stored.interval_s
   end
   if table.find(settings.ORDERS, stored.order) then
      current.order = stored.order
   end
   current.remaining = flag(stored.remaining, current.remaining)
   current.bar_colors = flag(stored.bar_colors, current.bar_colors)
   current.percent_colors = flag(stored.percent_colors, current.percent_colors)
   current.compact = flag(stored.compact, current.compact)
   current.show_age = flag(stored.show_age, current.show_age)
   return current
end

local function hidden_ids(current: Settings): { string }
   local ids: { string } = {}
   for id in current.hidden do
      ids[#ids + 1] = id
   end
   table.sort(ids)
   return ids
end

function settings.save(current: Settings): boolean
   local ok = pcall(tern.kv.set, KEY, {
      version = VERSION,
      hidden = tern.json.array(hidden_ids(current)),
      interval_s = current.interval_s,
      remaining = current.remaining,
      bar_colors = current.bar_colors,
      percent_colors = current.percent_colors,
      compact = current.compact,
      show_age = current.show_age,
      order = current.order,
   })
   return ok
end

function settings.signature(current: Settings): string
   return table.concat({
      table.concat(hidden_ids(current), ","),
      tostring(current.interval_s),
      tostring(current.remaining),
      tostring(current.bar_colors),
      tostring(current.percent_colors),
      tostring(current.compact),
      tostring(current.show_age),
      current.order,
   }, "\1")
end

return settings

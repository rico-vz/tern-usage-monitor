--!strict

local usage_monitor = require("./usage_monitor")

local function anchor(cx: WindowCx, monitor: number?): number?
   local focused = cx.session:focused()
   local tab = if focused then cx.session:tab_of(focused) else nil
   if focused and focused ~= monitor then
      local pane = cx.session:pane(focused)
      if pane and not pane.floating then return focused end
   end
   for _, pane in cx.session:panes() do
      if pane.pane ~= monitor and not pane.floating and pane.tab == tab then return pane.pane end
   end
   return nil
end

local function open_monitor(cx: WindowCx, floating: boolean)
   local focused = cx.session:focused()
   local tab = if focused then cx.session:tab_of(focused) else nil
   local monitor: number? = nil
   for _, pane in cx.session:panes() do
      if pane.block == usage_monitor.KIND and pane.tab == tab then
         monitor = pane.pane
         break
      end
   end

   local target = anchor(cx, monitor)
   if not monitor then
      monitor = if target
         then cx.layout:split(target, "right", { block = usage_monitor.KIND, cwd = "" }, { focus = false })
         else cx:new_block(usage_monitor.KIND, nil, "beside")
   end
   if not monitor then
      cx:toast("error", "Usage Monitor", "Install the plugin on the host where this pane runs.")
      return
   end

   local info = cx.session:pane(monitor)
   if floating and (not info or not info.floating) then
      -- A PiP needs a tiled pane to float over
      if not target then
         target = cx.layout:split(monitor, "left", {}, { focus = false })
         if not target then
            cx:toast("error", "Usage Monitor", "Couldn't create a tiled pane for the floating monitor.")
            return
         end
      end
      local ok, err = cx.layout:float(monitor, target, "tr", { focus = false })
      if not ok then
         cx:toast("error", "Usage Monitor", err or "Couldn't float the monitor. It remains available as a side panel.")
         return
      end
   elseif not floating and info and info.floating then
      local ok, err = cx.layout:dock(monitor, target, "right", { focus = true })
      if not ok then
         cx:toast("error", "Usage Monitor", err or "Couldn't dock the monitor.")
         return
      end
   end
   if not floating then
      cx.layout:focus(monitor)
   end
end

tern.command({
   id = "open-floating",
   title = "Usage Monitor: Open floating panel",
   icon = "pip",
   group = "Usage Monitor",
   run = function(cx: WindowCx)
      open_monitor(cx, true)
   end,
})

tern.command({
   id = "open-side",
   title = "Usage Monitor: Open side panel",
   icon = "dock-right",
   group = "Usage Monitor",
   run = function(cx: WindowCx)
      open_monitor(cx, false)
   end,
})

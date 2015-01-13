--
-- All profiler related stuff is stored in the top level table 'module'
--
local module = {}


--
-- newProfiler() creates a new profiler object for managing
-- the profiler and storing state.  Note that only one profiler
-- object can be executing at one time.
--
function module.new(variant, sampledelay)
  if module.running then
    print("Profiler already running.")
    return
  end

  variant = variant or "time"

  if variant ~= "time" and variant ~= "call" then
    print("Profiler method must be 'time' or 'call'.")
    return
  end

  local newprof = {}
  for k,v in pairs(module) do
    newprof[k] = v
  end
  newprof.variant = variant
  newprof.sampledelay = sampledelay or 100000
  return newprof
end

--
-- Simple wrapper to handle the hook.  You should not
-- be calling this directly. Duplicated to reduce overhead.
--
local function _profiler_hook_wrapper_by_call(action)
  if module.running == nil then
    debug.sethook( nil )
  end
  module.running:_internal_profile_by_call(action)
end
local function _profiler_hook_wrapper_by_time(action)
  if module.running == nil then
    debug.sethook( nil )
  end
  module.running:_internal_profile_by_time(action)
end

--
-- This function starts the profiler.  It will do nothing
-- if this (or any other) profiler is already running.
--
function module:start()
  if module.running then
    return
  end
  -- Start the profiler. This begins by setting up internal profiler state
  module.running = self
  self.rawstats = {}
  self.callstack = {}
  if self.variant == "time" then
    self.lastclock = os.clock()
    debug.sethook( _profiler_hook_wrapper_by_time, "", self.sampledelay )
  elseif self.variant == "call" then
    debug.sethook( _profiler_hook_wrapper_by_call, "cr" )
  else
    print("Profiler method must be 'time' or 'call'.")
    sys.exit(1)
  end
end


--
-- This function stops the profiler.  It will do nothing
-- if a profiler is not running, and nothing if it isn't
-- the currently running profiler.
--
function module:stop()
  if module.running ~= self then
    return
  end
  -- Stop the profiler.
  debug.sethook( nil )
  module.running = nil
end

--
-- This is the main by-function-call function of the profiler and should not
-- be called except by the hook wrapper
--
function module:_internal_profile_by_call(action)
  -- Since we can obtain the 'function' for the item we've had call us, we
  -- can use that...
  local caller_info = debug.getinfo( 3 )
  if caller_info == nil then
    print "No caller_info"
    return
  end

  --SHG_LOG("[module._internal_profile] "..(caller_info.name or "<nil>"))

  -- Retrieve the most recent activation record...
  local latest_ar = nil
  if table.getn(self.callstack) > 0 then
    latest_ar = self.callstack[table.getn(self.callstack)]
  end

  -- Are we allowed to profile this function?
  local should_not_profile = 0
  for k,v in pairs(self.prevented_functions) do
    if k == caller_info.func then
      should_not_profile = v
    end
  end
  -- Also check the top activation record...
  if latest_ar then
    if latest_ar.should_not_profile == 2 then
      should_not_profile = 2
    end
  end

  -- Now then, are we in 'call' or 'return' ?
  -- print("Profile:", caller_info.name, "SNP:", should_not_profile,
  --       "Action:", action )
  if action == "call" then
    -- Making a call...
    local this_ar = {}
    this_ar.should_not_profile = should_not_profile
    this_ar.parent_ar = latest_ar
    this_ar.anon_child = 0
    this_ar.name_child = 0
    this_ar.children = {}
    this_ar.children_time = {}
    this_ar.clock_start = os.clock()
    -- Last thing to do on a call is to insert this onto the ar stack...
    table.insert( self.callstack, this_ar )
  else
    local this_ar = latest_ar
    if this_ar == nil then
      return -- No point in doing anything if no upper activation record
    end

    -- Right, calculate the time in this function...
    this_ar.clock_end = os.clock()
    this_ar.this_time = this_ar.clock_end - this_ar.clock_start

    -- Now, if we have a parent, update its call info...
    if this_ar.parent_ar then
      this_ar.parent_ar.children[caller_info.func] =
        (this_ar.parent_ar.children[caller_info.func] or 0) + 1
      this_ar.parent_ar.children_time[caller_info.func] =
        (this_ar.parent_ar.children_time[caller_info.func] or 0 ) +
        this_ar.this_time
      if caller_info.name == nil then
        this_ar.parent_ar.anon_child =
          this_ar.parent_ar.anon_child + this_ar.this_time
      else
        this_ar.parent_ar.name_child =
          this_ar.parent_ar.name_child + this_ar.this_time
      end
    end
    -- Now if we're meant to record information about ourselves, do so...
    if this_ar.should_not_profile == 0 then
      local inforec = self:_get_func_rec(caller_info.func,1)
      inforec.count = inforec.count + 1
      inforec.time = inforec.time + this_ar.this_time
      inforec.anon_child_time = inforec.anon_child_time + this_ar.anon_child
      inforec.name_child_time = inforec.name_child_time + this_ar.name_child
      inforec.func_info = caller_info
      for k,v in pairs(this_ar.children) do
        inforec.children[k] = (inforec.children[k] or 0) + v
        inforec.children_time[k] =
          (inforec.children_time[k] or 0) + this_ar.children_time[k]
      end
    end

    -- Last thing to do on return is to drop the last activation record...
    table.remove( self.callstack, table.getn( self.callstack ) )
  end
end


--
-- This is the main by-time internal function of the profiler and should not
-- be called except by the hook wrapper
--
function module:_internal_profile_by_time(action)
  -- we do this first so we add the minimum amount of extra time to this call
  local timetaken = os.clock() - self.lastclock

  local depth = 3
  local at_top = true
  local last_caller
  local caller = debug.getinfo(depth)
  while caller do
    if not caller.func then caller.func = "(tail call)" end
    if self.prevented_functions[caller.func] == nil then
      local info = self:_get_func_rec(caller.func, 1, caller)
      info.count = info.count + 1
      info.time = info.time + timetaken
      if last_caller then
        -- we're not the head, so update the "children" times also
        if last_caller.name then
          info.name_child_time = info.name_child_time + timetaken
        else
          info.anon_child_time = info.anon_child_time + timetaken
        end
        info.children[last_caller.func] =
          (info.children[last_caller.func] or 0) + 1
        info.children_time[last_caller.func] =
          (info.children_time[last_caller.func] or 0) + timetaken
      end
    end
    depth = depth + 1
    last_caller = caller
    caller = debug.getinfo(depth)
  end

  self.lastclock = os.clock()
end


--
-- This returns a (possibly empty) function record for
-- the specified function. It is for internal profiler use.
--
function module:_get_func_rec(func,force,info)
  -- Find the function ref for 'func' (if force and not present, create one)
  local ret = self.rawstats[func]
  if ret == nil and force ~= 1 then
    return nil
  end
  if ret == nil then
    -- Build a new function statistics table
    ret = {}
    ret.func = func
    ret.count = 0
    ret.time = 0
    ret.anon_child_time = 0
    ret.name_child_time = 0
    ret.children = {}
    ret.children_time = {}
    ret.func_info = info
    self.rawstats[func] = ret
  end
  return ret
end


--
-- This writes a profile report to the output file object.  If
-- sort_by_total_time is nil or false the output is sorted by
-- the function time minus the time in it's children.
--
function module:report(outfile, sort_by_total_time )

  outfile:write
    [[Lua Profile output created by profiler.lua. Copyright Pepperfish 2002+

]]

  -- This is pretty awful.
  local terms = {}
  if self.variant == "time" then
    terms.capitalized = "Sample"
    terms.single = "sample"
    terms.pastverb = "sampled"
  elseif self.variant == "call" then
    terms.capitalized = "Call"
    terms.single = "call"
    terms.pastverb = "called"
  else
    assert(false)
  end

  local total_time = 0
  local ordering = {}
  for func,record in pairs(self.rawstats) do
    table.insert(ordering, func)
  end

  if sort_by_total_time then
    table.sort( ordering,
      function(a,b) return self.rawstats[a].time > self.rawstats[b].time end
    )
  else
    table.sort( ordering,
      function(a,b)
        local arec = self.rawstats[a]
        local brec = self.rawstats[b]
        local atime = arec.time - (arec.anon_child_time + arec.name_child_time)
        local btime = brec.time - (brec.anon_child_time + brec.name_child_time)
        return atime > btime
      end
    )
  end

  for i=1,table.getn(ordering) do
    local func = ordering[i]
    local record = self.rawstats[func]
    local thisfuncname = " " .. self:_pretty_name(func) .. " "
    if string.len( thisfuncname ) < 42 then
      thisfuncname =
        string.rep( "-", (42 - string.len(thisfuncname))/2 ) .. thisfuncname
      thisfuncname =
        thisfuncname .. string.rep( "-", 42 - string.len(thisfuncname) )
    end

    total_time = total_time + ( record.time - ( record.anon_child_time +
      record.name_child_time ) )
    outfile:write( string.rep( "-", 19 ) .. thisfuncname ..
      string.rep( "-", 19 ) .. "\n" )
    outfile:write( terms.capitalized.." count:         " ..
      string.format( "%4d", record.count ) .. "\n" )
    outfile:write( "Time spend total:       " ..
      string.format( "%4.3f", record.time ) .. "s\n" )
    outfile:write( "Time spent in children: " ..
      string.format("%4.3f",record.anon_child_time+record.name_child_time) ..
      "s\n" )
    local timeinself =
      record.time - (record.anon_child_time + record.name_child_time)
    outfile:write( "Time spent in self:     " ..
      string.format("%4.3f", timeinself) .. "s\n" )
    outfile:write( "Time spent per " .. terms.single .. ":  " ..
      string.format("%4.5f", record.time/record.count) ..
      "s/" .. terms.single .. "\n" )
    outfile:write( "Time spent in self per "..terms.single..": " ..
      string.format( "%4.5f", timeinself/record.count ) .. "s/" ..
      terms.single.."\n" )

    -- Report on each child in the form
    -- Child  <funcname> called n times and took a.bs
    local added_blank = 0
    for k,v in pairs(record.children) do
      if self.prevented_functions[k] == nil or
         self.prevented_functions[k] == 0
      then
        if added_blank == 0 then
          outfile:write( "\n" ) -- extra separation line
          added_blank = 1
        end
        outfile:write( "Child " .. self:_pretty_name(k) ..
          string.rep( " ", 41-string.len(self:_pretty_name(k)) ) .. " " ..
          terms.pastverb.." " .. string.format("%6d", v) )
        outfile:write( " times. Took " ..
          string.format("%4.2f", record.children_time[k] ) .. "s\n" )
      end
    end

    outfile:write( "\n" ) -- extra separation line
    outfile:flush()
  end
  outfile:write( "\n\n" )
  outfile:write( "Total time spent in profiled functions: " ..
                 string.format("%5.3g",total_time) .. "s\n" )
  outfile:write( [[

END
]] )
  outfile:flush()
end


--
-- This writes the profile to the output file object as
-- loadable Lua source.
--
function module:lua_report(outfile)
  -- Purpose: Write out the entire raw state in a cross-referenceable form.
  local ordering = {}
  local functonum = {}
  for func,record in pairs(self.rawstats) do
    table.insert(ordering, func)
    functonum[func] = table.getn(ordering)
  end

  outfile:write(
    "-- Profile generated by profiler.lua Copyright Pepperfish 2002+\n\n" )
  outfile:write( "-- Function names\nfuncnames = {}\n" )
  for i=1,table.getn(ordering) do
    local thisfunc = ordering[i]
    outfile:write( "funcnames[" .. i .. "] = " ..
      string.format("%q", self:_pretty_name(thisfunc)) .. "\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Function times\nfunctimes = {}\n" )
  for i=1,table.getn(ordering) do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "functimes[" .. i .. "] = { " )
    outfile:write( "tot=" .. record.time .. ", " )
    outfile:write( "achild=" .. record.anon_child_time .. ", " )
    outfile:write( "nchild=" .. record.name_child_time .. ", " )
    outfile:write( "count=" .. record.count .. " }\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child links\nchildren = {}\n" )
  for i=1,table.getn(ordering) do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "children[" .. i .. "] = { " )
    for k,v in pairs(record.children) do
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( functonum[k] .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child call counts\nchildcounts = {}\n" )
  for i=1,table.getn(ordering) do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc]
    outfile:write( "children[" .. i .. "] = { " )
    for k,v in record.children do
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( v .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n" )
  outfile:write( "-- Child call time\nchildtimes = {}\n" )
  for i=1,table.getn(ordering) do
    local thisfunc = ordering[i]
    local record = self.rawstats[thisfunc];
    outfile:write( "children[" .. i .. "] = { " )
    for k,v in pairs(record.children) do
      if functonum[k] then -- non-recorded functions will be ignored now
        outfile:write( record.children_time[k] .. ", " )
      end
    end
    outfile:write( "}\n" )
  end
  outfile:write( "\n\n-- That is all.\n\n" )
  outfile:flush()
end

-- Internal function to calculate a pretty name for the profile output
function module:_pretty_name(func)

  -- Only the data collected during the actual
  -- run seems to be correct.... why?
  local info = self.rawstats[ func ].func_info
  -- local info = debug.getinfo( func )

  local name = ""
  if info.what == "Lua" then
    name = "L:"
  end
  if info.what == "C" then
    name = "C:"
  end
  if info.what == "main" then
    name = " :"
  end

  if info.name == nil then
    name = name .. "<"..tostring(func) .. ">"
  else
    name = name .. info.name
  end

  if info.source then
    name = name .. "@" .. info.source
  else
    if info.what == "C" then
      name = name .. "@?"
    else
      name = name .. "@<string>"
    end
  end
  name = name .. ":"
  if info.what == "C" then
    name = name .. "?"
  else
    name = name .. info.linedefined
  end

  return name
end


--
-- This allows you to specify functions which you do
-- not want profiled.  Setting level to 1 keeps the
-- function from being profiled.  Setting level to 2
-- keeps both the function and its children from
-- being profiled.
--
-- BUG: 2 will probably act exactly like 1 in "time" mode.
-- If anyone cares, let me (zorba) know and it can be fixed.
--
function module:prevent(func, level)
  self.prevented_functions[func] = (level or 1)
end


module.prevented_functions = {
  [module.start] = 2,
  [module.stop] = 2,
  [module._internal_profile_by_time] = 2,
  [module._internal_profile_by_call] = 2,
  [_profiler_hook_wrapper_by_time] = 2,
  [_profiler_hook_wrapper_by_call] = 2,
  [module.prevent] = 2,
  [module._get_func_rec] = 2,
  [module.report] = 2,
  [module.lua_report] = 2,
  [module._pretty_name] = 2
}

return module

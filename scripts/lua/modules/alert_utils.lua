--
-- (C) 2014-19 - ntop.org
--

-- This file contains the description of all functions
-- used to trigger host alerts
local verbose = ntop.getCache("ntopng.prefs.alerts.debug") == "1"
local callback_utils = require "callback_utils"
local template = require "template_utils"
local json = require("dkjson")
local host_pools_utils = require("host_pools_utils")
local recovery_utils = require "recovery_utils"
local alert_consts = require "alert_consts"
local format_utils = require "format_utils"
local telemetry_utils = require "telemetry_utils"
local tracker = require "tracker"
local alerts_api = require "alerts_api"
local alert_endpoints = require "alert_endpoints_utils"
local flow_consts = require "flow_consts"
local store_alerts_queue = "ntopng.alert_store_queue"
local inactive_hosts_hash_key = "ntopng.prefs.alerts.ifid_%d.inactive_hosts_alerts"

local shaper_utils = nil

if(ntop.isnEdge()) then
   package.path = dirs.installdir .. "/pro/scripts/lua/modules/?.lua;" .. package.path
   shaper_utils = require("shaper_utils")
end

-- ##############################################

function alertSeverityRaw(severity_id)
  severity_id = tonumber(severity_id)

  for key, severity_info in pairs(alert_consts.alert_severities) do
    if(severity_info.severity_id == severity_id) then
      return(key)
    end
  end
end

function alertSeverityLabel(v, nohtml)
   local severity_id = alertSeverityRaw(v)

   if(severity_id) then
      local severity_info = alert_consts.alert_severities[severity_id]
      local title = i18n(severity_info.i18n_title) or severity_info.i18n_title

      if(nohtml) then
        return(title)
      else
        return(string.format('<span class="label %s">%s</span>', severity_info.label, title))
      end
   end
end

function alertSeverity(v)
  return(alert_consts.alert_severities[v].severity_id)
end

-- ##############################################

function alertTypeRaw(type_id)
  type_id = tonumber(type_id)

  for key, type_info in pairs(alert_consts.alert_types) do
    if(type_info.alert_id == type_id) then
      return(key)
    end
  end
end

function alertTypeLabel(v, nohtml)
   local alert_id = alertTypeRaw(v)

   if(alert_id) then
      local type_info = alert_consts.alert_types[alert_id]
      local title = i18n(type_info.i18n_title) or type_info.i18n_title

      if(nohtml) then
        return(title)
      else
        return(string.format('<i class="fa %s"></i> %s', type_info.icon, title))
      end
   end
end

function alertType(v)
  return(alert_consts.alert_types[v].alert_id)
end

function alertTypeDescription(v)
  local alert_id = alertTypeRaw(v)

  if(alert_id) then
    return(alert_consts.alert_types[alert_id].i18n_description)
  end
end

-- ##############################################

-- Rename engine -> granulariy
function alertEngineRaw(granularity_id)
  granularity_id = tonumber(granularity_id)

  for key, granularity_info in pairs(alert_consts.alerts_granularities) do
    if(granularity_info.granularity_id == granularity_id) then
      return(key)
    end
  end
end

function alertEngine(v)
   return(alert_consts.alerts_granularities[v].granularity_id)
end

function alertEngineLabel(v)
  local granularity_id = alertEngineRaw(v)

  if(granularity_id ~= nil) then
    return(i18n(alert_consts.alerts_granularities[granularity_id].i18n_title))
  end
end

function alertEngineDescription(v)
  local granularity_id = alertEngineRaw(v)

  if(granularity_id ~= nil) then
    return(i18n(alert_consts.alerts_granularities[granularity_id].i18n_description))
  end
end

function granularity2sec(v)
  return(alert_consts.alerts_granularities[v].granularity_seconds)
end

-- See NetworkInterface::checkHostsAlerts()
function granularity2id(granularity)
  -- TODO replace alertEngine
  return(alertEngine(granularity))
end

function sec2granularity(seconds)
  seconds = tonumber(seconds)

  for key, granularity_info in pairs(alert_consts.alerts_granularities) do
    if(granularity_info.granularity_seconds == seconds) then
      return(key)
    end
  end
end

-- ##############################################

function alertEntityRaw(entity_id)
  entity_id = tonumber(entity_id)

  for key, entity_info in pairs(alert_consts.alert_entities) do
    if(entity_info.entity_id == entity_id) then
      return(key)
    end
  end
end

function alertEntity(v)
   return(alert_consts.alert_entities[v].entity_id)
end

function alertEntityLabel(v, nothml)
  local entity_id = alertEntityRaw(v)

  if(entity_id) then
    return(alert_consts.alert_entities[entity_id].label)
  end
end

-- ##############################################################################

function getInterfacePacketDropPercAlertKey(ifname)
   return "ntopng.prefs.iface_" .. getInterfaceId(ifname) .. ".packet_drops_alert"
end

-- ##############################################################################

if ntop.isEnterprise() then
   local dirs = ntop.getDirs()
   package.path = dirs.installdir .. "/pro/scripts/lua/enterprise/modules/?.lua;" .. package.path
   require "enterprise_alert_utils"
end

j = require("dkjson")
require "persistence"

function is_allowed_timespan(timespan)
   return(alert_consts.alerts_granularities[timespan] ~= nil)
end

function get_alerts_hash_name(timespan, ifname, entity_type)
   local ifid = getInterfaceId(ifname)
   if not is_allowed_timespan(timespan) or tonumber(ifid) == nil then
      return nil
   end

   return "ntopng.prefs.alerts_"..timespan..".".. entity_type ..".ifid_"..tostring(ifid)
end

-- Get the hash key used for saving global settings
local function get_global_alerts_hash_key(entity_type, local_hosts)
   if entity_type == "host" then
      if local_hosts then
        return "local_hosts"
      else
        return "remote_hosts"
      end
   elseif entity_type == "interface" then
      return "interfaces"
   elseif entity_type == "network" then
      return "local_networks"
   else
      return "*"
   end
end

function get_make_room_keys(ifId)
   return {flows="ntopng.cache.alerts.ifid_"..ifId..".make_room_flow_alerts",
	   entities="ntopng.cache.alerts.ifid_"..ifId..".make_room_closed_alerts"}
end

-- =====================================================

function get_alerts_suppressed_hash_name(ifid)
   local hash_name = "ntopng.prefs.alerts.ifid_"..ifid
   return hash_name
end

-- #################################

-- This function maps the SQLite table names to the conventional table
-- names used in this script
local function luaTableName(sqlite_table_name)
  --~ ALERTS_MANAGER_FLOWS_TABLE_NAME      "flows_alerts"
  if(sqlite_table_name == "flows_alerts") then
    return("historical-flows")
  else
    return("historical")
  end
end

-- #################################

function performAlertsQuery(statement, what, opts, force_query, group_by)
   local wargs = {"WHERE", "1=1"}
   local oargs = {}

   if(group_by ~= nil) then
     group_by = " GROUP BY " .. group_by
   else
     group_by = ""
   end

   if tonumber(opts.row_id) ~= nil then
      wargs[#wargs+1] = 'AND rowid = '..(opts.row_id)
   end

   if (not isEmptyString(opts.entity)) and (not isEmptyString(opts.entity_val)) then
      if(what == "historical-flows") then
         if(tonumber(opts.entity) ~= alertEntity("host")) then
           return({})
         else
           -- need to handle differently for flows table
           local info = hostkey2hostinfo(opts.entity_val)
           wargs[#wargs+1] = 'AND (cli_addr="'..(info.host)..'" OR srv_addr="'..(info.host)..'")'
           wargs[#wargs+1] = 'AND vlan_id='..(info.vlan)
         end
      else
         wargs[#wargs+1] = 'AND alert_entity = "'..(opts.entity)..'"'
         wargs[#wargs+1] = 'AND alert_entity_val = "'..(opts.entity_val)..'"'
      end
   elseif (what ~= "historical-flows") then
      if (not isEmptyString(opts.entity)) then
	 wargs[#wargs+1] = 'AND alert_entity = "'..(opts.entity)..'"'
      elseif(not isEmptyString(opts.entity_excludes)) then
	 local excludes = string.split(opts.entity_excludes, ",") or {opts.entity_excludes}

	 for _, entity in pairs(excludes) do
	    wargs[#wargs+1] = 'AND alert_entity != "'.. entity ..'"'
	 end
      end
   end

   if not isEmptyString(opts.origin) then
      local info = hostkey2hostinfo(opts.origin)
      wargs[#wargs+1] = 'AND cli_addr="'..(info.host)..'"'
      wargs[#wargs+1] = 'AND vlan_id='..(info.vlan)
   end

   if not isEmptyString(opts.target) then
      local info = hostkey2hostinfo(opts.target)
      wargs[#wargs+1] = 'AND srv_addr="'..(info.host)..'"'
      wargs[#wargs+1] = 'AND vlan_id='..(info.vlan)
   end

   if tonumber(opts.epoch_begin) ~= nil then
      wargs[#wargs+1] = 'AND alert_tstamp >= '..(opts.epoch_begin)
   end

   if tonumber(opts.epoch_end) ~= nil then
      wargs[#wargs+1] = 'AND alert_tstamp <= '..(opts.epoch_end)
   end

   if not isEmptyString(opts.flowhosts_type) then
      if opts.flowhosts_type ~= "all_hosts" then
         local cli_local, srv_local = 0, 0

         if opts.flowhosts_type == "local_only" then cli_local, srv_local = 1, 1
         elseif opts.flowhosts_type == "remote_only" then cli_local, srv_local = 0, 0
         elseif opts.flowhosts_type == "local_origin_remote_target" then cli_local, srv_local = 1, 0
         elseif opts.flowhosts_type == "remote_origin_local_target" then cli_local, srv_local = 0, 1
         end

         if what == "historical-flows" then
            wargs[#wargs+1] = "AND cli_localhost = "..cli_local
            wargs[#wargs+1] = "AND srv_localhost = "..srv_local
         end
         -- TODO cannot apply it to other tables right now
      end
   end

   if tonumber(opts.alert_type) ~= nil then
      wargs[#wargs+1] = "AND alert_type = "..(opts.alert_type)
   end

   if tonumber(opts.alert_severity) ~= nil then
      wargs[#wargs+1] = "AND alert_severity = "..(opts.alert_severity)
   end

   if((not isEmptyString(opts.sortColumn)) and (not isEmptyString(opts.sortOrder))) then
      local order_by

      if opts.sortColumn == "column_date" then
         order_by = "alert_tstamp"
      elseif opts.sortColumn == "column_key" then
         order_by = "rowid"
      elseif opts.sortColumn == "column_severity" then
         order_by = "alert_severity"
      elseif opts.sortColumn == "column_type" then
         order_by = "alert_type"
      elseif opts.sortColumn == "column_count" and what ~= "engaged" then
         order_by = "alert_counter"
      elseif((opts.sortColumn == "column_duration") and (what == "historical")) then
         order_by = "(alert_tstamp_end - alert_tstamp)"
      else
         -- default
         order_by = "alert_tstamp"
      end

      oargs[#oargs+1] = "ORDER BY "..order_by
      oargs[#oargs+1] = string.upper(opts.sortOrder)
   end

   -- pagination
   if((tonumber(opts.perPage) ~= nil) and (tonumber(opts.currentPage) ~= nil)) then
      local to_skip = (tonumber(opts.currentPage)-1) * tonumber(opts.perPage)
      oargs[#oargs+1] = "LIMIT"
      oargs[#oargs+1] = to_skip..","..(opts.perPage)
   end

   local query = table.concat(wargs, " ")
   local res

   query = query .. " " .. table.concat(oargs, " ") .. group_by

   -- Uncomment to debug the queries
   --~ tprint(statement.." (from "..what..") "..query)

   if((what == "engaged") or (what == "historical")) then
      res = interface.queryAlertsRaw(statement, query, force_query)
   elseif what == "historical-flows" then
      res = interface.queryFlowAlertsRaw(statement, query, force_query)
   else
      error("Invalid alert subject: "..what)
   end

   return res
end

-- #################################

local function getNumEngagedAlerts(options)
  local entity_type_filter = tonumber(options.entity)
  local entity_value_filter = options.entity_val
  local res = interface.getEngagedAlertsCount(entity_type_filter, entity_value_filter, options.entity_excludes)

  if(res ~= nil) then
    return(res.num_alerts)
  end

  return(0)
end

-- #################################

function getNumAlerts(what, options)
   local num = 0

   if(what == "engaged") then
     num = getNumEngagedAlerts(options)
   else
     local opts = getUnpagedAlertOptions(options or {})
     local res = performAlertsQuery("SELECT COUNT(*) AS count", what, opts)
     if((res ~= nil) and (#res == 1) and (res[1].count ~= nil)) then num = tonumber(res[1].count) end
   end

   return num
end

-- #################################

-- Faster than of getNumAlerts
function hasAlerts(what, options)
  if(what == "engaged") then
    return(getNumEngagedAlerts(options) > 0)
  end

  local opts = getUnpagedAlertOptions(options or {})
  -- limit 1
  opts.perPage = 1
  opts.currentPage = 1
  local res = performAlertsQuery("SELECT rowid", what, opts)

  if((res ~= nil) and (#res == 1)) then
    return(true)
  else
    return(false)
  end
end

-- #################################

local function engagedAlertsQuery(params)
  local type_filter = tonumber(params.alert_type)
  local severity_filter = tonumber(params.alert_severity)
  local entity_type_filter = tonumber(params.entity)
  local entity_value_filter = params.entity_val

  local perPage = tonumber(params.perPage)
  local sortColumn = params.sortColumn
  local sortOrder = params.sortOrder
  local sOrder = ternary(sortOrder == "desc", rev_insensitive, asc_insensitive)
  local currentPage = tonumber(params.currentPage)
  local totalRows = 0

  --~ tprint(string.format("type=%s sev=%s entity=%s val=%s", type_filter, severity_filter, entity_type_filter, entity_value_filter))
  local alerts = interface.getEngagedAlerts(entity_type_filter, entity_value_filter, type_filter, severity_filter, params.entity_excludes)
  local sort_2_col = {}

  -- Sort
  for idx, alert in pairs(alerts) do
    if sortColumn == "column_type" then
      sort_2_col[idx] = alert.alert_type
    elseif sortColumn == "column_severity" then
      sort_2_col[idx] = alert.alert_severity
    elseif sortColumn == "column_duration" then
      sort_2_col[idx] = os.time() - alert.alert_tstamp
    else -- column_date
      sort_2_col[idx] = alert.alert_tstamp
    end

    totalRows = totalRows + 1
  end

  -- Pagination
  local to_skip = (currentPage-1) * perPage
  local totalRows = #alerts
  local res = {}
  local i = 0

  for idx in pairsByValues(sort_2_col, sOrder) do
    if i >= to_skip + perPage then
      break
    end

    if (i >= to_skip) then
      res[#res + 1] = alerts[idx]
    end

    i = i + 1
  end

  return res, totalRows
end

-- #################################

function getAlerts(what, options, with_counters)
   local alerts, num_alerts

   if what == "engaged" then
      alerts, num_alerts = engagedAlertsQuery(options)

      if not with_counters then
        num_alerts = nil
      end
   else
      alerts = performAlertsQuery("SELECT rowid, *", what, options)

      if with_counters then
        num_alerts = getNumAlerts(what, options)
      end
   end

   return alerts, num_alerts
end

-- #################################

local function refreshAlerts(ifid)
   ntop.delCache(string.format("ntopng.cache.alerts.ifid_%d.has_alerts", ifid))
   ntop.delCache("ntopng.cache.update_alerts_stats_time")
end

-- #################################

function deleteAlerts(what, options)
   local opts = getUnpagedAlertOptions(options or {})
   performAlertsQuery("DELETE", what, opts)
   refreshAlerts(interface.getId())
end

-- #################################

-- this function returns an object with parameters specific for one tab
function getTabParameters(_get, what)
   local opts = {}
   for k,v in pairs(_get) do opts[k] = v end

   -- these options are contextual to the current tab (status)
   if _get.status ~= what then
      opts.alert_type = nil
      opts.alert_severity = nil
   end
   if not isEmptyString(what) then opts.status = what end
   opts.ifid = interface.getId()
   return opts
end

-- #################################

-- Remove pagination options from the options
function getUnpagedAlertOptions(options)
   local res = {}

   local paged_option = { currentPage=1, perPage=1, sortColumn=1, sortOrder=1 }

   for k,v in pairs(options) do
      if not paged_option[k] then
         res[k] = v
      end
   end

   return res
end

-- #################################

local function checkDisableAlerts()
  if(_POST["action"] == "disable_alert") then
    local entity = _POST["entity"]
    local entity_val = _POST["entity_val"]
    local alert_type = _POST["alert_type"]

    alerts_api.disableEntityAlert(interface.getId(), entity, entity_val, alert_type)
  elseif(_POST["action"] == "enable_alert") then
    local entity = _POST["entity"]
    local entity_val = _POST["entity_val"]
    local alert_type = _POST["alert_type"]

    alerts_api.enableEntityAlert(interface.getId(), entity, entity_val, alert_type)
  end
end

-- #################################

function checkDeleteStoredAlerts()
   _GET["status"] = _GET["status"] or _POST["status"]

   if((_POST["id_to_delete"] ~= nil) and (_GET["status"] ~= nil)) then
      if(_POST["id_to_delete"] ~= "__all__") then
         _GET["row_id"] = tonumber(_POST["id_to_delete"])
      end

      deleteAlerts(_GET["status"], _GET)

      -- TRACKER HOOK
      tracker.log("checkDeleteStoredAlerts", {_GET["status"], _POST["id_to_delete"]})

      -- to avoid performing the delete again
      _POST["id_to_delete"] = nil
      -- to avoid filtering by id
      _GET["row_id"] = nil
      -- in case of delete "older than" button, resets the time period after the delete took place
      if isEmptyString(_GET["epoch_begin"]) then _GET["epoch_end"] = nil end

      local has_alerts = hasAlerts(_GET["status"], _GET)
      if(not has_alerts) then
         -- reset the filter to avoid hiding the tab
         _GET["alert_severity"] = nil
         _GET["alert_type"] = nil
      end
   end

   checkDisableAlerts()

   if(_POST["action"] == "release_alert") then
      local entity_info = {
         alert_entity = alert_consts.alert_entities[alertEntityRaw(_POST["entity"])],
         alert_entity_val = _POST["entity_val"],
      }

      local type_info = {
         alert_type = alert_consts.alert_types[alertTypeRaw(_POST["alert_type"])],
         alert_severity = alert_consts.alert_severities[alertSeverityRaw(_POST["alert_severity"])],
         alert_subtype = _POST["alert_subtype"],
         alert_granularity = alert_consts.alerts_granularities[sec2granularity(_POST["alert_granularity"])],
      }

      alerts_api.release(entity_info, type_info)
      interface.refreshAlerts();
   end
end

-- #################################

local function getFlowStatusInfo(record, status_info)
   local res = ""

   local l7proto_name = interface.getnDPIProtoName(tonumber(record["l7_proto"]) or 0)

   if l7proto_name == "ICMP" then -- is ICMPv4
      -- TODO: old format - remove when the all the flow alers will be generated in lua
      local type_code = {type = status_info["icmp.icmp_type"], code = status_info["icmp.icmp_code"]}

      if table.empty(type_code) and status_info["icmp"] then
	 -- This is the new format created when setting the alert from lua
	 type_code = {type = status_info["icmp"]["type"], code = status_info["icmp"]["code"]}
      end

      if status_info["icmp.unreach.src_ip"] then -- TODO: old format to be removed
	 res = string.format("[%s]", i18n("icmp_page.icmp_port_unreachable_extra", {unreach_host=status_info["icmp.unreach.dst_ip"], unreach_port=status_info["icmp.unreach.dst_port"], unreach_protocol = l4_proto_to_string(status_info["icmp.unreach.protocol"])}))
      elseif status_info["icmp"] and status_info["icmp"]["unreach"] then -- New format
	 res = string.format("[%s]", i18n("icmp_page.icmp_port_unreachable_extra", {unreach_host=status_info["icmp"]["unreach"]["dst_ip"], unreach_port=status_info["icmp"]["unreach"]["dst_port"], unreach_protocol = l4_proto_to_string(status_info["icmp"]["unreach"]["protocol"])}))
      else
	 res = string.format("[%s]", getICMPTypeCode(type_code))
      end
   end

   return string.format(" %s", res)
end

-- #################################

local function formatRawFlow(record, flow_json, skip_add_links, skip_peers)
   require "flow_utils"
   local time_bounds
   local add_links = (not skip_add_links)
   local host_page = "&page=alerts"

   if interfaceHasNindexSupport() and not skip_add_links then
      -- only add links if nindex is present
      add_links = true
      time_bounds = {getAlertTimeBounds(record)}
   end

   local decoded = json.decode(flow_json)

   if type(decoded["status_info"]) == "string" then
      -- This is for backward compatibility
      decoded["status_info"] = json.decode(decoded["status_info"])
   end

   local status_info = alert2statusinfo(decoded)

   -- active flow lookup
   if not interface.isView() and status_info and status_info["ntopng.key"] and record["alert_tstamp"] and (not skip_peers) then
      -- attempt a lookup on the active flows
      local active_flow = interface.findFlowByKey(status_info["ntopng.key"])

      if active_flow and active_flow["seen.first"] < tonumber(record["alert_tstamp"]) then
	 return string.format("%s [%s: <A HREF='%s/lua/flow_details.lua?flow_key=%u'><span class='label label-info'>Info</span></A> %s]",
			      getFlowStatus(tonumber(record["flow_status"]), status_info),
			      i18n("flow"), ntop.getHttpPrefix(), active_flow["ntopng.key"],
			      getFlowLabel(active_flow, true, true))
      end
   end

   -- pretend record is a flow to reuse getFlowLabel
   local flow = {
      ["cli.ip"] = record["cli_addr"], ["cli.port"] = tonumber(record["cli_port"]),
      ["cli.blacklisted"] = tostring(record["cli_blacklisted"]) == "1",
      ["srv.ip"] = record["srv_addr"], ["srv.port"] = tonumber(record["srv_port"]),
      ["srv.blacklisted"] = tostring(record["srv_blacklisted"]) == "1",
      ["vlan"] = record["vlan_id"]}

   if skip_peers then
      flow = ""
   else
      flow = "["..i18n("flow")..": "..(getFlowLabel(flow, false, add_links, time_bounds, host_page) or "").."] "
   end

   local l4_proto_label = l4_proto_to_string(record["proto"] or 0) or ""

   if not isEmptyString(l4_proto_label) then
      flow = flow.."[" .. l4_proto_label .. "] "
   end

   local l7proto_name = interface.getnDPIProtoName(tonumber(record["l7_proto"]) or 0)

   if record["l7_master_proto"] and record["l7_master_proto"] ~= "0" then
      local l7proto_master_name = interface.getnDPIProtoName(tonumber(record["l7_master_proto"]))

      if l7proto_master_name ~= l7proto_name then
	 l7proto_name = string.format("%s.%s", l7proto_master_name, l7proto_name)
      end
   end

   if not isEmptyString(l7proto_name) and l4_proto_label ~= l7proto_name then
      flow = flow.."["..i18n("application")..": " ..l7proto_name.."] "
   end

   if decoded ~= nil then
      -- render the json
      local msg = ""

      if not isEmptyString(record["flow_status"]) then
         msg = msg..getFlowStatus(tonumber(record["flow_status"]), status_info).." "
      end

      if not isEmptyString(flow) then
         msg = msg..flow.." "
      end

      if not isEmptyString(decoded["info"]) then
         local lb = ""
         if (record["flow_status"] == "13") -- blacklisted flow
                  and (not flow["srv.blacklisted"]) and (not flow["cli.blacklisted"]) then
            lb = " <i class='fa fa-ban' aria-hidden='true' title='Blacklisted'></i>"
         end
         msg = msg.."["..i18n("info")..": "..decoded["info"]..lb.."] "
      end

      flow = msg
   end

   if status_info then
      flow = flow..getFlowStatusInfo(record, status_info)
   end

   return flow
end

-- #################################

local function getMenuEntries(status, selection_name, get_params)
   local actual_entries = {}
   local params = table.clone(get_params)

   -- Remove previous filters
   params.alert_severity = nil
   params.alert_type = nil

   if selection_name == "severity" then
      actual_entries = performAlertsQuery("select alert_severity id, count(*) count", status, params, nil, "alert_severity" --[[ group by ]])
    elseif selection_name == "type" then
      actual_entries = performAlertsQuery("select alert_type id, count(*) count", status, params, nil, "alert_type" --[[ group by ]])
   end

   return(actual_entries)
end

-- #################################

local function dropdownUrlParams(get_params)
  local buttons = ""

  for param, val in pairs(get_params) do
    -- NOTE: exclude the ifid parameter to avoid interface selection issues with system interface alerts
    if((param ~= "alert_severity") and (param ~= "alert_type") and (param ~= "status") and (param ~= "ifid")) then
      buttons = buttons.."&"..param.."="..val
    end
  end

  return(buttons)
end

-- #################################

local function drawDropdown(status, selection_name, active_entry, entries_table, button_label, get_params, actual_entries)
   -- alert_consts.alert_severity_keys and alert_consts.alert_type_keys are defined in lua_utils
   local id_to_label
   if selection_name == "severity" then
      id_to_label = alertSeverityLabel
   elseif selection_name == "type" then
      id_to_label = alertTypeLabel
   end

   actual_entries = actual_entries or getMenuEntries(status, selection_name, get_params)

   local buttons = '<div class="btn-group">'

   button_label = button_label or firstToUpper(selection_name)
   if active_entry ~= nil and active_entry ~= "" then
      button_label = firstToUpper(active_entry)..'<span class="glyphicon glyphicon-filter"></span>'
   end

   buttons = buttons..'<button class="btn btn-link dropdown-toggle" data-toggle="dropdown">'..button_label
   buttons = buttons..'<span class="caret"></span></button>'

   buttons = buttons..'<ul class="dropdown-menu dropdown-menu-right" role="menu">'

   local class_active = ""
   if active_entry == nil then class_active = ' class="active"' end
   buttons = buttons..'<li'..class_active..'><a href="?status='..status..dropdownUrlParams(get_params)..'">All</a></i>'

   for _, entry in pairs(actual_entries) do
      local id = tonumber(entry["id"])
      local count = entry["count"]

      if(id >= 0) then
        local label = id_to_label(id, true)

        class_active = ""
        if label == active_entry then class_active = ' class="active"' end
        -- buttons = buttons..'<li'..class_active..'><a href="'..ntop.getHttpPrefix()..'/lua/show_alerts.lua?status='..status
        buttons = buttons..'<li'..class_active..'><a href="?status='..status
        buttons = buttons..dropdownUrlParams(get_params)
        buttons = buttons..'&alert_'..selection_name..'='..id..'">'
        buttons = buttons..firstToUpper(label)..' ('..count..')</a></li>'
      end
   end

   buttons = buttons..'</ul></div>'

   return buttons
end

-- #################################

local function getGlobalAlertsConfigurationHash(granularity, entity_type, local_hosts)
   return 'ntopng.prefs.alerts_global.'..granularity.."."..get_global_alerts_hash_key(entity_type, local_hosts)
end

local global_redis_thresholds_key = "thresholds"

-- #################################

local function printConfigTab(entity_type, entity_value, page_name, page_params, alt_name, options)
   local trigger_alerts = true
   local ifid = interface.getId()
   local trigger_alerts_checked
   local cur_bitmap
   local host_bitmap_key

   if(entity_type == "host") then
      host_bitmap_key = string.format("ntopng.prefs.alerts.ifid_%d.disabled_status.host_%s", ifid, entity_value)
      cur_bitmap = tonumber(ntop.getPref(host_bitmap_key)) or 0
   end

   if _SERVER["REQUEST_METHOD"] == "POST" then
      if _POST["trigger_alerts"] ~= "1" then
         trigger_alerts = false
      else
         trigger_alerts = true
      end

      if(not trigger_alerts) then
        ntop.setHashCache(get_alerts_suppressed_hash_name(ifid), entity_value, tostring(trigger_alerts))
      else
        -- Delete the entry to save space
        ntop.delHashCache(get_alerts_suppressed_hash_name(ifid), entity_value)
      end

      interface.refreshSuppressedAlertsPrefs(alertEntity(entity_type), entity_value)

      if(entity_type == "host") then
         local bitmap = 0

         if not isEmptyString(_POST["disabled_status"]) then
           local status_selection = split(_POST["disabled_status"], ",") or { _POST["disabled_status"] }

           for _, status in pairs(status_selection) do
             bitmap = ntop.bitmapSet(bitmap, tonumber(status))
           end
         end

         if(bitmap ~= cur_bitmap) then
           ntop.setPref(host_bitmap_key, string.format("%u", bitmap))
           cur_bitmap = bitmap
           interface.reloadHostDisableFlowAlertTypes(entity_value)
         end
      end
   else
      trigger_alerts = toboolean(ntop.getHashCache(get_alerts_suppressed_hash_name(ifid), entity_value))
   end

   if trigger_alerts == false then
      trigger_alerts_checked = ""
   else
      trigger_alerts = true
      trigger_alerts_checked = "checked"
   end

  print[[
   <br>
   <form id="alerts-config" class="form-inline" method="post">
   <input name="csrf" type="hidden" value="]] print(ntop.getRandomCSRFValue()) print[[" />
   <table class="table table-bordered table-striped">]]
  print[[<tr>
         <th width="25%">]] print(i18n("device_protocols.alert")) print[[</th>
         <td>
               <input type="checkbox" name="trigger_alerts" value="1" ]] print(trigger_alerts_checked) print[[>
                  <i class="fa fa-exclamation-triangle fa-lg"></i>
                  ]] print(i18n("show_alerts.trigger_alert_descr")) print[[
               </input>
         </td>
      </tr>]]

   if(entity_type == "host") then
      print[[<tr>
         <td width="30%">
           <b>]] print(i18n("host_details.status_ignore")) print[[</b> <i class="fa fa-info-circle" title="]] print(i18n("host_details.disabled_flow_status_help")) print[["></i>
         </td>
         <td>
           <input id="status_trigger_alert" name="disabled_status" type="hidden" />
           <select onchange="convertMultiSelect()" id="status_trigger_alert_select" multiple class="form-control" style="width:40em; height:10em; display:inline;">]]

      for status_id, status in pairsByKeys(flow_consts.flow_status_types, asc) do
        if(status_id == flow_consts.status_normal) then
          goto continue
        end

        print[[<option value="]] print(string.format("%d", status_id))
        if ntop.bitmapIsSet(cur_bitmap, tonumber(status_id)) then
          print[[" selected="selected]]
        end
        print[[">]]
        print(i18n(status.i18n_title))
        print[[</option>]]

        ::continue::
      end

      print[[</select><div style="margin-top:1em;"><i>]] print(i18n("host_details.multiple_selection")) print[[</i></div>
         <button type="button" class="btn btn-default" style="margin-top:1em;" onclick="resetMultiSelect()">]] print(i18n("reset")) print[[</button>
         </td>
      </tr>]]
   end
   print[[</table>
   <button class="btn btn-primary" style="float:right; margin-right:1em;" disabled="disabled" type="submit">]] print(i18n("save_configuration")) print[[</button>
   </form>
   <br><br>
   <script>
    function convertMultiSelect() {
      var values = [];

      $("#status_trigger_alert_select option:selected").each(function(idx, item) {
        values.push($(item).val());
      });

      $("#status_trigger_alert").val(values.join(","));
      $("#status_trigger_alert").trigger("change");
    }

    function resetMultiSelect() {
       $("#status_trigger_alert_select option:selected").each(function(idx, item) {
         item.selected = "";
       });

       convertMultiSelect();
    }

    /* Run after page load */
    $(convertMultiSelect);

    aysHandleForm("#alerts-config");
   </script>]]
end

-- #################################

local function thresholdStr2Val(threshold)
  local parts = string.split(threshold, ";") or {threshold}

  if(#parts >= 2) then
    return {metric=parts[1], operator=parts[2], edge=parts[3] --[[can be nil]]}
  end
end

local function getEntityConfiguredAlertThresholds(ifname, granularity, entity_type, local_hosts, check_modules)
   local thresholds_key = get_alerts_hash_name(granularity, ifname, entity_type)
   local thresholds_config = {}
   local skip_defaults = {}
   local res = {}

   -- Handle the global configuration
   local thresholds_str = ntop.getHashCache(getGlobalAlertsConfigurationHash(granularity, entity_type, local_hosts), global_redis_thresholds_key)
   local global_key = get_global_alerts_hash_key(entity_type, local_hosts)

   if not isEmptyString(thresholds_str) then
     thresholds_config[global_key] = thresholds_str
   end

   -- Entity specific/global alerts
   for entity_val, thresholds_str in pairs(table.merge(thresholds_config, ntop.getHashAllCache(thresholds_key) or {})) do
      local thresholds = split(thresholds_str, ",")
      res[entity_val] = {}

      for _, threshold in pairs(thresholds) do
        local val = thresholdStr2Val(threshold)

        if(val) then
          if(val.edge) then
            res[entity_val][val.metric] = val
          else
            skip_defaults[val.metric] = true
          end
        end
      end
   end

   res[global_key] = res[global_key] or {}

      -- Add defaults
   for modname, check_module in pairs(check_modules) do
     local default_value = alerts_api.getCheckModuleDefaultValue(check_module, granularity)

     if((res[global_key][modname] == nil) and (default_value ~= nil) and (not skip_defaults[modname])) then
       res[global_key][modname] = thresholdStr2Val(default_value)
     end
   end

   return res
end

-- #################################

function drawAlertSourceSettings(entity_type, alert_source, delete_button_msg, delete_confirm_msg, page_name, page_params, alt_name, show_entity, options)
   local has_engaged_alerts, has_past_alerts, has_flow_alerts = false,false,false
   local has_disabled_alerts = alerts_api.hasEntitiesWithAlertsDisabled(interface.getId())
   local tab = _GET["tab"]
   local have_nedge = ntop.isnEdge()
   options = options or {}

   local descr = alerts_api.load_check_modules(entity_type)

   local anomaly_config_key = nil
   local flow_rate_alert_thresh, syn_alert_thresh

   if entity_type == "host" then
      anomaly_config_key = 'ntopng.prefs.'..(options.host_ip)..':'..tostring(options.host_vlan)..'.alerts_config'
   end

   print('<ul class="nav nav-tabs">')

   local function printTab(tab, content, sel_tab)
      if(tab == sel_tab) then print("\t<li class=active>") else print("\t<li>") end
      print("<a href=\""..ntop.getHttpPrefix().."/lua/"..page_name.."?page=alerts&tab="..tab)
      for param, value in pairs(page_params) do
         print("&"..param.."="..value)
      end
      print("\">"..content.."</a></li>\n")
   end

   if(show_entity) then
      -- these fields will be used to perform queries
      _GET["entity"] = alertEntity(show_entity)
      _GET["entity_val"] = alert_source
   end

   if(show_entity) then
      -- possibly process pending delete arguments
      checkDeleteStoredAlerts()

      -- possibly add a tab if there are alerts configured for the host
      has_engaged_alerts = hasAlerts("engaged", getTabParameters(_GET, "engaged"))
      has_past_alerts = hasAlerts("historical", getTabParameters(_GET, "historical"))
      has_flow_alerts = hasAlerts("historical-flows", getTabParameters(_GET, "historical-flows"))

      if(has_engaged_alerts or has_past_alerts or has_flow_alerts) then
         if(has_engaged_alerts) then
           tab = tab or "alert_list"
           printTab("alert_list", i18n("show_alerts.engaged_alerts"), tab)
         end
         if(has_past_alerts) then
           tab = tab or "past_alert_list"
           printTab("past_alert_list", i18n("show_alerts.past_alerts"), tab)
         end
         if(has_flow_alerts) then
           tab = tab or "flow_alert_list"
           printTab("flow_alert_list", i18n("show_alerts.flow_alerts"), tab)
         end
      else
         -- if there are no alerts, we show the alert settings
         if(tab=="alert_list") then tab = nil end
      end
   end

   -- Default tab
   if(tab == nil) then tab = "min" end
   local is_alert_list_tab = ((tab == "alert_list") or (tab == "past_alert_list") or (tab == "flow_alert_list"))

   if((not is_alert_list_tab) and (tab ~= "config")) then
      local granularity_label = alertEngineLabel(alertEngine(tab))

      print(
	 template.gen("modal_confirm_dialog.html", {
			 dialog={
			    id      = "deleteAlertSourceSettings",
			    action  = "deleteAlertSourceSettings()",
			    title   = i18n("show_alerts.delete_alerts_configuration"),
			    message = i18n(delete_confirm_msg, {granularity=granularity_label}) .. " <span style='white-space: nowrap;'>" .. ternary(alt_name ~= nil, alt_name, alert_source).."</span>?",
			    confirm = i18n("delete")
			 }
	 })
      )

      print(
	 template.gen("modal_confirm_dialog.html", {
			 dialog={
			    id      = "deleteGlobalAlertConfig",
			    action  = "deleteGlobalAlertConfig()",
			    title   = i18n("show_alerts.delete_alerts_configuration"),
			    message = i18n("show_alerts.delete_config_message", {conf = entity_type, granularity=granularity_label}).."?",
			    confirm = i18n("delete")
			 }
	 })
      )
   end

   for k, granularity in pairsByField(alert_consts.alerts_granularities, "granularity_id", asc) do
      local l = i18n(granularity.i18n_title)
      local resolution = granularity.granularity_seconds

      if (not options.remote_host) or resolution <= 60 then
	 --~ l = '<i class="fa fa-cog" aria-hidden="true"></i>&nbsp;'..l
	 printTab(k, l, tab)
      end
   end

   printTab("config", '<i class="fa fa-cog" aria-hidden="true"></i> ' .. i18n("traffic_recording.settings"), tab)

   local global_redis_hash = getGlobalAlertsConfigurationHash(tab, entity_type, not options.remote_host)

   print('</ul>')

   if((show_entity) and is_alert_list_tab) then
      drawAlertTables(has_past_alerts, has_engaged_alerts, has_flow_alerts, has_disabled_alerts, _GET, true, nil, { dont_nest_alerts = true })
   elseif(tab == "config") then
      printConfigTab(entity_type, alert_source, page_name, page_params, alt_name, options)
   else
      -- Before doing anything we need to check if we need to save values

      vals = { }
      alerts = ""
      global_alerts = ""
      to_save = false

      -- Needed to handle the defaults
      local check_modules = alerts_api.load_check_modules(entity_type)

      if((_POST["to_delete"] ~= nil) and (_POST["SaveAlerts"] == nil)) then
         if _POST["to_delete"] == "local" then
            -- Delete threshold configuration
            ntop.delHashCache(get_alerts_hash_name(tab, ifname, entity_type), alert_source)
            alerts = nil

            -- Load the global settings normally
            global_alerts = ntop.getHashCache(global_redis_hash, global_redis_thresholds_key)
         else
            -- Only delete global configuration
            ntop.delCache(global_redis_hash)
         end
      end

      if _POST["to_delete"] ~= "local" then
	 if not table.empty(_POST) then
	    to_save = true
	 end

         -- TODO refactor this into the threshold cross checker
         for _, check_module in pairs(descr) do
            k = check_module.key
            value    = _POST["value_"..k]
            operator = _POST["op_"..k] or "gt"
            if value == "on" then value = "1" end
            value = tonumber(value)

            if(value ~= nil) then
               if(alerts ~= "") then alerts = alerts .. "," end
               alerts = alerts .. k .. ";" .. operator .. ";" .. value
            end

            -- Handle global settings
            local global_value = _POST["value_global_"..k]
            local global_operator = _POST["op_global_"..k] or "gt"
            if global_value == "on" then global_value = "1" end
            global_value = tonumber(global_value)

            local default_value = alerts_api.getCheckModuleDefaultValue(check_modules[k], tab)

            if((global_value == nil) and (default_value ~= nil)) then
               -- save an empty value to differentiate it from the default
               global_value = ""
            end

            if(global_value ~= nil) then
               local cur_value = k..";"..global_operator..";"..global_value

               -- Do not save default values
               if(cur_value ~= default_value) then
                  if(global_alerts ~= "") then global_alerts = global_alerts .. "," end
                  global_alerts = global_alerts..cur_value
               end
            end
         end --END for k,_ in pairs(descr) do

         --print(alerts)

         if(to_save and (_POST["to_delete"] == nil)) then
            -- This specific entity alerts
            if(alerts == "") then
               ntop.delHashCache(get_alerts_hash_name(tab, ifname, entity_type), alert_source)
            else
               ntop.setHashCache(get_alerts_hash_name(tab, ifname, entity_type), alert_source, alerts)
            end

            -- Global alerts
            if(global_alerts ~= "") then
               ntop.setHashCache(global_redis_hash, global_redis_thresholds_key, global_alerts)
            else
               ntop.delHashCache(global_redis_hash, global_redis_thresholds_key)
            end
         end
      end -- END if _POST["to_delete"] ~= nil

      -- Reuse getEntityConfiguredAlertThresholds instead of directly read from hash to handle defaults
      local alert_config = getEntityConfiguredAlertThresholds(ifname, tab, entity_type, not options.remote_host, check_modules) or {}
      alerts = alert_config[alert_source]
      global_alerts = alert_config[get_global_alerts_hash_key(entity_type, not options.remote_host)]

      for _, al in pairs({
	    {prefix = "", config = alerts},
	    {prefix = "global_", config = global_alerts},
      }) do
	 if al.config ~= nil then
      for k, v in pairs(al.config) do
        vals[(al.prefix)..k] = v
      end
	 end
      end

      local label

      if entity_type == "host" then
        if options.remote_host then
          label = i18n("remote_hosts")
        else
          label = i18n("alerts_thresholds_config.active_local_hosts")
        end
      else
        label = firstToUpper(entity_type) .. "s"
      end

      print [[
       </ul>
       <form method="post">
       <br>
       <table id="user" class="table table-bordered table-striped" style="clear: both"> <tbody>
       <tr><th>]] print(i18n("alerts_thresholds_config.threshold_type")) print[[</th><th width=30%>]] print(i18n("alerts_thresholds_config.thresholds_single_source", {source=firstToUpper(entity_type),alt_name=ternary(alt_name ~= nil, alt_name, alert_source)})) print[[</th><th width=30%>]] print(i18n("alerts_thresholds_config.common_thresholds_local_sources", {source=label}))
      print[[</th></tr>]]
      print('<input id="csrf" name="csrf" type="hidden" value="'..ntop.getRandomCSRFValue()..'" />\n')

      for _, check_module in pairsByKeys(descr, asc) do
        local key = check_module.key
        local gui_conf = check_module.gui
	local show_input = true

	if check_module.granularity then
	   -- check if the check is performed and thus has to
	   -- be configured at this granularity
	   show_input = false

	   for _, gran in pairs(check_module.granularity) do
	      if gran == tab then
		 show_input = true
		 break
	      end
	   end
  end

  if(check_module.local_only and options.remote_host) then
    show_input = false
  end

        if not gui_conf or not show_input then
          goto next_module
        end

         print("<tr><td><b>".. i18n(gui_conf.i18n_title) .."</b><br>")
         print("<small>"..i18n(gui_conf.i18n_description).."</small>\n")

         for _, prefix in pairs({"", "global_"}) do
            if check_module.gui.input_builder then
              local k = prefix..key
              local value = vals[k]

              if(check_module.gui.input_builder ~= alerts_api.threshold_cross_input_builder) then
                -- Temporary fix to handle non-thresholds
                k = "value_" .. k

                if(value ~= nil) then
                  value = tonumber(value.edge)
                end
              end

              print("</td><td>")

              print(check_module.gui.input_builder(check_module.gui or {}, k, value))
            end
         end

         print("</td></tr>\n")
         ::next_module::
      end

      print [[
      </tbody> </table>
      <input type="hidden" name="SaveAlerts" value="">

      <button class="btn btn-primary" style="float:right; margin-right:1em;" disabled="disabled" type="submit">]] print(i18n("save_configuration")) print[[</button>
      </form>

      <button class="btn btn-default" onclick="$('#deleteGlobalAlertConfig').modal('show');" style="float:right; margin-right:1em;"><i class="fa fa-trash" aria-hidden="true" data-original-title="" title=""></i> ]] print(i18n("show_alerts.delete_config_btn",{conf=firstToUpper(entity_type)})) print[[</button>
      <button class="btn btn-default" onclick="$('#deleteAlertSourceSettings').modal('show');" style="float:right; margin-right:1em;"><i class="fa fa-trash" aria-hidden="true" data-original-title="" title=""></i> ]] print(delete_button_msg) print[[</button>
      ]]

      print("<div style='margin-top:4em;'><b>" .. i18n("alerts_thresholds_config.notes") .. ":</b><ul>")

      print("<li>" .. i18n("alerts_thresholds_config.note_control_threshold_checks_periods") .. "</li>")
      print("<li>" .. i18n("alerts_thresholds_config.note_thresholds_expressed_as_delta") .. "</li>")
      print("<li>" .. i18n("alerts_thresholds_config.note_consecutive_checks") .. "</li>")

      if (entity_type == "host") then
	 print("<li>" .. i18n("alerts_thresholds_config.note_checks_on_active_hosts") .. "</li>")
      end

      print("</ul></div>")

      print[[
      <script>
         function deleteAlertSourceSettings() {
            var params = {};

            params.to_delete = "local";
            params.csrf = "]] print(ntop.getRandomCSRFValue()) print[[";

            var form = paramsToForm('<form method="post"></form>', params);
            form.appendTo('body').submit();
         }

         function deleteGlobalAlertConfig() {
            var params = {};

            params.to_delete = "global";
            params.csrf = "]] print(ntop.getRandomCSRFValue()) print[[";

            var form = paramsToForm('<form method="post"></form>', params);
            form.appendTo('body').submit();
         }

         aysHandleForm("form", {
            handle_tabs: true,
         });
      </script>
      ]]
   end
end

-- #################################

function housekeepingAlertsMakeRoom(ifId)
   local prefs = ntop.getPrefs()
   local max_num_alerts_per_entity = prefs.max_num_alerts_per_entity
   local max_num_flow_alerts = prefs.max_num_flow_alerts

   local k = get_make_room_keys(ifId)

   if ntop.getCache(k["entities"]) == "1" then
      ntop.delCache(k["entities"])
      local res = interface.queryAlertsRaw(
					   "SELECT alert_entity, alert_entity_val, count(*) count",
					   "GROUP BY alert_entity, alert_entity_val HAVING COUNT >= "..max_num_alerts_per_entity)

      for _, e in pairs(res) do
	 local to_keep = (max_num_alerts_per_entity * 0.8) -- deletes 20% more alerts than the maximum number
	 to_keep = round(to_keep, 0)
	 -- tprint({e=e, total=e.count, to_keep=to_keep, to_delete=to_delete, to_delete_not_discounted=(e.count - max_num_alerts_per_entity)})
	 local cleanup = interface.queryAlertsRaw(
						  "DELETE",
						  "WHERE alert_entity="..e.alert_entity.." AND alert_entity_val=\""..e.alert_entity_val.."\" "
						     .." AND rowid NOT IN (SELECT rowid FROM alerts WHERE alert_entity="..e.alert_entity.." AND alert_entity_val=\""..e.alert_entity_val.."\" "
						     .." ORDER BY alert_tstamp DESC LIMIT "..to_keep..")", false)
      end
   end

   if ntop.getCache(k["flows"]) == "1" then
      ntop.delCache(k["flows"])
      local res = interface.queryFlowAlertsRaw("SELECT count(*) count", "WHERE 1=1")
      local count = tonumber(res[1].count)
      if count ~= nil and count >= max_num_flow_alerts then
	 local to_keep = (max_num_flow_alerts * 0.8)
	 to_keep = round(to_keep, 0)
	 local cleanup = interface.queryFlowAlertsRaw("DELETE",
						      "WHERE rowid NOT IN (SELECT rowid FROM flows_alerts ORDER BY alert_tstamp DESC LIMIT "..to_keep..")")
	 --tprint({total=count, to_delete=to_delete, cleanup=cleanup})
	 --tprint(cleanup)
	 -- TODO: possibly raise a too many flow alerts
      end
   end

end

-- #################################

local function menuEntriesToDbFormat(entries)
  local res = {}

  for entry_id, entry_val in pairs(entries) do
    res[#res + 1] = {
      id = tostring(entry_id),
      count = tostring(entry_val),
    }
  end

  return(res)
end

-- #################################

local function printDisabledAlerts(ifid)
  local entitites = alerts_api.listEntitiesWithAlertsDisabled(ifid)

  print[[
  <div id="#table-disabled-alerts"></div>

  <script>
  $("#table-disabled-alerts").datatable({
    url: "]] print(ntop.getHttpPrefix()) print [[/lua/get_disabled_alerts.lua?ifid=]] print(ifid) print[[",
    showPagination: true,
    title: "]] print(i18n("show_alerts.disabled_alerts")) print[[",
      columns: [
	 {
	    title: "]]print(i18n("show_alerts.alarmable"))print[[",
	    field: "column_entity_formatted",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
          width: '35%',
	    }
	 },{
	    title: "]]print(i18n("show_alerts.alert_type"))print[[",
	    field: "column_type",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
	    }
	 },{
	    title: "]]print(i18n("show_alerts.num_ignored_alerts"))print[[",
	    field: "column_count",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
	    }
	 },{
	    title: "]]print(i18n("show_alerts.alert_actions")) print[[",
	    css: {
	       textAlign: 'center',
	    }
	 }], tableCallback: function() {
        datatableForEachRow("#table-disabled-alerts", function(row_id) {
           datatableAddActionButtonCallback.bind(this)(4, "prepareToggleAlertsDialog('table-disabled-alerts',"+ row_id +"); $('#enable_alert_type').modal('show');", "]] print(i18n("show_alerts.enable_alerts")) print[[");
        })
       }
  });
  </script>]]
end

-- #################################

function drawAlertTables(has_past_alerts, has_engaged_alerts, has_flow_alerts, has_disabled_alerts, get_params, hide_extended_title, alt_nav_tabs, options)
   local alert_items = {}
   local url_params = {}
   local options = options or {}
   local ifid = interface.getId()

   print(
      template.gen("modal_confirm_dialog.html", {
		      dialog={
			 id      = "delete_alert_dialog",
			 action  = "deleteAlertById(delete_alert_id)",
			 title   = i18n("show_alerts.delete_alert"),
			 message = i18n("show_alerts.confirm_delete_alert").."?",
			 confirm = i18n("delete"),
			 confirm_button = "btn-danger",
		      }
      })
   )

   print(
      template.gen("modal_confirm_dialog.html", {
		      dialog={
			 id      = "release_single_alert",
			 action  = "releaseAlert(alert_to_release)",
			 title   = i18n("show_alerts.release_alert"),
			 message = i18n("show_alerts.confirm_release_alert"),
			 confirm = i18n("show_alerts.release_alert_action"),
			 confirm_button = "btn-primary",
		      }
      })
   )

   print(
      template.gen("modal_confirm_dialog.html", {
		      dialog={
			 id      = "enable_alert_type",
			 action  = "toggleAlert(false)",
			 title   = i18n("show_alerts.enable_alerts_title"),
			 message = i18n("show_alerts.enable_alerts_message", {
        type = "<span class='toggle-alert-id'></span>",
        entity_value = "<span class='toggle-alert-entity-value'></span>"
       }),
			 confirm = i18n("show_alerts.enable_alerts"),
		      }
      })
   )

   print(
      template.gen("modal_confirm_dialog.html", {
		      dialog={
			 id      = "disable_alert_type",
			 action  = "toggleAlert(true)",
			 title   = i18n("show_alerts.disable_alerts_title"),
			 message = i18n("show_alerts.disable_alerts_message", {
        type = "<span class='toggle-alert-id'></span>",
        entity_value = "<span class='toggle-alert-entity-value'></span>"
       }),
			 confirm = i18n("show_alerts.disable_alerts"),
		      }
      })
   )

   print(
      template.gen("modal_confirm_dialog.html", {
		      dialog={
			 id      = "myModal",
			 action  = "checkModalDelete()",
			 title   = "",
			 message = i18n("show_alerts.purge_subj_alerts_confirm", {subj = '<span id="modalDeleteContext"></span><span id="modalDeleteAlertsMsg"></span>'}),
			 confirm = i18n("show_alerts.purge_num_alerts", {
					   num_alerts = '<img id="alerts-summary-wait" src="'..ntop.getHttpPrefix()..'/img/loading.gif"/><span id="alerts-summary-body"></span>'
			 }),
		      }
      })
   )

   for k,v in pairs(get_params) do if k ~= "csrf" then url_params[k] = v end end
      if not alt_nav_tabs then
      if not options.dont_nest_alerts then
        print("<br>")
      end
	 print[[
<ul class="nav nav-tabs" role="tablist" id="alert-tabs" style="]] print(ternary(options.dont_nest_alerts, 'display:none', '')) print[[">
<!-- will be populated later with javascript -->
</ul>
]]
	 nav_tab_id = "alert-tabs"
      else
	 nav_tab_id = alt_nav_tabs
      end

      print[[
<script>

function checkAlertActionsPanel() {
   /* check if this tab is handled by this script */
   if(getCurrentStatus() == "" || getCurrentStatus() == "engaged")
      $("#alertsActionsPanel").css("display", "none");
   else
      $("#alertsActionsPanel").css("display", "");
}

function setActiveHashTab(hash) {
   $('#]] print(nav_tab_id) --[[ see "clicked" below for the other part of this logic ]] print[[ a[href="' + hash + '"]').tab('show');
}

/* Handle the current tab */
$(function() {
 $("ul.nav-tabs > li > a").on("shown.bs.tab", function(e) {
      var id = $(e.target).attr("href").substr(1);
      history.replaceState(null, null, "#"+id);
      updateDeleteLabel(id);
      checkAlertActionsPanel();
   });

  var hash = window.location.hash;
  if (! hash && ]] if(isEmptyString(status) and not isEmptyString(_GET["tab"])) then print("true") else print("false") end print[[)
    hash = "#]] print(_GET["tab"] or "") print[[";

  if (hash)
    setActiveHashTab(hash)

  $(function() { checkAlertActionsPanel(); });
});

function getActiveTabId() {
   return $("#]] print(nav_tab_id) print[[ > li.active > a").attr('href').substr(1);
}

function updateDeleteLabel(tabid) {
   var label = $("#purgeBtnLabel");
   var prefix = "]]
      if not isEmptyString(_GET["entity"]) then print(alertEntityLabel(_GET["entity"], true).." ") end
      print [[";
   var val = "";

   if (tabid == "tab-table-engaged-alerts")
      val = "]] print(i18n("show_alerts.engaged")) print[[ ";
   else if (tabid == "tab-table-alerts-history")
      val = "]] print(i18n("show_alerts.past")) print[[ ";
   else if (tabid == "tab-table-flow-alerts-history")
      val = "]] print(i18n("show_alerts.past_flow")) print[[ ";

   label.html(prefix + val);
}

function getCurrentStatus() {
   var tabid = getActiveTabId();

   if (tabid == "tab-table-engaged-alerts")
      val = "engaged";
   else if (tabid == "tab-table-alerts-history")
      val = "historical";
   else if (tabid == "tab-table-flow-alerts-history")
      val = "historical-flows";
   else
      val = "";

   return val;
}

function deleteAlertById(alert_id) {
  var params = {};
  params.id_to_delete = alert_id;
  params.status = getCurrentStatus();
  params.csrf = "]] print(ntop.getRandomCSRFValue()) print[[";

  var form = paramsToForm('<form method="post"></form>', params);
  form.appendTo('body').submit();
}

var alert_to_toggle = null;

function prepareToggleAlertsDialog(table_id, idx) {
  var table_data = $("#" + table_id ).data("datatable").resultset.data;
  var row = table_data[idx];
  alert_to_toggle = row;

  $(".toggle-alert-id").html(noHtml(row.column_type).trim());
  $(".toggle-alert-entity-value").html(noHtml(row.column_entity_formatted).trim())
}

var alert_to_release = null;

function releaseAlert(idx) {
  var table_data = $("#table-engaged-alerts").data("datatable").resultset.data;
  var row = table_data[idx];

  var params = {
    "action": "release_alert",
    "entity": row.column_entity_id,
    "entity_val": row.column_entity_val,
    "alert_type": row.column_type_id,
    "alert_severity": row.column_severity_id,
    "alert_subtype": row.column_subtype,
    "alert_granularity": row.column_granularity,
    "csrf": "]] print(ntop.getRandomCSRFValue()) print[[",
  };

  var form = paramsToForm('<form method="post"></form>', params);
  form.appendTo('body').submit();
}

function toggleAlert(disable) {
  var row = alert_to_toggle;
  var params = {
    "action": disable ? "disable_alert" : "enable_alert",
    "entity": row.column_entity_id,
    "entity_val": row.column_entity_val,
    "alert_type": row.column_type_id,
    "csrf": "]] print(ntop.getRandomCSRFValue()) print[[",
  };

  var form = paramsToForm('<form method="post"></form>', params);
  form.appendTo('body').submit();
}
</script>
]]

      if not alt_nav_tabs then print [[<div class="tab-content">]] end

      local status = _GET["status"]
      if(status == nil) then
	 local tab = _GET["tab"]

	 if(tab == "past_alert_list") then
	    status = "historical"
	 elseif(tab == "flow_alert_list") then
	    status = "historical-flows"
	 end
      end

      local status_reset = (status == nil)
      local ts_utils = require "ts_utils"

      if(has_engaged_alerts) then
	 alert_items[#alert_items + 1] = {
	    ["label"] = i18n("show_alerts.engaged_alerts"),
	    ["chart"] = ternary(ts_utils.exists("iface:engaged_alerts", {ifid = ifid}), "iface:engaged_alerts", ""),
	    ["div-id"] = "table-engaged-alerts",  ["status"] = "engaged"}
      elseif status == "engaged" then
	 status = nil; status_reset = 1
      end

      if(has_past_alerts) then
	 alert_items[#alert_items +1] = {
	    ["label"] = i18n("show_alerts.past_alerts"),
	    ["chart"] = "",
	    ["div-id"] = "table-alerts-history",  ["status"] = "historical"}
      elseif status == "historical" then
	 status = nil; status_reset = 1
      end

      if(has_flow_alerts) then
	 alert_items[#alert_items +1] = {
	    ["label"] = i18n("show_alerts.flow_alerts"),
	    ["chart"] = "",
	    ["div-id"] = "table-flow-alerts-history",  ["status"] = "historical-flows"}
      elseif status == "historical-flows" then
	 status = nil; status_reset = 1
      end

      if has_disabled_alerts then
	 alert_items[#alert_items +1] = {
	    ["label"] = i18n("show_alerts.disabled_alerts"),
	    ["chart"] = "",
	    ["div-id"] = "table-disabled-alerts",  ["status"] = "disabled-alerts"}
      end

      for k, t in ipairs(alert_items) do
	 local clicked = "0"
	 if((not alt_nav_tabs) and ((k == 1 and status == nil) or (status ~= nil and status == t["status"]))) then
	    clicked = "1"
	 end
	 print [[
      <div class="tab-pane fade in" id="tab-]] print(t["div-id"]) print[[">
	<div id="]] print(t["div-id"]) print[["></div>
      </div>

      <script type="text/javascript">
      $("#]] print(nav_tab_id) print[[").append('<li class="]] print(ternary(options.dont_nest_alerts, 'hidden', '')) print[["><a href="#tab-]] print(t["div-id"]) print[[" clicked="]] print(clicked) print[[" role="tab" data-toggle="tab">]] print(t["label"]) print[[</a></li>')
      </script>
   ]]

   if t["status"] == "disabled-alerts" then
     printDisabledAlerts(ifid)
     goto next_menu_item
   end

   print[[
      <script type="text/javascript">
         $('a[href="#tab-]] print(t["div-id"]) print[["]').on('shown.bs.tab', function (e) {
         // append the li to the tabs

	 $("#]] print(t["div-id"]) print[[").datatable({
			url: "]] print(ntop.getHttpPrefix()) print [[/lua/get_alerts_table_data.lua?" + $.param(]] print(tableToJsObject(getTabParameters(url_params, t["status"]))) print [[),
               showFilter: true,
	       showPagination: true,
               buttons: [']]

   local title = t["label"]..ternary(t["chart"] ~= "", " <small><A HREF='"..ntop.getHttpPrefix().."/lua/if_stats.lua?ifid="..ifid.."&page=historical&ts_schema="..t["chart"].."'><i class='fa fa-area-chart fa-sm'></i></A></small>", "")

	 if(options.hide_filters ~= true)  then
	    -- alert_consts.alert_severity_keys and alert_consts.alert_type_keys are defined in lua_utils
	    local alert_severities = {}
	    for s, _ in pairs(alert_consts.alert_severities) do alert_severities[#alert_severities +1 ] = s end
	    local alert_types = {}
	    for s, _ in pairs(alert_consts.alert_types) do alert_types[#alert_types +1 ] = s end
	    local type_menu_entries = nil
	    local sev_menu_entries = nil

	    local a_type, a_severity = nil, nil
	    if clicked == "1" then
	       if tonumber(_GET["alert_type"]) ~= nil then a_type = alertTypeLabel(_GET["alert_type"], true) end
	       if tonumber(_GET["alert_severity"]) ~= nil then a_severity = alertSeverityLabel(_GET["alert_severity"], true) end
	    end

	    if t["status"] == "engaged" then
	       local res = interface.getEngagedAlertsCount(tonumber(_GET["entity"]), _GET["entity_val"], _GET["entity_excludes"])

	       if(res ~= nil) then
		  type_menu_entries = menuEntriesToDbFormat(res.type)
		  sev_menu_entries = menuEntriesToDbFormat(res.severities)
	       end
	    end

	    print(drawDropdown(t["status"], "type", a_type, alert_types, i18n("alerts_dashboard.alert_type"), get_params, type_menu_entries))
	    print(drawDropdown(t["status"], "severity", a_severity, alert_severities, i18n("alerts_dashboard.alert_severity"), get_params, sev_menu_entries))
	 elseif((not isEmptyString(_GET["entity_val"])) and (not hide_extended_title)) then
	    if entity == "host" then
	       title = title .. " - " .. firstToUpper(formatAlertEntity(getInterfaceId(ifname), entity, _GET["entity_val"], nil))
	    end
	 end

   if options.dont_nest_alerts then
     title = ""
   end

	 print[['],
/*
               buttons: ['<div class="btn-group"><button class="btn btn-link dropdown-toggle" data-toggle="dropdown">Severity<span class="caret"></span></button><ul class="dropdown-menu" role="menu"><li>test severity</li></ul></div><div class="btn-group"><button class="btn btn-link dropdown-toggle" data-toggle="dropdown">Type<span class="caret"></span></button><ul class="dropdown-menu" role="menu"><li>test type</li></ul></div>'],
*/
]]

	 if(_GET["currentPage"] ~= nil and _GET["status"] == t["status"]) then
	    print("currentPage: ".._GET["currentPage"]..",\n")
	 end
	 if(_GET["perPage"] ~= nil and _GET["status"] == t["status"]) then
	    print("perPage: ".._GET["perPage"]..",\n")
	 end
	 print ('sort: [ ["' .. getDefaultTableSort("alerts") ..'","' .. getDefaultTableSortOrder("alerts").. '"] ],\n')
	 print [[
	        title: "]] print(title) print[[",
      columns: [
	 {
	    title: "]]print(i18n("show_alerts.alert_datetime"))print[[",
	    field: "column_date",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
	    }
	 },

	 {
	    title: "]]print(i18n("show_alerts.alert_duration"))print[[",
	    field: "column_duration",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
	    }
	 },

	 {
	    title: "]]print(i18n("show_alerts.alert_count"))print[[",
	    field: "column_count",
            hidden: ]] print(ternary(t["status"] ~= "historical-flows", "true", "false")) print[[,
            sortable: true,
	    css: {
	       textAlign: 'center'
	    }
	 },

	 {
	    title: "]]print(i18n("show_alerts.alert_severity"))print[[",
	    field: "column_severity",
            sortable: true,
	    css: {
	       textAlign: 'center'
	    }
	 },

	 {
	    title: "]]print(i18n("show_alerts.alert_type"))print[[",
	    field: "column_type",
            sortable: true,
	    css: {
	       textAlign: 'center',
          whiteSpace: 'nowrap',
	    }
	 },

	 {
	    title: "]]print(i18n("drilldown"))print[[",
	    field: "column_chart",
            sortable: false,
	    hidden: ]] print(ternary(not interfaceHasNindexSupport() or ntop.isPro(), "false", "true")) print[[,
	    css: {
	       textAlign: 'center'
	    }
	 },

	 {
	    title: "]]print(i18n("show_alerts.alert_description"))print[[",
	    field: "column_msg",
	    css: {
	       textAlign: 'left',
	    }
	 },

    {
      field: "column_key",
      hidden: true
    },
    {
	    title: "]]print(i18n("show_alerts.alert_actions")) print[[",
	    css: {
	       textAlign: 'center',
	       width: "10%",
	    }
	 },

      ], tableCallback: function() {
            var table_data = $("#]] print(t["div-id"]) print[[").data("datatable").resultset.data;

            datatableForEachRow("#]] print(t["div-id"]) print[[", function(row_id) {              
               var alert_key = $("td:nth(7)", this).html().split("|");
               var alert_id = alert_key[0];
               var data = table_data[row_id];
               var explorer_url = data["column_explorer"];

               if(explorer_url) {
                  datatableAddLinkButtonCallback.bind(this)(9, explorer_url, "]] print(i18n("show_alerts.explorer")) print[[");
                  disable_alerts_dialog = "#disable_flows_alerts";
               } else if(!data.column_alert_disabled)
                  datatableAddActionButtonCallback.bind(this)(9, "prepareToggleAlertsDialog(']] print(t["div-id"]) print[[',"+ row_id +"); $('#disable_alert_type').modal('show');", "]] print(i18n("show_alerts.disable_alerts")) print[[");
               else
                  datatableAddActionButtonCallback.bind(this)(9, "prepareToggleAlertsDialog(']] print(t["div-id"]) print[[',"+ row_id +"); $('#enable_alert_type').modal('show');", "]] print(i18n("show_alerts.enable_alerts")) print[[");

               if(]] print(ternary(t["status"] == "engaged", "true", "false")) print[[)
                 datatableAddActionButtonCallback.bind(this)(9, "alert_to_release = "+ row_id +"; $('#release_single_alert').modal('show');", "]] print(i18n("show_alerts.release_alert_action")) print[[");

               if(]] print(ternary(t["status"] ~= "engaged", "true", "false")) print[[)
                 datatableAddDeleteButtonCallback.bind(this)(9, "delete_alert_id ='" + alert_id + "'; $('#delete_alert_dialog').modal('show');", "]] print(i18n('delete')) print[[");

               $("form", this).submit(function() {
                  // add "status" parameter to the form
                  var get_params = paramsExtend(]] print(tableToJsObject(getTabParameters(url_params, nil))) print[[, {status:getCurrentStatus()});
                  $(this).attr("action", "?" + $.param(get_params));

                  return true;
               });
         });
      }
   });
   });
   ]]
	 if (clicked == "1") then
	    print[[
         // must wait for modalDeleteAlertsStatus to be created
         $(function() {
            var status_reset = ]] print(tostring(status_reset)) --[[ this is necessary because of status parameter inconsistency after tab switch ]] print[[;
            var tabid;

            if ((status_reset) || (getCurrentStatus() == "")) {
               tabid = "]] print("tab-"..t["div-id"]) print[[";
               history.replaceState(null, null, "#"+tabid);
            } else {
               tabid = getActiveTabId();
            }

            updateDeleteLabel(tabid);
         });
      ]]
	 end
	 print[[
   </script>
	      ]]

       ::next_menu_item::
      end

      local zoom_vals = {
	 { i18n("show_alerts.5_min"),  5*60*1, i18n("show_alerts.older_5_minutes_ago") },
	 { i18n("show_alerts.30_min"), 30*60*1, i18n("show_alerts.older_30_minutes_ago") },
	 { i18n("show_alerts.1_hour"),  60*60*1, i18n("show_alerts.older_1_hour_ago") },
	 { i18n("show_alerts.1_day"),  60*60*24, i18n("show_alerts.older_1_day_ago") },
	 { i18n("show_alerts.1_week"),  60*60*24*7, i18n("show_alerts.older_1_week_ago") },
	 { i18n("show_alerts.1_month"),  60*60*24*31, i18n("show_alerts.older_1_month_ago") },
	 { i18n("show_alerts.6_months"),  60*60*24*31*6, i18n("show_alerts.older_6_months_ago") },
	 { i18n("show_alerts.1_year"),  60*60*24*366 , i18n("show_alerts.older_1_year_ago") }
      }

      if(has_engaged_alerts or has_past_alerts or has_flow_alerts) then
	 -- trigger the click on the right tab to force table load
	 print[[
<script type="text/javascript">
$("[clicked=1]").trigger("click");
</script>
]]

	 if not alt_nav_tabs then print [[</div> <!-- closes tab-content -->]] end
	 local has_fixed_period = ((not isEmptyString(_GET["epoch_begin"])) or (not isEmptyString(_GET["epoch_end"])))

	 print('<div id="alertsActionsPanel">')
	 print('<br>' ..  i18n("show_alerts.alerts_to_purge") .. ': ')
	 print[[<select id="deleteZoomSelector" class="form-control" style="display:]] if has_fixed_period then print("none") else print("inline") end print[[; width:14em; margin:0 1em;">]]
	 local all_msg = ""

	 if not has_fixed_period then
	    print('<optgroup label="' .. i18n("show_alerts.older_than") .. '">')
	    for k,v in ipairs(zoom_vals) do
	       print('<option data-older="'..(os.time() - zoom_vals[k][2])..'" data-msg="'.." "..zoom_vals[k][3].. '">'..zoom_vals[k][1]..'</option>\n')
	    end
	    print('</optgroup>')
	 else
	    all_msg = " " .. i18n("show_alerts.in_the_selected_time_frame")
	 end

	 print('<option selected="selected" data-older="0" data-msg="') print(all_msg) print('">' .. i18n("all") .. '</option>\n')


	 print[[</select>
       <form id="modalDeleteForm" class="form-inline" style="display:none;" method="post" onsubmit="return checkModalDelete();">
         <input type="hidden" id="modalDeleteAlertsOlderThan" value="-1" />
         <input id="csrf" name="csrf" type="hidden" value="]] print(ntop.getRandomCSRFValue()) print[[" />
      </form>
    ]]

	    -- we need to dynamically modify parameters at js-time because we switch tab
	 local delete_params = getTabParameters(url_params, nil)
	 delete_params.epoch_end = -1

	 print[[<button id="buttonOpenDeleteModal" data-toggle="modal" data-target="#myModal" class="btn btn-default"><i type="submit" class="fa fa-trash-o"></i> <span id="purgeBtnMessage">]]
	 print(i18n("show_alerts.purge_subj_alerts", {subj='<span id="purgeBtnLabel"></span>'}))
	 print[[</span></button>
   </div> <!-- closes alertsActionsPanel -->

<script>

paramsToForm('#modalDeleteForm', ]] print(tableToJsObject(delete_params)) print[[);

function getTabSpecificParams() {
   var tab_specific = {status:getCurrentStatus()};
   var period_end = $('#modalDeleteAlertsOlderThan').val();
   if (parseInt(period_end) > 0)
      tab_specific.epoch_end = period_end;

   if (tab_specific.status == "]] print(_GET["status"]) print[[") {
      tab_specific.alert_severity = ]] if tonumber(_GET["alert_severity"]) ~= nil then print(_GET["alert_severity"]) else print('""') end print[[;
      tab_specific.alert_type = ]] if tonumber(_GET["alert_type"]) ~= nil then print(_GET["alert_type"]) else print('""') end print[[;
   }

   // merge the general parameters to the tab specific ones
   return paramsExtend(]] print(tableToJsObject(getTabParameters(url_params, nil))) print[[, tab_specific);
}

function checkModalDelete() {
   var get_params = getTabSpecificParams();
   var post_params = {};
   post_params.csrf = "]] print(ntop.getRandomCSRFValue()) print[[";
   post_params.id_to_delete = "__all__";

   // this actually performs the request
   var form = paramsToForm('<form method="post"></form>', post_params);
   form.attr("action", "?" + $.param(get_params));
   form.appendTo('body').submit();
   return false;
}

var cur_alert_num_req = null;

/* This acts before shown.bs.modal event, avoiding visual fields substitution glitch */
$('#buttonOpenDeleteModal').on('click', function() {
   var lb = $("#purgeBtnLabel");
   var zoomsel = $("#deleteZoomSelector").find(":selected");
   $("#myModal h3").html($("#purgeBtnMessage").html());

   $(".modal-body #modalDeleteAlertsMsg").html(zoomsel.data('msg') + ']]
	 if tonumber(_GET["alert_severity"]) ~= nil then
	    print(' with severity "'..alertSeverityLabel(_GET["alert_severity"], true)..'" ')
	 elseif tonumber(_GET["alert_type"]) ~= nil then
	    print(' with type "'..alertTypeLabel(_GET["alert_type"], true)..'" ')
	 end
	 print[[');
   if (lb.length == 1)
      $(".modal-body #modalDeleteContext").html(" " + lb.html());

   $('#modalDeleteAlertsOlderThan').val(zoomsel.data('older'));

   cur_alert_num_req = $.ajax({
      type: 'GET',
      ]] print("url: '"..ntop.getHttpPrefix().."/lua/get_num_alerts.lua'") print[[,
       data: $.extend(getTabSpecificParams(), {ifid: ]] print(_GET["ifid"] or "null") print[[}),
       complete: function() {
         $("#alerts-summary-wait").hide();
       }, error: function() {
         $("#alerts-summary-body").html("?");
       }, success: function(count){
         $("#alerts-summary-body").html(count);
         if (count == 0)
            $('#myModal button[type="submit"]').attr("disabled", "disabled");
       }
    });
});

$('#myModal').on('hidden.bs.modal', function () {
   if(cur_alert_num_req) {
      cur_alert_num_req.abort();
      cur_alert_num_req = null;
   }

   $("#alerts-summary-wait").show();
   $("#alerts-summary-body").html("");
   $('#myModal button[type="submit"]').removeAttr("disabled");
})
</script>]]
      end

end

-- #################################

function drawAlerts(options)
   local has_engaged_alerts = hasAlerts("engaged", getTabParameters(_GET, "engaged"))
   local has_past_alerts = hasAlerts("historical", getTabParameters(_GET, "historical"))
   local has_disabled_alerts = alerts_api.hasEntitiesWithAlertsDisabled(interface.getId())
   local has_flow_alerts = false

   if _GET["entity"] == nil then
     has_flow_alerts = hasAlerts("historical-flows", getTabParameters(_GET, "historical-flows"))
   end

   checkDeleteStoredAlerts()
   checkDisableAlerts()
   return drawAlertTables(has_past_alerts, has_engaged_alerts, num_flow_alerts, has_disabled_alerts, _GET, true, nil, options)
end

-- #################################

-- Get all the configured threasholds for the specified interface
-- NOTE: an additional "interfaces" key is added if there are globally
-- configured threasholds (threasholds active for all the interfaces)
function getInterfaceConfiguredAlertThresholds(ifname, granularity, check_modules)
  return(getEntityConfiguredAlertThresholds(ifname, granularity, "interface", nil, check_modules))
end

-- #################################

-- Get all the configured threasholds for local hosts on the specified interface
-- NOTE: an additional "local_hosts" key is added if there are globally
-- configured threasholds (threasholds active for all the hosts of the interface)
function getLocalHostsConfiguredAlertThresholds(ifname, granularity, check_modules)
  return(getEntityConfiguredAlertThresholds(ifname, granularity, "host", true, check_modules))
end

-- #################################

-- Get all the configured threasholds for remote hosts on the specified interface
-- NOTE: an additional "local_hosts" key is added if there are globally
-- configured threasholds (threasholds active for all the hosts of the interface)
function getRemoteHostsConfiguredAlertThresholds(ifname, granularity, check_modules)
  return(getEntityConfiguredAlertThresholds(ifname, granularity, "host", false, check_modules))
end

-- #################################

-- Get all the configured threasholds for networks on the specified interface
-- NOTE: an additional "local_networks" key is added if there are globally
-- configured threasholds (threasholds active for all the hosts of the interface)
function getNetworksConfiguredAlertThresholds(ifname, granularity, check_modules)
  return(getEntityConfiguredAlertThresholds(ifname, granularity, "network", nil, check_modules))
end

-- #################################

function check_networks_alerts(granularity)
   if(granularity == "min") then
      interface.checkNetworksAlertsMin()
   elseif(granularity == "5mins") then
      interface.checkNetworksAlerts5Min()
   elseif(granularity == "hour") then
      interface.checkNetworksAlertsHour()
   elseif(granularity == "day") then
      interface.checkNetworksAlertsDay()
   else
      traceError(TRACE_ERROR, TRACE_CONSOLE, "Unknown granularity " .. granularity)
   end
end

-- #################################

local function check_interface_alerts(granularity)
   if(granularity == "min") then
      interface.checkInterfaceAlertsMin()
   elseif(granularity == "5mins") then
      interface.checkInterfaceAlerts5Min()
   elseif(granularity == "hour") then
      interface.checkInterfaceAlertsHour()
   elseif(granularity == "day") then
      interface.checkInterfaceAlertsDay()
   else
      traceError(TRACE_ERROR, TRACE_CONSOLE, "Unknown granularity " .. granularity)
   end
end

-- #################################

local function check_hosts_alerts(granularity)
   if(granularity == "min") then
      interface.checkHostsAlertsMin()
   elseif(granularity == "5mins") then
      interface.checkHostsAlerts5Min()
   elseif(granularity == "hour") then
      interface.checkHostsAlertsHour()
   elseif(granularity == "day") then
      interface.checkHostsAlertsDay()
   else
      traceError(TRACE_ERROR, TRACE_CONSOLE, "Unknown granularity " .. granularity)
   end
end

-- #################################

function newAlertsWorkingStatus(ifstats, granularity)
   local res = {
      granularity = granularity,
      engine = alertEngine(granularity),
      ifid = ifstats.id,
      now = os.time(),
      interval = granularity2sec(granularity),
   }
   return res
end

-- #################################

-- A redis set with mac addresses as keys
local function getActiveDevicesHashKey(ifid)
   return "ntopng.cache.active_devices.ifid_" .. ifid
end

function deleteActiveDevicesKey(ifid)
   ntop.delCache(getActiveDevicesHashKey(ifid))
end

-- #################################

local function getSavedDeviceNameKey(mac)
   return "ntopng.cache.devnames." .. mac
end

local function setSavedDeviceName(mac, name)
   local key = getSavedDeviceNameKey(mac)
   ntop.setCache(key, name)
end

local function getSavedDeviceName(mac)
   local key = getSavedDeviceNameKey(mac)
   return ntop.getCache(key)
end

local function check_macs_alerts(ifid, granularity)
   if granularity ~= "min" then
      return
   end

   local active_devices_set = getActiveDevicesHashKey(ifid)
   local seen_devices_hash = getFirstSeenDevicesHashKey(ifid)
   local seen_devices = ntop.getHashAllCache(seen_devices_hash) or {}
   local prev_active_devices = swapKeysValues(ntop.getMembersCache(active_devices_set) or {})
   local alert_new_devices_enabled = ntop.getPref("ntopng.prefs.alerts.device_first_seen_alert") == "1"
   local alert_device_connection_enabled = ntop.getPref("ntopng.prefs.alerts.device_connection_alert") == "1"
   local new_active_devices = {}

   callback_utils.foreachDevice(getInterfaceName(ifid), nil, function(devicename, devicestats, devicebase)
				   -- note: location is always lan when capturing from a local interface
				   if (not devicestats.special_mac) and (devicestats.location == "lan") then
				      local mac = devicestats.mac

				      if not seen_devices[mac] then
					 -- First time we see a device
					 ntop.setHashCache(seen_devices_hash, mac, tostring(os.time()))

					 if alert_new_devices_enabled then
					    local name = getDeviceName(mac)
					    setSavedDeviceName(mac, name)

              alerts_api.store(
                alerts_api.macEntity(mac),
                alerts_api.newDeviceType(name)
              )
					 end
				      end

				      if not prev_active_devices[mac] then
					 -- Device connection
					 ntop.setMembersCache(active_devices_set, mac)

					 if alert_device_connection_enabled then
					    local name = getDeviceName(mac)
					    setSavedDeviceName(mac, name)

              alerts_api.store(
                alerts_api.macEntity(mac),
                alerts_api.deviceHasConnectedType(name)
              )
					 end
				      else
					 new_active_devices[mac] = 1
				      end
				   end
   end)

   for mac in pairs(prev_active_devices) do
      if not new_active_devices[mac] then
         -- Device disconnection
         local name = getSavedDeviceName(mac)
         ntop.delMembersCache(active_devices_set, mac)

         if alert_device_connection_enabled then
            alerts_api.store(
              alerts_api.macEntity(mac),
              alerts_api.deviceHasDisconnectedType(name)
            )
         end
      end
   end
end

-- #################################

-- A redis set with host pools as keys
local function getActivePoolsHashKey(ifid)
   return "ntopng.cache.active_pools.ifid_" .. ifid
end

function deleteActivePoolsKey(ifid)
   ntop.delCache(getActivePoolsHashKey(ifid))
end

-- #################################

-- Redis hashe with key=pool and value=list of quota_exceed_items, separated by |
local function getPoolsQuotaExceededItemsKey(ifid)
   return "ntopng.cache.quota_exceeded_pools.ifid_" .. ifid
end

function deletePoolsQuotaExceededItemsKey(ifid)
   ntop.delCache(getPoolsQuotaExceededItemsKey(ifid))
end

-- #################################

function check_host_pools_alerts(ifid, granularity)
   if granularity ~= "min" then
      return
   end

   local active_pools_set = getActivePoolsHashKey(ifid)
   local prev_active_pools = swapKeysValues(ntop.getMembersCache(active_pools_set)) or {}
   local alert_pool_connection_enabled = ntop.getPref("ntopng.prefs.alerts.pool_connection_alert") == "1"
   local alerts_on_quota_exceeded = ntop.isPro() and ntop.getPref("ntopng.prefs.alerts.quota_exceeded_alert") == "1"
   local pools_stats = nil
   local quota_exceeded_pools_key = getPoolsQuotaExceededItemsKey(ifid)
   local quota_exceeded_pools_values = ntop.getHashAllCache(quota_exceeded_pools_key) or {}
   local quota_exceeded_pools = {}
   local now_active_pools = {}

   -- Deserialize quota_exceeded_pools
   for pool, v in pairs(quota_exceeded_pools_values) do
      quota_exceeded_pools[pool] = {}

      for _, group in pairs(split(quota_exceeded_pools_values[pool], "|")) do
         local parts = split(group, "=")

         if #parts == 2 then
            local proto = parts[1]
            local quota = parts[2]

            local parts = split(quota, ",")
            quota_exceeded_pools[pool][proto] = {toboolean(parts[1]), toboolean(parts[2])}
         end
      end
      -- quota_exceeded_pools[pool] is like {Youtube={true, false}}, where true is bytes_exceeded, false is time_exceeded
   end

   if ntop.isPro() then
      pools_stats = interface.getHostPoolsStats()
   end

   local pools = interface.getHostPoolsInfo()
   if(pools ~= nil) and (pools_stats ~= nil) then
      for pool, info in pairs(pools.num_members_per_pool) do
	 local pool_stats = pools_stats[tonumber(pool)]
	 local pool_exceeded_quotas = quota_exceeded_pools[pool] or {}

	 -- Pool quota
	 if((pool_stats ~= nil) and (shaper_utils ~= nil)) then
	    local quotas_info = shaper_utils.getQuotasInfo(ifid, pool, pool_stats)

	    for proto, info in pairs(quotas_info) do
	       local prev_exceeded = pool_exceeded_quotas[proto] or {false,false}

	       if alerts_on_quota_exceeded then
		  if info.bytes_exceeded and not prev_exceeded[1] then
         alerts_api.store(
            alerts_api.hostPoolEntity(pool),
            alerts_api.poolQuotaExceededType(pool, proto, "traffic_quota", info.bytes_value, info.bytes_quota)
         )
		  end

		  if info.time_exceeded and not prev_exceeded[2] then
         alerts_api.store(
            alerts_api.hostPoolEntity(pool),
            alerts_api.poolQuotaExceededType(pool, proto, "time_quota", info.time_value, info.time_quota)
         )
		  end
	       end

	       if not info.bytes_exceeded and not info.time_exceeded then
		  -- delete as no quota is left
		  pool_exceeded_quotas[proto] = nil
	       else
		  -- update/add serialized
		  pool_exceeded_quotas[proto] = {info.bytes_exceeded, info.time_exceeded}
	       end
	    end

	    if table.empty(pool_exceeded_quotas) then
	       ntop.delHashCache(quota_exceeded_pools_key, pool)
	    else
	       -- Serialize the new quota information for the pool
	       for proto, value in pairs(pool_exceeded_quotas) do
		  pool_exceeded_quotas[proto] = table.concat({tostring(value[1]), tostring(value[2])}, ",")
	       end

	       ntop.setHashCache(quota_exceeded_pools_key, pool, table.tconcat(pool_exceeded_quotas, "=", "|"))
	    end
	 end

	 -- Pool presence
	 if (pool ~= host_pools_utils.DEFAULT_POOL_ID) and (info.num_hosts > 0) then
	    now_active_pools[pool] = 1

	    if not prev_active_pools[pool] then
	       -- Pool connection
	       ntop.setMembersCache(active_pools_set, pool)

	       if alert_pool_connection_enabled then
            alerts_api.store(
              alerts_api.hostPoolEntity(pool),
              alerts_api.poolConnectionType(pool)
            )
	       end
	    end
	 end
      end
   end

   -- Pool presence
   for pool in pairs(prev_active_pools) do
      if not now_active_pools[pool] then
         -- Pool disconnection
         ntop.delMembersCache(active_pools_set, pool)

         if alert_pool_connection_enabled then
            alerts_api.store(
              alerts_api.hostPoolEntity(pool),
              alerts_api.poolDisconnectionType(pool)
            )
         end
      end
   end
end

-- #################################

function scanAlerts(granularity, ifstats)
   if not mustScanAlerts(ifstats) then return end

   local ifname = ifstats["name"]
   local ifid = getInterfaceId(ifname)

   if(verbose) then print("[minute.lua] Scanning ".. granularity .." alerts for interface " .. ifname.."\n") end

   check_interface_alerts(granularity)
   check_networks_alerts(granularity)
   check_hosts_alerts(granularity)
   check_macs_alerts(ifid, granularity)
   check_host_pools_alerts(ifid, granularity)

   if ntop.getInfo()["test_mode"] then
      package.path = dirs.installdir .. "/scripts/lua/modules/test/?.lua;" .. package.path
      local test_utils = require "test_utils"
      if test_utils then
	 test_utils.check_alerts(ifid, granularity)
      end
   end
end

-- #################################

local function deleteCachePattern(pattern)
   local keys = ntop.getKeysCache(pattern)

   for key in pairs(keys or {}) do
      ntop.delCache(key)
   end
end

function disableAlertsGeneration()
   if not haveAdminPrivileges() then
      return
   end

   -- Ensure we do not conflict with others
   ntop.setPref("ntopng.prefs.disable_alerts_generation", "1")
   ntop.reloadPreferences()
   if(verbose) then io.write("[Alerts] Disable done\n") end
end

-- #################################

function flushAlertsData()
   if not haveAdminPrivileges() then
      return
   end

   local selected_interface = ifname
   local ifnames = interface.getIfNames()
   local force_query = true
   local generation_toggle_backup = ntop.getPref("ntopng.prefs.disable_alerts_generation")

   if(verbose) then io.write("[Alerts] Temporary disabling alerts generation...\n") end
   ntop.setAlertsTemporaryDisabled(true);
   ntop.msleep(3000)

   callback_utils.foreachInterface(ifnames, nil, function(ifname, ifstats)
				      if(verbose) then io.write("[Alerts] Processing interface "..ifname.."...\n") end
				      interface.refreshSuppressedAlertsPrefs()

				      if(verbose) then io.write("[Alerts] Flushing SQLite configuration...\n") end
				      performAlertsQuery("DELETE", "engaged", {}, force_query)
				      performAlertsQuery("DELETE", "historical", {}, force_query)
				      performAlertsQuery("DELETE", "historical-flows", {}, force_query)
   end)

   if(verbose) then io.write("[Alerts] Flushing Redis configuration...\n") end
   deleteCachePattern("ntopng.prefs.*alert*")
   deleteCachePattern("ntopng.alerts.*")
   deleteCachePattern(getGlobalAlertsConfigurationHash("*", "*", true))
   deleteCachePattern(getGlobalAlertsConfigurationHash("*", "*", false))
   ntop.delCache(get_alerts_suppressed_hash_name("*"))
   for _, key in pairs(get_make_room_keys("*")) do deleteCachePattern(key) end

   if(verbose) then io.write("[Alerts] Enabling alerts generation...\n") end
   ntop.setAlertsTemporaryDisabled(false);

   callback_utils.foreachInterface(ifnames, nil, function(_ifname, ifstats)
      interface.refreshSuppressedAlertsPrefs()
   end)

   ntop.setPref("ntopng.prefs.disable_alerts_generation", generation_toggle_backup)
   refreshAlerts(interface.getId())

   if(verbose) then io.write("[Alerts] Flush done\n") end
   interface.select(selected_interface)
end

-- #################################

function alertNotificationActionToLabel(action)
   local label = ""

   if action == "engage" then
      label = "[Engaged]"
   elseif action == "release" then
      label = "[Released]"
   end

   return label
end

-- #################################

function formatAlertMessage(ifid, alert, skip_peers)
  local msg

  if(alert.alert_entity == alertEntity("flow") or (alert.alert_entity == nil)) then
    msg = formatRawFlow(alert, alert["alert_json"], nil, skip_peers)
  else
    msg = alert["alert_json"]

    if(string.sub(msg, 1, 1) == "{") then
      msg = json.decode(msg)
    end

    local description = alertTypeDescription(alert.alert_type)

    if(type(description) == "string") then
      -- localization string
      msg = i18n(description, msg)
    elseif(type(description) == "function") then
      msg = description(ifid, alert, msg)
    end
  end

  return(msg)
end

-- #################################

function notification_timestamp_asc(a, b)
   return (a.alert_tstamp < b.alert_tstamp)
end

function notification_timestamp_rev(a, b)
   return (a.alert_tstamp > b.alert_tstamp)
end

-- Returns a summary of the alert as readable text
function formatAlertNotification(notif, options)
   local defaults = {
      nohtml = false,
      show_severity = true,
   }
   options = table.merge(defaults, options)

   local msg = "[" .. formatEpoch(notif.alert_tstamp or 0) .. "]"
   msg = msg .. ternary(options.show_severity == false, "", "[" .. alertSeverityLabel(notif.alert_severity, options.nohtml) .. "]") ..
      "[" .. alertTypeLabel(notif.alert_type, options.nohtml) .."]"

   -- entity can be hidden for example when one is OK with just the message
   if options.show_entity then
      msg = msg.."["..alertEntityLabel(notif.alert_entity).."]"

      if notif.alert_entity ~= "flow" then
	 local ev = notif.alert_entity_val
	 if notif.alert_entity == "host" then
	    -- suppresses @0 when the vlan is zero
	    ev = hostinfo2hostkey(hostkey2hostinfo(notif.alert_entity_val))
	 end

	 msg = msg.."["..ev.."]"
      end
   end

   -- add the label, that is, engaged or released
   msg = msg .. alertNotificationActionToLabel(notif.action).. " "
   local alert_message = formatAlertMessage(notif.ifid, notif)

   if options.nohtml then
      msg = msg .. noHtml(alert_message)
   else
      msg = msg .. alert_message
   end

   return msg
end

-- ##############################################

-- Processes queued alerts and returns the information necessary to store them.
-- Alerts are only enqueued by AlertsQueue in C. From lua, the alerts_api
-- can be called directly as slow operations will be postponed
local function processStoreAlertFromQueue(alert)
  local entity_info = nil
  local type_info = nil

  interface.select(tostring(alert.ifid))

  if(alert.alert_type == alertType("ip_outsite_dhcp_range")) then
    local router_info = {host = alert.router_ip, vlan = alert.vlan_id}
    entity_info = alerts_api.hostAlertEntity(alert.client_ip, alert.vlan_id)
    type_info = alerts_api.ipOutsideDHCPRangeType(router_info, alert.mac_address, alert.client_mac, alert.sender_mac)
  elseif(alert.alert_type == alertType("slow_periodic_activity")) then
    entity_info = alerts_api.periodicActivityEntity(alert.path)
    type_info = alerts_api.slowPeriodicActivityType(alert.duration_ms, alert.max_duration_ms)
  elseif(alert.alert_type == alertType("mac_ip_association_change")) then
    local name = getSavedDeviceName(alert.new_mac)
    entity_info = alerts_api.macEntity(alert.new_mac)
    type_info = alerts_api.macIpAssociationChangeType(name, alert.ip, alert.old_mac, alert.new_mac)
  elseif(alert.alert_type == alertType("login_failed")) then
    entity_info = alerts_api.userEntity(alert.user)
    type_info = alerts_api.loginFailedType()
  elseif(alert.alert_type == alertType("broadcast_domain_too_large")) then
    entity_info = alerts_api.macEntity(alert.src_mac)
    type_info = alerts_api.broadcastDomainTooLargeType(alert.src_mac, alert.dst_mac, alert.vlan_id, alert.spa, alert.tpa)
  elseif(alert.alert_type == alertType("remote_to_remote")) then
    local host_info = {host = alert.host, vlan = alert.vlan}
    entity_info = alerts_api.hostAlertEntity(alert.host, alert.vlan)
    type_info = alerts_api.remoteToRemoteType(host_info, alert.mac_address)
  elseif((alert.alert_type == alertType("alert_user_activity")) and (alert.scope == "login")) then
    entity_info = alerts_api.userEntity(alert.user)
    type_info = alerts_api.userActivityType("login", nil, nil, nil, "authorized")
  elseif(alert.alert_type == alertType("nfq_flushed")) then
    entity_info = alerts_api.interfaceAlertEntity(alert.ifid)
    type_info = alerts_api.nfqFlushedType(getInterfaceName(alert.ifid), alert.pct, alert.tot, alert.dropped)
  else
    traceError(TRACE_ERROR, TRACE_CONSOLE, "Unknown alert type " .. (alert.alert_type or ""))
  end

  return entity_info, type_info
end

-- ##############################################

-- Global function
-- NOTE: this is executed in a system VM, with no interfaces references
function checkStoreAlertsFromC(deadline)
  if(not areAlertsEnabled()) then
    return
  end

  while(os.time() <= deadline) do
    -- TODO add max_length check and alert
    local message = ntop.lpopCache(store_alerts_queue)

    if((message == nil) or (message == "")) then
      break
    end

    if(verbose) then print(message.."\n") end

    local alert = json.decode(message)

    if(alert == nil) then
      if(verbose) then io.write("JSON Decoding error: "..message.."\n") end
    else
      local entity_info, type_info = processStoreAlertFromQueue(alert)

      if((type_info ~= nil) and (entity_info ~= nil)) then
        alerts_api.store(entity_info, type_info, alert.alert_tstamp)
      end
    end
  end
end

-- ##############################################

-- NOTE: this is executed in a system VM, with no interfaces references
function processAlertNotifications(now, periodic_frequency, force_export)
   if(not areAlertsEnabled()) then
      return
   end

   local interfaces = interface.getIfNames()

   -- Get new alerts
   while(true) do
      local json_message = ntop.lpopCache("ntopng.alerts.notifications_queue")

      if((json_message == nil) or (json_message == "")) then
         break
      end

      if(verbose) then
         io.write("Alert Notification: " .. json_message .. "\n")
      end

      local message = json.decode(json_message)

      if(not message) then
        goto continue
      end

      local str_ifid = tostring(message.ifid)

      if((interfaces[str_ifid] == nil) and (str_ifid ~= getSystemInterfaceId())) then
        goto continue
      end

      interface.select(str_ifid)

      if((message.rowid ~= nil) and (message.table_name ~= nil)) then
        -- A rowid has been passed instead of actual notification information,
        -- retrieve the alert from sqlite
        local res = performAlertsQuery("SELECT *", luaTableName(message.table_name), {row_id = message.rowid})

        if((res == nil) or (#res ~= 1)) then
          if not interface.isPcapDumpInterface() then
            traceError(TRACE_WARNING, TRACE_CONSOLE,
              string.format("Could not retrieve alert information [ifid=%s][table=%s][rowid=%s]",
              message.ifid, message.table_name, message.rowid))
          end

          goto continue
        end

        -- Build the actual alert notification
        message.rowid = nil
        message.table_name = nil
        message = table.merge(message, res[1])
        json_message = json.encode(message)
      end

      alert_endpoints.dispatchNotification(message, json_message)
      ::continue::
   end

   alert_endpoints.processNotifications(now, periodic_frequency)
end

-- ##############################################

local function notify_ntopng_status(started)
   local info = ntop.getInfo()
   local severity = alertSeverity("info")
   local msg
   local msg_details = string.format("%s v.%s (%s) [pid: %s][options: %s]", info.product, info.version, info.OS, info.pid, info.command_line)
   local anomalous = false
   local event
   
   if(started) then
      -- let's check if we are restarting from an anomalous termination
      -- e.g., from a crash
      if not recovery_utils.check_clean_shutdown() then
        -- anomalous termination
        msg = string.format("%s %s", i18n("alert_messages.ntopng_anomalous_termination", {url="https://www.ntop.org/support/need-help-2/need-help/"}), msg_details)
        severity = alertSeverity("error")
        anomalous = true
        event = "anomalous_termination"
      else
	 -- normal termination
        msg = string.format("%s %s", i18n("alert_messages.ntopng_start"), msg_details)
        event = "start"
      end
   else
      msg = string.format("%s %s", i18n("alert_messages.ntopng_stop"), msg_details)
      event = "stop"
   end

   local entity_value = "ntopng"

   obj = {
      entity_type = alertEntity("process"), entity_value=entity_value,
      type = alertType("process_notification"),
      severity = severity,
      message = msg,
      when = os.time() }

   if anomalous then
      telemetry_utils.notify(obj)
   end

  local entity_info = alerts_api.processEntity(entity_value)
  local type_info = alerts_api.processNotificationType(event, severity, msg_details)

  interface.select(getSystemInterfaceId())  
  return(alerts_api.store(entity_info, type_info))
end

function notify_snmp_device_interface_status_change(snmp_host, snmp_interface)
  local entity_info = alerts_api.snmpInterfaceEntity(snmp_host, snmp_interface["index"])
  local type_info = alerts_api.snmpInterfaceStatusChangeType(snmp_host, snmp_interface["index"], snmp_interface["name"], snmp_interface["status"])

  interface.select(getSystemInterfaceId())  
  return(alerts_api.store(entity_info, type_info))
end

function notify_snmp_device_interface_duplexstatus_change(snmp_host, snmp_interface)
  local entity_info = alerts_api.snmpInterfaceEntity(snmp_host, snmp_interface["index"])
  local type_info = alerts_api.snmpInterfaceDuplexStatusChangeType(snmp_host, snmp_interface["index"], snmp_interface["name"], snmp_interface["duplexstatus"])

  interface.select(getSystemInterfaceId())
  return(alerts_api.store(entity_info, type_info))
end

function notify_snmp_device_interface_errors(snmp_host, snmp_interface)
  local entity_info = alerts_api.snmpInterfaceEntity(snmp_host, snmp_interface["index"])
  local type_info = alerts_api.snmpInterfaceErrorsType(snmp_host, snmp_interface["index"], snmp_interface["name"])

  interface.select(getSystemInterfaceId())
  return(alerts_api.store(entity_info, type_info))
end

function notify_snmp_device_interface_load_threshold_exceeded(snmp_host, snmp_interface, interface_load, in_direction)
  local entity_info = alerts_api.snmpInterfaceEntity(snmp_host, snmp_interface["index"])
  local type_info = alerts_api.snmpPortLoadThresholdExceededType(snmp_host, snmp_interface["index"], snmp_interface["name"],
    interface_load, in_direction)

  interface.select(getSystemInterfaceId())
  return(alerts_api.store(entity_info, type_info))
end

function notify_ntopng_start()
   return(notify_ntopng_status(true))
end

function notify_ntopng_stop()
   return(notify_ntopng_status(false))
end

-- DEBUG: uncomment this to test
--~ scanAlerts("min", "wlan0")

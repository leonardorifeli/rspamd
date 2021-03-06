--[[
Copyright (c) 2011-2015, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

-- 0 or 1 received: = spam

local symbol = 'ONCE_RECEIVED'
local symbol_rdns = 'RDNS_NONE'
-- Symbol for strict checks
local symbol_strict = nil
local bad_hosts = {}
local good_hosts = {}
local whitelist = nil
local rspamd_logger = require "rspamd_logger"
local check_local = false
local check_authed = false

local function check_quantity_received (task)
  local recvh = task:get_received_headers()

  local function recv_dns_cb(_, to_resolve, results, err)
    if err and (err ~= 'requested record is not found' and err ~= 'no records with this name') then
      rspamd_logger.errx(task, 'error looking up %s: %s', to_resolve, err)
    end
    task:inc_dns_req()

    if not results then
      if recvh and #recvh <= 1 then
        task:insert_result(symbol, 1)
        task:insert_result(symbol_strict, 1)
      end
      task:insert_result(symbol_rdns, 1)
    else
      rspamd_logger.infox(task, 'SMTP resolver failed to resolve: %1 is %2',
        to_resolve, results[1])
      if good_hosts then
        for _,gh in ipairs(good_hosts) do
          if string.find(results[1], gh) then
            return
          end
        end
      end

      task:insert_result(symbol, 1)
      for _,h in ipairs(bad_hosts) do
        if string.find(results[1], h) then

          task:insert_result(symbol_strict, 1, h)
          return
        end
      end
    end
  end

  local task_ip = task:get_ip()

  if ((not check_authed and task:get_user()) or
      (not check_local and task_ip and task_ip:is_local())) then
    rspamd_logger.infox(task, 'Skipping once_received for authenticated user or local network')
    return
  end
  if whitelist and task_ip and whitelist:get_key(task_ip) then
    rspamd_logger.infox(task, 'whitelisted mail from %s',
      task_ip:to_string())
    return
  end

  local hn = task:get_hostname()
  -- Here we don't care about received
  if (not hn or hn == 'unknown') and task_ip and task_ip:is_valid() then
    task:get_resolver():resolve_ptr({task = task,
      name = task_ip:to_string(),
      callback = recv_dns_cb,
      forced = true
    })
    return
  end

  if recvh and #recvh <= 1 then
    local ret = true
    local r = recvh[1]

    if not r then
      return
    end

    if r['real_hostname'] then
      local rhn = string.lower(r['real_hostname'])
      -- Check for good hostname
      if rhn and good_hosts then
        for _,gh in ipairs(good_hosts) do
          if string.find(rhn, gh) then
            ret = false
            break
          end
        end
      end
    end

    if ret then
      -- Strict checks
      if symbol_strict then
        -- Unresolved host
        task:insert_result(symbol, 1)

        if not hn then return end
        for _,h in ipairs(bad_hosts) do
          if string.find(hn, h) then
            task:insert_result(symbol_strict, 1, h)
            return
          end
        end
      else
        task:insert_result(symbol, 1)
      end
    end
  end
end

-- Registration
if type(rspamd_config.get_api_version) ~= 'nil' then
  if rspamd_config:get_api_version() >= 1 then
    rspamd_config:register_module_option('once_received', 'symbol', 'string')
    rspamd_config:register_module_option('once_received', 'symbol_strict', 'string')
    rspamd_config:register_module_option('once_received', 'bad_host', 'string')
    rspamd_config:register_module_option('once_received', 'good_host', 'string')
  end
end

local opts = rspamd_config:get_all_opt('options')
if opts and type(opts) ~= 'table' then
  if type(opts['check_local']) == 'boolean' then
    check_local = opts['check_local']
  end
  if type(opts['check_authed']) == 'boolean' then
    check_authed = opts['check_authed']
  end
end
-- Configuration
opts = rspamd_config:get_all_opt('once_received')
if opts then
  if opts['symbol'] then
    symbol = opts['symbol']

    local id = rspamd_config:register_symbol({
      name = symbol,
      callback = check_quantity_received,
    })

    for n,v in pairs(opts) do
      if n == 'symbol_strict' then
        symbol_strict = v
      elseif n == 'symbol_rdns' then
        symbol_rdns = v
      elseif n == 'bad_host' then
        if type(v) == 'string' then
          bad_hosts[1] = v
        else
          bad_hosts = v
        end
      elseif n == 'good_host' then
        if type(v) == 'string' then
          good_hosts[1] = v
        else
          good_hosts = v
        end
      elseif n == 'whitelist' then
        whitelist = rspamd_config:add_radix_map (v, 'once received whitelist')
      end
    end

    rspamd_config:register_symbol({
      name = symbol_rdns,
      type = 'virtual',
      parent = id
    })
      rspamd_config:register_symbol({
      name = symbol_strict,
      type = 'virtual',
      parent = id
    })
  end
end

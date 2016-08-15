--[[

  Copyright (C) 2016 Open Lab Athens.

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.

  @license GPL-3.0+ <http://spdx.org/licenses/GPL-3.0+>


  Changes

  15-8-2016: Rowan Thorpe <rowan@rowanthorpe.com>: Original commit

]]

--[[
 TODO:
  * Have [table]:admin, [table]:user, and [table]:session consumers (separate sessions from users, then only allow session-consumer
    jwt-access to tables and session/account-management - except for LOGIN which is open)
  * Add fail2ban jail for LOGIN
  * Optionally configurable token timeout on LOGIN (in params)
  * Create a JWT-Based-Auth plugin for kong (layered on top of JWT-Plugin) to use DAO directly instead of subrequest-based (in the
    meantime at least when kong and backend merged in same nginx process, use internal subrequests rather than full HTTP requests)
  * Proper PATCH handling (using proper "JSON Patch" logic? - maybe wrapping C++ lib - https://github.com/nlohmann/json) ...then again
    even Kong doesn't support this...
  * Use JSON-LD everywhere (and in Kong...?)
]]

--local dbg = require('debugger')
local bcrypt = require('bcrypt')
local crypto = require('crypto')
local http = require('resty.http') -- TODO: include the .new() here for http once cosockets work in init_by_lua context
local cache = require('kong.tools.database_cache')
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64

--------

local bcrypt_rounds = 12 -- pre-tuned for this server's CPU to take ~ 1s, see https://github.com/mikejsavage/lua-bcrypt#user-content-tuning
local kong_admin_port = 8101
local kong_admin_host = '127.0.0.1'
local kong_admin_timeout = 3000 -- milliseconds
local jwt_expiry_timeout = 3600 -- seconds
--local jwt_notbefore_margin = 60 -- seconds
local token_struct = {
   header={
      typ='type',
      alg='algorithm',
   },
   payload={
      iss={'user_name', 'device'},
      aud={'server_name', 'table_name'},
      sub='login_type',
      exp='expiry',
   },
   signature='',
}
local req_table = { -- set sanest defaults here
   version=1.1,
   headers={
      ['Content-Type']='application/json',
      ['Accept']='application/json',
   },
   method='unspecified', -- ...paranoia
   path='unspecified', -- ...paranoia
   body=nil,
}

--------

local function copy(ob, copymethod)
   --[[ copymethod =
      'ref': direct copy by ref for table
      'shallow': copy one level deep for table
      'deep': (default) full deep copy for table
   ]]
   if copymethod == 'ref' or type(ob) ~= 'table' then return ob end
   local meta = getmetatable(ob)
   local target = {}
   for k, v in pairs(ob) do
      if copymethod == 'shallow' or type(v) ~= "table" then
	 target[k] = v
      else
	 target[k] = copy(v, copymethod)
      end
   end
   setmetatable(target, meta)
   return target
end

local function b64_encode(input)
   local result = encode_base64(input)
   result = result:gsub("+", "-"):gsub("/", "_"):gsub("=", "")
   return result
end

local function b64_decode(input)
   local remainder = #input % 4
   if remainder > 0 then
      local padlen = 4 - remainder
      input = input .. string.rep('=', padlen)
   end
   input = input:gsub("-", "+"):gsub("_", "/")
   return decode_base64(input)
end

function string:explode(sep, max)
   if self:find(sep) == nil then
      return {self}
   end
   if max == nil or max < 1 then
      max = 0
   end
   local result = {}
   local pattern = '(.-)' .. sep .. '()'
   local num = 0
   local last
   for chunk, position in self:gmatch(pattern) do
      num = num + 1
      result[num] = chunk
      last = position
      if num == max then
	 break
      end
   end
   if num ~= max then
      result[num + 1] = self:sub(last)
   end
   return result
end

function table.len(tbl)
   local count = 0
   for _ in pairs(tbl) do
      count = count + 1
   end
   return count
end

function table.isin(tbl, key)
   for _, tkey in pairs(tbl) do
      if key == tkey then
	 return true
      end
   end
end

function table.map(tbl, func, keys, with_key)
   local newtbl = {}
   for k, v in pairs(tbl) do
      if not keys or table.isin(keys, k) then
	 if with_key then
	    newtbl[k] = func(k, v)
	 else
	    newtbl[k] = func(v)
	 end
      end
   end
   return newtbl
end

function table.filter(tbl, func, by_key)
   local newtbl = {}
   for i, v in pairs(tbl) do
      local x
      if by_key then
	 x = i
      else
	 x = v
      end
      if func(x) then
	 newtbl[i] = v
      end
   end
   return newtbl
end

--------

local _M = {}

function _M:fail(message, status, log_message, log_level)
   if not message then
      message = 'Unknown error.'
   end
   if not status then
      status = 'INTERNAL_SERVER_ERROR'
   end
   ngx.log(log_level or ngx.ERR, log_message or message)
   ngx.status = ngx['HTTP_' .. status]
   ngx.say('{"status":' .. js.encode(status) .. ',"message":' .. js.encode(message) .. '}')
   ngx.exit(ngx['HTTP_' .. status])
end

function _M:params_get()
   ngx.req.read_body()
   local body = ngx.var.request_body
   if type(body) ~= 'string' or body == '' then
      self:fail('No request body.', 'BAD_REQUEST')
   end
   return body
end

function _M:params_unpack(body)
   local params = js.decode(body)
   if type(params) ~= 'table' then
      self:fail('Invalid request body: ' .. body, 'BAD_REQUEST')
   end
   return params -- NOT "unpacked" (key/val)
end

function _M:param_get(params, param_name, allow_no_exist)
   local validations = {
      user_name='^[a-zA-Z][a-zA-Z0-9_]*$',
      device='^[a-zA-Z][a-zA-Z0-9_]*$',
      secret='^%$[a-z0-9]+%$[0-9]+%$([a-zA-Z0-9+/,:!~_=.$-]+)$' -- should already be bcrypted client-side
   }
   local param = params[param_name]
   if not param or param == '' then
      if not allow_no_exist then
	 self:fail('Missing ' .. param_name .. ' param.', 'BAD_REQUEST')
      end
   else
      local validation = validations[param_name]
      local matched = param:match(validation)
      if not validation or not matched or (param_name == 'secret' and matched:len() ~= 53) then
	 self:fail('Unauthorized.', 'BAD_REQUEST', 'Invalid ' .. param_name .. ' param: ' .. param)
      end
   end
   return param
end

function _M:token_header_get()
   local token_hdr = ngx.var.http_authorization
   if type(token_hdr) ~= 'string' or token_hdr == '' then
      self:fail('Missing token header.', 'BAD_REQUEST')
   end
   return token_hdr
end

function _M:token_get(token_hdr)
   local token = token_hdr:gsub('^ *[bB]earer +', '')
   if token == token_hdr or token == '' then
      self:fail('Invalid token header: ' .. token_hdr, 'BAD_REQUEST')
   end
   return token
end

function _M:token_unpack(token)
   return token:explode('%.')
end

function _M:section_get(sections, section_name)
   local section
   if section_name == 'header' then
      section = sections[1]
   elseif section_name == 'payload' then
      section = sections[2]
   else -- if section_name == 'signature' then
      section = sections[3]
   end
   if type(section) ~= 'string' or section == '' then
      self:fail('Missing token ' .. section_name .. ' section.', 'BAD_REQUEST')
   elseif not section:match('^[a-zA-Z0-9+/,:!~_=-]+$') then
      self:fail('Invalid token ' .. section_name .. ' section: ' .. section, 'BAD_REQUEST')
   end
   return section
end

function _M:section_decode(section)
   local section_decoded = b64_decode(section)
   if type(section_decoded) ~= 'string' then
      self:fail('Badly base64-encoded section: ' .. section, 'BAD_REQUEST')
   end
   return section_decoded
end

function _M:field_get(fields, field_name)
   local field = fields[field_name]
   local field_type = type(field)
   if not field_name then
      self:fail('Missing ' .. field_name .. ' field.', 'BAD_REQUEST')
   elseif field_name == 'exp' and field_type ~= 'number' then
      self:fail('Invalid ' .. field_name .. ' field: ' .. field, 'BAD_REQUEST')
   elseif field_name ~= 'exp' and (field_type ~= 'string' or not field:match('^[a-zA-Z0-9+/,.:!~_=-]+$')) then
      self:fail('Invalid ' .. field_name .. ' field: ' .. field, 'BAD_REQUEST')
   end
   return field
end

function _M:section_unpack_raw(section_decoded, section_name)
   local section_unpacked_raw
   section_unpacked_raw = js.decode(section_decoded)
   if type(section_unpacked_raw) ~= 'table' then
      self:fail('Badly json-encoded ' .. section_name .. ' section: ' .. section_decoded, 'BAD_REQUEST')
   end
   return table.map(
      token_struct[section_name],
      function (k, v)
         return self:field_get(section_unpacked_raw, k)
      end, nil, true
   )
end

function _M:section_unpack(section_unpacked_raw, section_name)
   local section_unpacked = {}
   for k, v in pairs(token_struct[section_name]) do
      if type(v) == 'table' then
	 local templist = self:field_get(section_unpacked_raw, k):explode(':')
	 for i = 1, #v do
	    section_unpacked[v[i]] = templist[i]
	 end
      else
	 section_unpacked[v] = self:field_get(section_unpacked_raw, k)
      end
   end
   return section_unpacked
end

function _M:subfield_get(subfields, subfield_name, ostime)
   local validations = {
      type='^JWT$',
      algorithm='^HS256$',
      server_name='^[a-zA-Z][a-zA-Z0-9_.]*$',
      table_name='^[a-zA-Z][a-zA-Z0-9_]*$',
      user_name='^[a-zA-Z][a-zA-Z0-9_]*$',
      device='^[a-zA-Z][a-zA-Z0-9_]*$',
      login_type={'^admin$', '^user$'},
      expiry={ostime} -- ostime,nil
   }
   local subfield = subfields[subfield_name]
   if not subfield or subfield == '' then
      self:fail('Missing ' .. subfield_name .. ' subfield.', 'BAD_REQUEST')
   else
      local validated = true
      local validation = validations[subfield_name]
      if not validation then
	 validated = false
      else
	 local validation_type = type(validation)
	 if validation_type == 'table' then
	    local validation_sub_type = type(validation[1]) or 'number' -- ([1] == nil only makes sense for number range validation)
	    local subfield_type = type(subfield)
	    if validation_sub_type == 'number' then
	       if subfield_type ~= 'number' or math.floor(subfield) ~= subfield or (validation[1] and subfield < validation[1]) or (validation[2] and subfield > validation[2]) then
		  validated = false
	       end
	    else -- if validation_sub_type == 'string' then
	       if type(subfield) ~= 'string' then
		  validated = false
	       else
		  local loop_validated = false
		  for _, v in pairs(validation) do
		     if not subfield:match(v) then
			loop_validated = true
			break
		     end
		  end
		  validated = loop_validated
	       end
	    end
	 elseif type(subfield) ~= 'string' or not subfield:match(validation) then
	    validated = false
	 end
      end
      if not validated then
	 self:fail('Invalid ' .. subfield_name .. ' subfield.', 'BAD_REQUEST')
      end
   end
   return subfield
end

function _M:token_pack(header_e, payload_e, signature_e)
   return header_e .. '.' .. payload_e .. '.' .. signature_e
end

function _M:sub_request(allowfail, ok_status, ...)
   local req_table = copy(req_table, 'deep')
   if select('#', ...) ~= 0 then
      for i, v in pairs(select(1, ...)) do
	 req_table[i] = v
      end
   end
   local exit_status
   local http = http.new()
   http:set_timeout(kong_admin_timeout)
   http:connect(kong_admin_host, kong_admin_port)
   local req_result, req_err = http:request(req_table)
   local read_result
   if not req_result then
      if allowfail then
	 return nil
      else
	 self:fail('Internal error.', 'INTERNAL_SERVER_ERROR', req_table.method .. ' subrequest to ' .. req_table.path .. ' failed, returned no result: ' .. req_err, ngx.CRIT)
      end
   else
      local read_err
      read_result, read_err = req_result:read_body()
      if req_result.status ~= ok_status then
	 if allowfail and (req_result.status == ngx.HTTP_NOT_FOUND or req_result.status == ngx.HTTP_CONFLICT) then
	    return nil
	 else
	    self:fail('Unauthorized.', 'UNAUTHORIZED', req_table.method .. ' subrequest to ' .. req_table.path .. ' failed, action: ' .. req_result.status, ngx.NOTICE)
	 end
      elseif read_err then
	 self:fail('Internal error.', 'INTERNAL_SERVER_ERROR', req_table.method .. ' subrequest to ' .. req_table.path .. ' failed, reading output: ' .. read_err, ngx.CRIT)
      end
   end
   local close_result, close_err = http:set_keepalive() -- should fall back to close() where needed
   if not close_result then
      ngx.log(ngx.NOTICE, method .. ' subrequest to ' .. req_table.path .. ' failed, setting keepalive-or-close: ' .. close_err)
   end
   if exit_status then
      ngx.exit(exit_status)
   end
   local result
   if read_result and read_result ~= '' then
      result = js.decode(read_result)
      if not result then
	 self:fail('Internal error.', 'INTERNAL_SERVER_ERROR', req_table.method .. ' subrequest to ' .. req_table.path .. ' failed, json-decoding output', ngx.CRIT)
      end
   end
   return result
end

function _M:user_data_get(table_name, login_type, user_name)
   local suffix = ''
   if user_name then
      suffix = '/' .. user_name
   end
   return self:sub_request(
      true,
      ngx.HTTP_OK,
      {
	 method='GET',
	 path=origin_path .. '/' .. table_name .. ':' .. login_type .. '/jwt' .. suffix, -- NB: don't use base_path here, using local vars...
      }
   )
end

function _M:all_data_get()
   return {
      admin=self:user_data_get(u_table_name, 'admin'),
      user=self:user_data_get(u_table_name, 'user')
   }
end

function _M:user_check_exists(all_data, user_name)
   table.map(
      {'admin', 'user'},
      function (y)
	 if all_data[y].total ~= 0 and table.isin(table.map(all_data[y].data, function (x) return x.key end), user_name) then
	    self:fail('User ' .. user_name .. ' already exists.', 'CONFLICT')
	 end
      end
   )
end

function _M:secret_get(...) -- table_name, login_type, user_name
   return self:user_data_get(...).secret
end

function _M:sig_create(header_e, payload_e, secret)
   return crypto.hmac.digest('sha256', header_e .. '.' .. payload_e, secret, true)
end

function _M:sig_verify(signature_e, header_e, payload_e, s_session_secret, token_session_path)
   local stored_session_secret = self:secret_get(token_session_path)

   if stored_session_secret ~= s_session_secret or signature_e ~= b64_encode(self:sig_create(header_e, payload_e, s_session_secret), true) then
      self:fail('Unauthorized.', 'UNAUTHORIZED', 'Authorization token failed signature verification.')
   end
end

function _M:acl_verify(login_type, table_name, user_name, server_name, req_role, req_user_name, req_server_name, req_table_name)
   if not (
      (login_type == 'admin' or req_role == 'user' or (req_role == 'owner' and user_name == req_user_name)) and
	 server_name == req_server_name and
	 table_name == req_table_name
   ) then
      self:fail('Unauthorized.', 'UNAUTHORIZED', 'Authorization token failed ACL verification.')
   end
end

function _M:secret_verify(...) -- p_secret, session_secret
   if not bcrypt.verify(...) then
      self:fail('Unauthorized.', 'UNAUTHORIZED', 'Authorization user/secret failed verification.')
   end
end

function _M:token_sign(header, payload, secret)
   local header_e = b64_encode(js.encode(header), true)
   local payload_e = b64_encode(js.encode(payload), true)
   local signature_e = b64_encode(self:sig_create(header_e, payload_e, secret), true)
   return self:token_pack(header_e, payload_e, signature_e)
end

function _M:secret_get(auth_password_path)
   return self:sub_request(
      false,
      ngx.HTTP_OK,
      {
	 method='GET',
	 path=auth_password_path,
      }
   ).secret
end

function _M:token_extract()
   return self:token_unpack(self:token_get(self:token_header_get()))
end

function _M:params_extract()
   return self:params_unpack(self:params_get())
end

function _M:session_clear_stale(all_data, user_name)
   table.map(
      {'admin', 'user'},
      function (y)
	 if all_data[y].total ~= 0 then
	    table.map(
	       all_data[y].data,
	       function (x)
		  local session_name = x.key:match('^(' .. (user_name or '.+') .. ':.+)$')
		  if session_name then
		     self:sub_request(
			false,
			ngx.HTTP_NO_CONTENT,
			{
			   method='DELETE',
			   path=root_path .. ':' .. y .. '/jwt/' .. session_name, -- NB: don't use base_path here, using local vars...
			}
		     )
		  end
	       end
	    )
	 end
      end
   )
end

--------

function _M:access()
   -- v_ = ngx.var.
   -- u_ = ngx.var. (from url)
   -- p_ = params.
   -- s_ = stored
   -- t_ = token
   -- h_ = http_req_headers

   local token, header_e, payload_e, signature_e, header, payload, signature, token_root_path, token_base_path, token_user_path, token_session_path,
   t_typ, t_alg, t_user_name, t_device, t_server_name, t_table_name, t_login_type, t_expiry
   local params
   local s_session_secret
   local intended_method

   v_request_method, v_server_name = ngx.var.request_method, ngx.var.server_name
   u_context, u_login_type, u_table_name = ngx.var.context, ngx.var.login_type, ngx.var.table_name
   h_origin, h_method, h_headers = ngx.var.http_origin, ngx.var.http_access_control_request_method, ngx.var.http_access_control_request_headers

   ostime = os.time()
   origin_path = '/consumers'
   root_path = origin_path .. '/' .. u_table_name
   base_path = root_path .. ':' .. u_login_type .. '/jwt'
   --req_table.method = v_request_method -- default to the parent-request method (disabled this, less confusing if explicit)
   req_table.path = base_path -- default to the base path

   if v_request_method == 'OPTIONS' then
      intended_method = h_method
   else
      intended_method = v_request_method
   end
   if u_context == 'session' then
      if intended_method == 'POST' then
         jwt_method = 'LOGIN'
      elseif intended_method == 'PATCH' then
         jwt_method = 'REFRESH'
      else -- if intended_method == 'DELETE' then
         jwt_method = 'LOGOUT'
      end
   else -- if u_context == 'account' then
      if intended_method == 'POST' then
         jwt_method = 'REGISTER'
      elseif intended_method == 'PATCH' then
         jwt_method = 'MODIFY'
      else -- if intended_method == 'DELETE' then
         jwt_method = 'DEREGISTER'
      end
   end

   if v_request_method == 'OPTIONS' then
      u_user_name = ngx.var.user_name
      if u_user_name and u_user_name ~= '' then
	 user_path = base_path .. '/' .. u_user_name
      end
      u_device = ngx.var.device
      if u_device and u_device ~= '' then
	 session_path = user_path .. ':' .. u_device
      end
   else
      if jwt_method ~= 'REGISTER' then
      --if u_context ~= 'account' or v_request_method ~= 'POST' then -- get user_name from url for everything except 'REGISTER'
	 u_user_name = ngx.var.user_name
	 user_path = base_path .. '/' .. u_user_name
      end
      if jwt_method ~= 'LOGIN' then
      --if u_context ~= 'session' or v_request_method ~= 'POST' then -- verify token for everything except 'LOGIN'
	 token = self:token_extract()
	 header_e, payload_e, signature_e = self:section_get(token, 'header'), self:section_get(token, 'payload'), self:section_get(token, 'signature')
	 signature = self:section_decode(signature_e)
	 local header_d, payload_d = self:section_decode(header_e), self:section_decode(payload_e)
	 local header_r, payload_r = self:section_unpack_raw(header_d, 'header'), self:section_unpack_raw(payload_d, 'payload')
	 header, payload = self:section_unpack(header_r, 'header'), self:section_unpack(payload_r, 'payload')
	 t_type, t_algorithm = self:subfield_get(header, 'type'), self:subfield_get(header, 'algorithm')
	 t_user_name, t_device, t_server_name, t_table_name, t_login_type, t_expiry = self:subfield_get(payload, 'user_name'), self:subfield_get(payload, 'device'), self:subfield_get(payload, 'server_name'), self:subfield_get(payload, 'table_name'), self:subfield_get(payload, 'login_type'), self:subfield_get(payload, 'expiry', ostime)
	 token_root_path = origin_path .. '/' .. t_table_name
	 token_base_path = token_root_path .. ':' .. t_login_type .. '/jwt'
	 token_user_path = token_base_path .. '/' .. t_user_name
	 token_session_path = token_user_path .. ':' .. t_device
	 s_session_secret = self:secret_get(token_session_path)
	 self:sig_verify(signature_e, header_e, payload_e, s_session_secret, token_session_path)
	 if jwt_method == 'REGISTER' then
         --if u_context == 'account' then
	    --if v_request_method == 'POST' then -- REGISTER
               params = self:params_extract()
               p_user_name = self:param_get(params, 'user_name')
               p_secret = self:param_get(params, 'secret')
         elseif jwt_method == 'MODIFY' then
            --elseif v_request_method == 'PATCH' then -- MODIFY
	       params = self:params_extract()
	       p_user_name = self:param_get(params, 'user_name', true)
	       p_secret = self:param_get(params, 'secret', true)
            ----else -- if v_request_method == 'DELETE' then -- DEREGISTER
            --end
	 elseif jwt_method ~= 'DEREGISTER' then
         --else -- if u_context == 'session' then
            u_device = ngx.var.device
            session_path = user_path .. ':' .. u_device
	 end
      end
      if jwt_method == 'LOGIN' then
      --if u_context == 'session' then
         --if v_request_method == 'POST' then
	 params = self:params_extract()
	 p_secret = self:param_get(params, 'secret')
	 s_user_secret = self:secret_get(user_path)
	 self:secret_verify(p_secret, s_user_secret)
	 p_device = self:param_get(params, 'device')
      elseif jwt_method == 'REFRESH' then
      --elseif v_request_method == 'PATCH' then
	 s_user_secret = self:secret_get(user_path)
      --end
      end
   end
end

function _M:content()
   ngx.header['Access-Control-Allow-Origin'] = h_origin -- TODO: get the actual kong CORS origin configured for this api
   --ngx.header['Access-Control-Allow-Credentials'] = 'true' -- not needed I think (only http-auth,ssl-client-cert,cookies)
   if v_request_method == 'OPTIONS' then
      ngx.header['Content-Length'] = '0'
      ngx.header['Content-Type'] = 'text/plain charset=UTF-8'
      ngx.header['Access-Control-Max-Age'] = '0' -- TODO: '1728000'
      ngx.header['Access-Control-Allow-Headers'] = 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,Keep-Alive,X-Requested-With,If-Modified-Since' -- TODO: add any custom headers from request?
      if jwt_method == 'LOGIN' or jwt_method == 'REGISTER' then
      --if ((u_context == 'session' and (not u_device or u_device == '')) or (u_context == 'account' and (not u_user_name or u_user_name == ''))) then
         ngx.header['Access-Control-Allow-Methods'] = 'POST,OPTIONS'
      else --if jwt_method == 'REFRESH' or jwt_method == 'LOGOUT' or jwt_method == 'MODIFY' or jwt_method == 'DEREGISTER' then
         ngx.header['Access-Control-Allow-Methods'] = 'PATCH,DELETE,OPTIONS'
      end
      ngx.status = ngx.HTTP_NO_CONTENT
      ngx.print('')
   else --if v_request_method ~= 'OPTIONS' then
      local ok_status, ok_output
      local user_name, device
      if jwt_method == 'REGISTER' or jwt_method == 'MODIFY' or jwt_method == 'DEREGISTER' then
      --if u_context == 'acount' then
	 user_name = p_user_name
      else --if jwt_method == 'MODIFY' or jwt_method == 'DEREGISTER' or jwt_method == 'LOGIN' or jwt_method == 'REFRESH' or jwt_method == 'LOGOUT' then
	 user_name = u_user_name
      end
      if jwt_method == 'LOGIN' then
	 device = p_device
      elseif jwt_method == 'REFRESH' or jwt_method == 'LOGOUT' then
	 device = u_device
      end
      if u_context == 'account' then
         local all_data = self:all_data_get()
	 if jwt_method == 'REGISTER' then
	 --if v_request_method == 'POST' then -- REGISTER
	    self:user_check_exists(all_data, user_name)
	 end
         self:session_clear_stale(all_data, user_name)
         if jwt_method == 'REGISTER' then
         --if v_request_method == 'POST' then -- REGISTER
            ok_status = ngx.HTTP_CREATED
            local result = self:sub_request(
               false,
               ok_status,
               {
		  method='POST',
		  --path=base_path,
                  body=js.encode({key=user_name, secret=bcrypt.digest(p_secret, bcrypt_rounds)}),
               }
            )
            local to_return = {}
            for k, v in pairs(result) do
               if k == 'key' then
                  to_return.user_name = v
               elseif k == 'secret' then
                  to_return.secret = v
               end
            end
            if table.len(to_return) ~= 2 or not to_return.user_name or not to_return.secret then
               self:fail('Failed to register user ' .. user_name .. '.', 'CONFLICT')
            end
            to_return.status = 'OK'
            ok_output = js.encode(to_return)
         elseif jwt_method == 'MODIFY' then
         --elseif v_request_method == 'PATCH' then -- MODIFY
            ok_status = ngx.HTTP_OK
            local to_patch = {}
            for k, v in pairs({key=user_name, secret=p_secret}) do
               if v then
                  if k == 'secret' then
                     to_patch[k] = bcrypt.digest(v, bcrypt_rounds)
                  else
                     to_patch[k] = v
                  end
               end
            end
            if table.len(to_patch) == 0 then
               self:fail('Must provide at least one param to modify a user.', 'BAD_REQUEST')
            end
            local result = self:sub_request(
               false,
               ok_status,
               {
		  method='PATCH',
                  path=user_path,
                  body=js.encode(to_patch),
               }
            )
            local to_return = {}
            for k, v in pairs(result) do
               if k == 'key' then
                  to_return.user_name = v
               elseif k == 'secret' then
                  to_return.secret = v
               end
            end
            if table.len(to_return) ~= 2 or not to_return.user_name or not to_return.secret then
               self:fail('Failed to modify user ' .. u_user_name .. '.', 'CONFLICT')
            end
            to_return.status = 'OK'
            ok_output = js.encode(to_return)
         else --if jwt_method == 'DEREGISTER' then
         --else --if v_request_method == 'DELETE' then -- DEREGISTER
            ok_status = ngx.HTTP_NO_CONTENT
            self:sub_request(
               false,
               ok_status,
               {
		  method='DELETE',
                  path=user_path,
               }
            )
         end
      else --if u_context == 'session' then
         if jwt_method == 'LOGIN' then
         --if v_request_method == 'POST' then -- LOGIN
            --s_session_secret = s_user_secret .. '-' .. tostring(ostime) -- kong jwt bug (leading $ in secret)
            s_session_secret = string.char(s_user_secret:byte(2, -1)) .. '-' .. tostring(ostime)
            ok_output = js.encode(
               {
		  status='OK',
                  token=self:token_sign(
                     {
                        typ='JWT',
                        alg='HS256',
                     },
                     {
                        iss=user_name .. ':' .. device,
                        exp=ostime + jwt_expiry_timeout,
                        aud=v_server_name .. ':' .. u_table_name,
                        sub=u_login_type,
                     },
                     s_session_secret
                  )
               }
            )
            ok_status = ngx.HTTP_CREATED
            local result = self:sub_request(
               true,
               ok_status,
               {
		  method='POST',
		  --path=base_path,
                  body=js.encode({key=user_name .. ':' .. device, secret=s_session_secret}),
               }
            )
            if not result then -- fallback to PATCH (REFRESH)
               result = self:sub_request(
                  false,
                  ngx.HTTP_OK,
                  {
                     method='PATCH',
                     path=user_path .. ':' .. device,
                     body=js.encode({secret=s_session_secret}),
                  }
               )
            end
         elseif jwt_method == 'REFRESH' then
         --elseif v_request_method == 'PATCH' then -- REFRESH
            --s_session_secret = s_user_secret .. '-' .. tostring(ostime) -- kong jwt bug (leading $ in secret)
            s_session_secret = string.char(s_user_secret:byte(2, -1)) .. '-' .. tostring(ostime)
            ok_output = js.encode(
               {
		  status='OK',
                  token=self:token_sign(
                     {
                        typ='JWT',
                        alg='HS256',
                     },
                     {
                        iss=user_name .. ':' .. device,
                        exp=ostime + jwt_expiry_timeout,
                        aud=v_server_name .. ':' .. u_table_name,
                        sub=u_login_type,
                     },
                     s_session_secret
                  )
               }
            )
            ok_status = ngx.HTTP_OK
            self:sub_request(
               false,
               ok_status,
               {
		  method='PATCH',
                  path=session_path,
                  body=js.encode({secret=s_session_secret}),
               }
            )
         else --if jwt_method == 'LOGOUT' then
         --else --if v_request_method == 'DELETE' then -- LOGOUT
            ok_status = ngx.HTTP_NO_CONTENT
            self:sub_request(
               false,
               ok_status,
               {
		  method='DELETE',
                  path=session_path,
               }
            )
         end
      end
      -- FIXME: I think the below should *not* be needed, should be "fixed" in plugins/jwt/hooks.lua instead (I guess?)
      if u_context == 'account' then
	 cache.delete(cache.jwtauth_credential_key(user_name))
      else -- if u_context == 'session' then
	 cache.delete(cache.jwtauth_credential_key(user_name .. ':' .. device))
      end
      ngx.status = ok_status
      ngx.print(ok_output or '')
   end
end

--------

return _M

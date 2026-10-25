-- Lua header filter implementing docs/FILTER_SPEC.md (filter-name = "lua").
-- Header-only: uses headers():get/add/replace/remove. No body calls.

local function set_header(headers, name, value)
  if headers:get(name) == nil then
    headers:add(name, value)
  else
    headers:replace(name, value)
  end
end

function envoy_on_request(request_handle)
  local headers = request_handle:headers()

  if headers:get("x-api-key") == "test-key-123" then
    set_header(headers, "x-auth-status", "authenticated")
  else
    set_header(headers, "x-auth-status", "unauthenticated")
    headers:add("x-auth-retry", "true")
  end

  local ua = headers:get("user-agent")
  if ua ~= nil and string.find(ua, "benchmark", 1, true) ~= nil then
    set_header(headers, "x-bench-tag", "lua")
  else
    headers:add("x-bench-tag", "lua-default")
  end

  set_header(headers, "x-request-touched", "true")
  set_header(headers, "x-filter-type", "lua")
  headers:remove("x-drop-me")
end

function envoy_on_response(response_handle)
  local headers = response_handle:headers()

  headers:add("x-resp-added", "lua")
  set_header(headers, "x-resp-version", "v1")
  set_header(headers, "x-gateway", "envoy-lua")
  headers:remove("server")
  headers:remove("x-drop-me")
end

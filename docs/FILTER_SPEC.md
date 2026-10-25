# Canonical Filter Spec

All filter variants (lua, wasm, go, gonvoy) MUST implement this exact logic.
Baseline implements no filter (reference only).

`<filter-name>` in `{lua, wasm, go, gonvoy}` — substitute literally per variant.

## Request (Decode / envoy_on_request / on_http_request_headers)

- IF `x-api-key == "test-key-123"`: Set `x-auth-status=authenticated`
- ELSE: Set `x-auth-status=unauthenticated` + Add `x-auth-retry=true`
- IF `user-agent` contains `"benchmark"`: Set `x-bench-tag=<filter-name>`
- ELSE: Add `x-bench-tag=<filter-name>-default`
- Set `x-request-touched=true` (replace)
- Set `x-filter-type=<filter-name>` (replace)
- Drop `x-drop-me` (remove)
- Always continue (no local reply)

Header-only: MUST NOT touch body/trailers/local-reply — header map APIs only.

Notes:
- "Set" = replace/add semantics (single value); "Add" = append value.
- Header name matching is case-insensitive per HTTP semantics.
- Missing `x-api-key` is treated as ELSE branch.
- `user-agent` substring match is case-sensitive on `"benchmark"`.

## Response (Encode / envoy_on_response / on_http_response_headers)

- Add `x-resp-added=<filter-name>`
- Set `x-resp-version=v1` (replace)
- Set `x-gateway=envoy-<filter-name>` (replace)
- Drop `server` + Drop `x-drop-me`
- Always continue

## Conformance

A variant passes conformance iff, for the request/response cases above,
an end-to-end request through Envoy yields exactly the headers defined here
(verified per variant by its conformance check in Tasks 2-5).

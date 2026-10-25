// Native Go header filter implementing docs/FILTER_SPEC.md (filter-name = "go").
// Header-only: uses Get/Set/Add/Del. No body calls.
package main

import "C"

import (
	"strings"

	"github.com/envoyproxy/envoy/contrib/golang/common/go/api"
	"github.com/envoyproxy/envoy/contrib/golang/filters/http/source/go/pkg/http"
)

type filter struct {
	api.PassThroughStreamFilter
}

func (f *filter) DecodeHeaders(h api.RequestHeaderMap, _ bool) api.StatusType {
	if key, ok := h.Get("x-api-key"); ok && key == "test-key-123" {
		h.Set("x-auth-status", "authenticated")
	} else {
		h.Set("x-auth-status", "unauthenticated")
		h.Add("x-auth-retry", "true")
	}

	if ua, ok := h.Get("user-agent"); ok && strings.Contains(ua, "benchmark") {
		h.Set("x-bench-tag", "go")
	} else {
		h.Add("x-bench-tag", "go-default")
	}

	h.Set("x-request-touched", "true")
	h.Set("x-filter-type", "go")
	h.Del("x-drop-me")
	return api.Continue
}

func (f *filter) EncodeHeaders(h api.ResponseHeaderMap, _ bool) api.StatusType {
	h.Add("x-resp-added", "go")
	h.Set("x-resp-version", "v1")
	h.Set("x-gateway", "envoy-go")
	h.Del("server")
	h.Del("x-drop-me")
	return api.Continue
}

func factory(_ interface{}, _ api.FilterCallbackHandler) api.StreamFilter {
	return &filter{}
}

func init() {
	http.RegisterHttpFilterFactoryAndConfigParser("bench-go", factory, http.NullParser)
}

func main() {}

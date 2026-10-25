// Gonvoy header filter implementing docs/FILTER_SPEC.md (filter-name = "gonvoy").
//
// BenchHandler is a gonvoy.Middleware: request logic runs before next(c),
// response logic runs after it returns. Header-only: request reads via
// c.Header, request sets via c.SetRequestHeader, request add/drop via the
// c.Request().Header escape hatch, response sets via c.SetHeader. No body
// APIs. Always returns nil (passthrough, never a local reply).
//
// NOTE: gonvoy.Context exposes no response-header delete, so the spec's
// response drops (server, x-drop-me) cannot be expressed here; the bridge
// forwards those upstream headers untouched. See task-5-report.md.
package main

import (
	"strings"

	"github.com/ardikabs/gonvoy"
)

func BenchHandler(next gonvoy.Handler) gonvoy.Handler {
	return gonvoy.Handler(func(c gonvoy.Context) error {
		if c.Header("x-api-key") == "test-key-123" {
			c.SetRequestHeader("x-auth-status", "authenticated")
		} else {
			c.SetRequestHeader("x-auth-status", "unauthenticated")
			c.Request().Header.Add("x-auth-retry", "true")
		}

		if strings.Contains(c.Header("user-agent"), "benchmark") {
			c.SetRequestHeader("x-bench-tag", "gonvoy")
		} else {
			c.Request().Header.Add("x-bench-tag", "gonvoy-default")
		}

		c.SetRequestHeader("x-request-touched", "true")
		c.SetRequestHeader("x-filter-type", "gonvoy")
		c.Request().Header.Del("x-drop-me")

		// Proceed upstream; the code below runs when the response arrives.
		if err := next(c); err != nil {
			return err
		}

		c.SetHeader("x-resp-added", "gonvoy")
		c.SetHeader("x-resp-version", "v1")
		c.SetHeader("x-gateway", "envoy-gonvoy")
		return nil
	})
}

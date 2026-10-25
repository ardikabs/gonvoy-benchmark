// Gonvoy header filter implementing docs/FILTER_SPEC.md (filter-name = "gonvoy").
//
// BenchHandler is a gonvoy.Middleware: request logic runs before next(c),
// response logic runs after it returns. Header-only: request via
// c.Request().Header, response via c.Response().Header (fresh view taken
// after next). No body APIs. Always returns nil (passthrough, never a
// local reply).
package main

import (
	"strings"

	"github.com/ardikabs/gonvoy"
)

func BenchHandler(next gonvoy.Handler) gonvoy.Handler {
	return gonvoy.Handler(func(c gonvoy.Context) error {
		if c.Request().Header.Get("x-api-key") == "test-key-123" {
			c.Request().Header.Set("x-auth-status", "authenticated")
		} else {
			c.Request().Header.Set("x-auth-status", "unauthenticated")
			c.Request().Header.Add("x-auth-retry", "true")
		}

		if strings.Contains(c.Request().Header.Get("user-agent"), "benchmark") {
			c.Request().Header.Set("x-bench-tag", "gonvoy")
		} else {
			c.Request().Header.Add("x-bench-tag", "gonvoy-default")
		}

		c.Request().Header.Set("x-request-touched", "true")
		c.Request().Header.Set("x-filter-type", "gonvoy")
		c.Request().Header.Del("x-drop-me")

		// Proceed upstream; the code below runs when the response arrives.
		if err := next(c); err != nil {
			return err
		}

		c.Response().Header.Add("x-resp-added", "gonvoy")
		c.Response().Header.Set("x-resp-version", "v1")
		c.Response().Header.Set("x-gateway", "envoy-gonvoy")
		c.Response().Header.Del("server")
		c.Response().Header.Del("x-drop-me")
		return nil
	})
}

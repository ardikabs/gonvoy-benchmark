// Registration-only main package for the gonvoy filter (Task 5).
// pkg/envoy links Envoy's C bindings, so it must stay here and never be
// imported by handler code or unit tests.
package main

import (
	"github.com/ardikabs/gonvoy"
	"github.com/ardikabs/gonvoy/pkg/envoy"
)

func init() {
	envoy.Handle("bench-gonvoy", gonvoy.Use(BenchHandler))
}

func main() {}

//! WASM header filter implementing docs/FILTER_SPEC.md (filter-name = "wasm").
//! Header-only: uses get_/set_/add_/remove_http_request/response_header.
//! No body calls. Always returns Action::Continue.

use proxy_wasm::traits::{Context, HttpContext, RootContext};
use proxy_wasm::types::{Action, ContextType, LogLevel};

#[no_mangle]
pub fn _start() {
    proxy_wasm::set_log_level(LogLevel::Trace);
    proxy_wasm::set_root_context(|context_id| -> Box<dyn RootContext> {
        Box::new(BenchRoot {
            context_id: context_id,
        })
    });
    proxy_wasm::set_http_context(|context_id, _| -> Box<dyn HttpContext> {
        Box::new(BenchHttp {
            context_id: context_id,
        })
    });
}

struct BenchRoot {
    // Retained for parity with the proxy-wasm context model; unused.
    #[allow(dead_code)]
    context_id: u32,
}

impl Context for BenchRoot {}

impl RootContext for BenchRoot {
    fn on_configure(&mut self, _plugin_configuration_size: usize) -> bool {
        true
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

struct BenchHttp {
    // Retained for parity with the proxy-wasm context model; unused.
    #[allow(dead_code)]
    context_id: u32,
}

impl Context for BenchHttp {}

impl HttpContext for BenchHttp {
    fn on_http_request_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        if self.get_http_request_header("x-api-key").as_deref() == Some("test-key-123") {
            self.set_http_request_header("x-auth-status", Some("authenticated"));
        } else {
            self.set_http_request_header("x-auth-status", Some("unauthenticated"));
            self.add_http_request_header("x-auth-retry", "true");
        }

        match self.get_http_request_header("user-agent") {
            Some(ua) if ua.contains("benchmark") => {
                self.set_http_request_header("x-bench-tag", Some("wasm"));
            }
            _ => {
                self.add_http_request_header("x-bench-tag", "wasm-default");
            }
        }

        self.set_http_request_header("x-request-touched", Some("true"));
        self.set_http_request_header("x-filter-type", Some("wasm"));
        self.remove_http_request_header("x-drop-me");

        Action::Continue
    }

    fn on_http_response_headers(&mut self, _num_headers: usize, _end_of_stream: bool) -> Action {
        self.add_http_response_header("x-resp-added", "wasm");
        self.set_http_response_header("x-resp-version", Some("v1"));
        self.set_http_response_header("x-gateway", Some("envoy-wasm"));
        self.remove_http_response_header("server");
        self.remove_http_response_header("x-drop-me");

        Action::Continue
    }
}

package main

import (
	"errors"
	"testing"
)

func TestClassifyBridgeErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{"nil", nil, ""},
		{"dns", errors.New("dial tcp: lookup dashscope.aliyuncs.com: no such host"), "network_dns"},
		{"refused", errors.New("dial tcp 1.2.3.4: connect: connection refused"), "network_refused"},
		{"io_timeout", errors.New("read dashscope event: read tcp 1.2.3.4:443: i/o timeout"), "upstream_timeout"},
		{"wait_finish_timeout", errors.New("timeout waiting for session.finished"), "upstream_timeout"},
		{"unauthorized", errors.New("dial failed (401): websocket: bad handshake"), "auth_invalid"},
		{"forbidden", errors.New("dial failed (403): websocket: bad handshake"), "auth_forbidden"},
		{"arrearage", errors.New("dashscope error: Your account is in good standing but has arrearage"), "auth_quota"},
		{"rate_limit", errors.New("dashscope error: 429 rate limit exceeded"), "rate_limit"},
		{"server_500", errors.New("dial failed (500): internal server error"), "upstream_server"},
		{"connection_reset", errors.New("read tcp: connection reset by peer"), "network_broken"},
		{"broken_pipe", errors.New("write tcp: write: broken pipe"), "network_broken"},
		{"eof", errors.New("read dashscope event: EOF"), "network_broken"},
		{"connect_wrap", errors.New("connect dashscope: websocket: bad handshake"), "upstream_connect"},
		{"handshake", errors.New("read handshake event: unexpected close"), "upstream_handshake"},
		{"unknown", errors.New("something we have never seen"), "bridge_internal"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyBridgeErr(tc.err)
			if got != tc.want {
				t.Errorf("classifyBridgeErr(%q) = %q, want %q", tc.err, got, tc.want)
			}
		})
	}
}

func TestClassifyDashEventError(t *testing.T) {
	cases := []struct {
		name string
		msg  string
		want string
	}{
		{
			"commit_empty_audio",
			"Error committing input audio buffer, maybe no invalid audio stream.",
			"asr_empty_audio",
		},
		{"auth_invalid", "Invalid API key provided", "auth_invalid"},
		{"unauthorized", "401 Unauthorized", "auth_invalid"},
		{"arrearage", "account is in arrearage", "auth_quota"},
		{"rate_limit_429", "429 Too Many Requests", "rate_limit"},
		{"rate_limit_keyword", "rate limit exceeded for qwen3-asr-flash-realtime", "rate_limit"},
		{"generic_upstream", "model temporarily unavailable", "asr_upstream_error"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyDashEventError(tc.msg)
			if got != tc.want {
				t.Errorf("classifyDashEventError(%q) = %q, want %q", tc.msg, got, tc.want)
			}
		})
	}
}

func TestIsDashEventErrorAlreadyWritten(t *testing.T) {
	if isDashEventErrorAlreadyWritten(nil) {
		t.Error("nil should not be marked as already-written")
	}
	if isDashEventErrorAlreadyWritten(errors.New("read tcp: timeout")) {
		t.Error("plain transport error should not be marked as already-written")
	}
	marked := errors.New(dashEventErrorPrefix + "some dashscope message")
	if !isDashEventErrorAlreadyWritten(marked) {
		t.Errorf("prefixed error %q should be marked as already-written", marked)
	}
}

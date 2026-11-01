package agentic_design

import "engine"

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import "core:time"

// While agents send requests, the window tells macOS the work is user-initiated and
// latency-critical. A window started by an agent sits behind other windows (or the
// display sleeps), so App Nap throttled it: the frame-pacing sleep stretched to ~130 ms,
// every request waited ~170 ms and a screenshot took seconds (dogfooding D35). The
// activity ends after AGENT_ACTIVITY_LINGER without a request, so an idle window can
// still nap. A window the user works in is in front and never napped anyway.
// Main thread only: no lock, and no Objective-C call from the server thread.

AGENT_ACTIVITY_LINGER :: 10 * time.Second

// NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical. Odin's
// ActivityOptions bit_set takes log2 of these multi-bit masks, so the raw value is passed.
AGENT_ACTIVITY_OPTIONS :: u64(0x00EFFFFF) | u64(0xFF00000000)

agent_activity: struct {
	token: ^NS.Object, // what beginActivity returned (retained), nil when none
	last:  time.Tick,
}

// After the main loop ran requests.
agent_activity_touch :: proc() {
	agent_activity.last = time.tick_now()
	if agent_activity.token != nil do return
	info := NS.ProcessInfo.processInfo()
	token := intrinsics.objc_send(^NS.Object, info, "beginActivityWithOptions:reason:", AGENT_ACTIVITY_OPTIONS, NS.AT("Agent requests"))
	if token != nil do agent_activity.token = intrinsics.objc_send(^NS.Object, token, "retain")
}

// Each frame: ends the activity once agents have been quiet for a while.
agent_activity_tick :: proc() {
	if agent_activity.token == nil || time.tick_since(agent_activity.last) < AGENT_ACTIVITY_LINGER do return
	info := NS.ProcessInfo.processInfo()
	intrinsics.objc_send(nil, info, "endActivity:", agent_activity.token)
	intrinsics.objc_send(nil, agent_activity.token, "release")
	agent_activity.token = nil
}

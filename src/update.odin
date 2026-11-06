#+build !js
package agentic_design

import "base:runtime"
import "engine"

import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import nvg "nanovg"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

// Updates (decision #57, docs/releasing.md). The window checks a manifest on GitHub
// Releases at launch and once a day, and from Settings:
//
//   latest.json      {"version", "url" of the zip, "sha256", "size", "notes", ...}
//   latest.json.sig  Ed25519 signature (base64) of latest.json's bytes
//
// The signature is checked against UPDATE_PUBLIC_KEY before anything in the manifest is
// believed; the zip must then match its size and SHA-256. HTTPS alone is never trusted.
// The new bundle is unpacked and checked (bundle id, version, code signature) while the
// user works. Installing waits for the user's consent and for agents to be idle, swaps the
// bundles atomically (renamex_np RENAME_SWAP on the same volume) and relaunches.
// Test windows (AGENTIC_QUIET) never check or install, except with AGENTIC_UPDATE_TEST=1.

UPDATE_FEED :: #config(UPDATE_FEED, "https://github.com/kirill-dev-pro/agentic-design/releases/latest/download/latest.json")
UPDATE_PUBLIC_KEY :: "uoWalaT1HbHqv6yYLY/Q1TRXp9zvOd+wCSmCd6W7yFI="
UPDATE_INTERVAL :: time.Hour // a check an hour; a found update downloads at once
UPDATE_FIRST_CHECK :: 8 * time.Second // after launch, so starting stays quick
UPDATE_AGENT_QUIET :: 5 * time.Second // no agent request for this long before installing

Update_Phase :: enum i32 {
	Idle,
	Checking,
	Up_To_Date,
	Downloading,
	Ready, // downloaded and verified; waits for the user
	Waiting_For_Agents, // the user said yes; installing once agents pause
	Installing,
	Failed,
}

update: struct {
	phase:      Update_Phase, // written by the worker (atomically), read each frame
	version:    string, // the version on offer
	notes:      string,
	staged:     string, // the verified new .app, in the cache folder
	error:      string,
	running:    bool, // a worker thread is busy
	next_check: time.Time,
	checked_at: time.Time,
	announced:  bool,
}

update_allowed :: proc() -> bool {
	if pf.quiet && os.get_env("AGENTIC_UPDATE_TEST", context.temp_allocator) == "" do return false
	return true
}

// Where the manifest comes from: the release feed, or AGENTIC_UPDATE_URL (a local test
// server or file:// path; the signature check is the same).
update_feed :: proc() -> string {
	if u := os.get_env("AGENTIC_UPDATE_URL", context.temp_allocator); u != "" do return u
	return UPDATE_FEED
}

update_phase :: proc() -> Update_Phase {
	return Update_Phase(sync.atomic_load(cast(^i32)&update.phase))
}

@(private = "file")
set_phase :: proc(p: Update_Phase) {
	sync.atomic_store(cast(^i32)&update.phase, i32(p))
	platform_wake()
}

// Once a frame from the main loop: schedules checks and installs a consented update when
// agents are idle.
update_tick :: proc() {
	if !update_allowed() do return
	now := time.now()
	if update.next_check == {} do update.next_check = time.time_add(now, UPDATE_FIRST_CHECK)
	if settings.auto_update && !update.running && time.diff(update.next_check, now) >= 0 {
		#partial switch update_phase() {
		case .Idle, .Up_To_Date, .Failed: update_check()
		}
	}
	if update_phase() == .Ready && !update.announced {
		update.announced = true
		set_status("Agentic Design %s is downloaded: Restart at the top right installs it", update.version)
	}
	if update_phase() == .Waiting_For_Agents && !agents_busy() do update_install()
}

// Starts a check (and, if newer, the download) on a worker thread.
update_check :: proc() {
	if update.running || !update_allowed() do return
	update.running = true
	update.next_check = time.time_add(time.now(), UPDATE_INTERVAL)
	set_phase(.Checking)
	t := thread.create_and_start(update_worker, app_context(), self_cleanup = true)
	_ = t
}

// The user said yes (Settings, or the socket in a test). Installs now, or once agents
// are idle.
update_request_install :: proc() {
	if update_phase() != .Ready do return
	if agents_busy() {
		set_phase(.Waiting_For_Agents)
		set_status("Updating as soon as the agents pause")
		return
	}
	update_install()
}

// An agent call is in progress or one came in within the last few seconds: an update
// must not cut a session off mid-call.
agents_busy :: proc() -> bool {
	sync.mutex_lock(&req_mutex)
	queued := len(req_queue)
	sync.mutex_unlock(&req_mutex)
	if queued > 0 || shot.req != nil || export_pending do return true
	return agent_activity.last != {} && time.tick_since(agent_activity.last) < UPDATE_AGENT_QUIET
}

// ---------------------------------------------------------------- worker

@(private = "file")
update_worker :: proc() {
	context = app_context()
	defer update.running = false
	version, notes, staged, err := update_fetch()
	if err != "" {
		update.error = err
		set_phase(.Failed)
		return
	}
	if version == "" {
		update.checked_at = time.now()
		set_phase(.Up_To_Date)
		return
	}
	update.version, update.notes, update.staged = version, notes, staged
	update.checked_at = time.now()
	set_phase(.Ready)
}

// Checks the feed; for a newer version downloads, verifies and unpacks it. Returns the
// version ("" when up to date) and the verified .app, or an error.
@(private = "file")
update_fetch :: proc() -> (version, notes, staged: string, err: string) {
	cache := update_cache_dir()
	_ = os.make_directory_all(cache)
	feed := update_feed()
	manifest_path := fmt.aprintf("%s/latest.json", cache)
	if !curl(feed, manifest_path) do return "", "", "", fmt.aprintf("could not reach %s", feed)
	if !curl(strings.concatenate({feed, ".sig"}), strings.concatenate({manifest_path, ".sig"})) do return "", "", "", "the update manifest has no signature"
	data, rerr := os.read_entire_file(manifest_path, context.allocator)
	if rerr != nil do return "", "", "", "could not read the update manifest"
	if !update_signature_ok(data, strings.concatenate({manifest_path, ".sig"})) do return "", "", "", "the update manifest's signature does not match: ignored"

	v, perr := json.parse(data, .JSON, false, context.allocator)
	m, ok := v.(json.Object)
	if perr != nil || !ok do return "", "", "", "the update manifest is not JSON"
	version = string(m["version"].(json.String) or_else "")
	url := string(m["url"].(json.String) or_else "")
	sha := strings.to_lower(string(m["sha256"].(json.String) or_else ""))
	size := int(m["size"].(json.Float) or_else -1)
	notes = string(m["notes"].(json.String) or_else "")
	if version == "" || url == "" || len(sha) != 64 || size <= 0 do return "", "", "", "the update manifest is incomplete"
	if !version_newer(version, VERSION) do return "", "", "", ""
	set_phase(.Downloading)

	dir := fmt.aprintf("%s/%s", cache, version)
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	zip := fmt.aprintf("%s/update.zip", dir)
	if !curl(url, zip) do return "", "", "", fmt.aprintf("could not download %s", url)
	blob, zerr := os.read_entire_file(zip, context.allocator)
	if zerr != nil do return "", "", "", "could not read the download"
	if len(blob) != size do return "", "", "", fmt.aprintf("the download has %d bytes, the manifest says %d: rejected", len(blob), size)
	got := string(hex.encode(hash.hash_bytes(.SHA256, blob)))
	if got != sha do return "", "", "", "the download's SHA-256 does not match the signed manifest: rejected"
	delete(blob)

	unpacked := fmt.aprintf("%s/unpacked", dir)
	if !run({"/usr/bin/ditto", "-x", "-k", zip, unpacked}) do return "", "", "", "could not unpack the update"
	app := fmt.aprintf("%s/%s.app", unpacked, APP_NAME)
	if !os.exists(app) do return "", "", "", "the update has no app bundle"
	plist, perr2 := os.read_entire_file(fmt.tprintf("%s/Contents/Info.plist", app), context.allocator)
	if perr2 != nil || plist_string(string(plist), "CFBundleIdentifier") != BUNDLE_ID do return "", "", "", "the update is not Agentic Design: rejected"
	if plist_string(string(plist), "CFBundleShortVersionString") != version do return "", "", "", "the update's version does not match its manifest: rejected"
	if !run({"/usr/bin/codesign", "--verify", "--deep", "--strict", app}) do return "", "", "", "the update's code signature is broken: rejected"
	return version, notes, app, ""
}

// Ed25519 over the manifest's exact bytes, with the key built into this binary.
update_signature_ok :: proc(data: []byte, sig_path: string) -> bool {
	pub_bytes, perr := base64.decode(UPDATE_PUBLIC_KEY, allocator = context.temp_allocator)
	if perr != nil do return false
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, pub_bytes) do return false
	text, err := os.read_entire_file(sig_path, context.temp_allocator)
	if err != nil do return false
	sig, derr := base64.decode(strings.trim_space(string(text)), allocator = context.temp_allocator)
	if derr != nil || len(sig) != ed25519.SIGNATURE_SIZE do return false
	return ed25519.verify(&pub, data, sig)
}

update_cache_dir :: proc() -> string {
	home, _ := os.user_home_dir(context.temp_allocator)
	return fmt.aprintf("%s/Library/Caches/%s/updates", home, BUNDLE_ID)
}

// <key>K</key><string>V</string> in an XML property list.
plist_string :: proc(plist, key: string) -> string {
	i := strings.index(plist, fmt.tprintf("<key>%s</key>", key))
	if i < 0 do return ""
	rest := plist[i:]
	a := strings.index(rest, "<string>")
	b := strings.index(rest, "</string>")
	if a < 0 || b < a do return ""
	return strings.trim_space(rest[a + len("<string>"):b])
}

@(private = "file")
curl :: proc(url, out: string) -> bool {
	return run({"/usr/bin/curl", "--fail", "--silent", "--show-error", "--location", "--max-time", "600", "--proto", "=https,http,file", "-o", out, url})
}

@(private = "file")
run :: proc(command: []string) -> bool {
	p, err := os.process_start({command = command})
	if err != nil do return false
	st, werr := os.process_wait(p)
	return werr == nil && st.exited && st.exit_code == 0
}

// ---------------------------------------------------------------- install

foreign import libc "system:System.framework"
@(default_calling_convention = "c")
foreign libc {
	renamex_np :: proc(from, to: cstring, flags: u32) -> i32 ---
}
RENAME_SWAP :: 0x2

// Swaps the verified bundle in for the running one and relaunches it. Documents are saved
// by the normal quit path.
@(private = "file")
update_install :: proc() {
	set_phase(.Installing)
	target := bundle_path()
	fail :: proc(msg: string) {
		update.error = strings.clone(msg)
		set_phase(.Failed)
		set_status("Update failed: %s", msg)
	}
	if target == "" {
		fail("this copy runs from a build folder, not an installed app")
		return
	}
	if bundle_translocated() {
		fail("move Agentic Design to the Applications folder first (macOS runs it from a temporary copy)")
		return
	}
	parent := os.dir(target)
	if posix.access(strings.clone_to_cstring(parent, context.temp_allocator), {.W_OK}) != .OK {
		fail(fmt.tprintf("no permission to write %s", parent))
		return
	}
	// the new bundle beside the old one: renaming only works within a volume
	incoming := fmt.tprintf("%s/.%s %s.app", parent, APP_NAME, update.version)
	_ = os.remove_all(incoming)
	if !run({"/usr/bin/ditto", update.staged, incoming}) {
		fail("could not copy the update next to the app")
		return
	}
	if renamex_np(strings.clone_to_cstring(incoming, context.temp_allocator), strings.clone_to_cstring(target, context.temp_allocator), RENAME_SWAP) != 0 {
		// not APFS: two renames, with the old bundle back in place if the second fails
		backup := fmt.tprintf("%s/.%s %s.app", parent, APP_NAME, VERSION)
		_ = os.remove_all(backup)
		if os.rename(target, backup) != nil {
			fail("could not move the old app aside")
			return
		}
		if os.rename(incoming, target) != nil {
			_ = os.rename(backup, target)
			fail("could not put the new app in place")
			return
		}
		incoming = backup
	}
	_ = os.remove_all(incoming) // the old bundle; this process keeps its binary mapped
	_ = os.remove_all(os.dir(os.dir(update.staged))) // the downloaded copy
	app_log("update: %s -> %s, relaunching", VERSION, update.version)
	// relaunch once this process has saved and exited, with the document it had open. The
	// paths go in as arguments, never into the script text. A test window starts the binary
	// itself, so it keeps its quiet mode and port (`open` does not pass the environment on).
	script := `(while kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" | cut -c1)" != Z ]; do sleep 0.2; done; if [ -n "$4" ]; then exec "$2/Contents/MacOS/agentic-design" "$3"; else exec /usr/bin/open -n "$2" --args "$3"; fi) >/dev/null 2>&1 &`
	test := "1" if os.get_env("AGENTIC_UPDATE_TEST", context.temp_allocator) != "" else ""
	if p, err := os.process_start({command = {"/bin/sh", "-c", script, "sh", fmt.tprintf("%d", posix.getpid()), target, app.file_path, test}}); err == nil {
		_, _ = os.process_wait(p)
	}
	platform_request_close()
}

// ---------------------------------------------------------------- the tab bar's button

// "Restart to update" at the right of the tab bar once an update is downloaded and checked
// (`right`: where it ends). Returns the width it takes.
draw_update_button :: proc(vg: ^nvg.Context, right: f32) -> f32 {
	phase := update_phase()
	text: string
	#partial switch phase {
	case .Ready: text = "Restart to update"
	case .Waiting_For_Agents: text = "Restarting after the agent"
	case .Installing: text = "Restarting…"
	case: return 0
	}
	w := text_width(vg, text, 12.5) + 40
	r := Rect{right - w, (TAB_H - 28) / 2, w, 28}
	ready := phase == .Ready
	fill_rect(vg, r, ACCENT if ready else {1, 1, 1, 0.08}, 8)
	if ready && hovered(r) do fill_rect(vg, r, {1, 1, 1, 0.12}, 8)
	draw_lucide(vg, "refresh-cw", r.x + 16, r.y + 14, 13, {1, 1, 1, 1} if ready else TEXT_DIM, 1.8)
	label(vg, r.x + 29, r.y + 14, text, {1, 1, 1, 1} if ready else TEXT_DIM, 12.5)
	if hovered(r) do tooltip_request(fmt.tprintf("Agentic Design %s is downloaded. Restart to install it; your files are saved and reopened.", update.version), r)
	if ready && clicked(r) do update_request_install()
	return w + 8
}

// ---------------------------------------------------------------- socket (tests)

// {"action": "status" | "check" | "install"}. Install stands in for the user's consent, so
// it only works in a test window (AGENTIC_UPDATE_TEST=1).
api_update :: proc(b: ^strings.Builder, params: json.Object) -> string {
	action := string(params["action"].(json.String) or_else "status")
	switch action {
	case "check":
		if !update_allowed() do return "updates are off in test windows (set AGENTIC_UPDATE_TEST=1)"
		update_check()
	case "install":
		if os.get_env("AGENTIC_UPDATE_TEST", context.temp_allocator) == "" do return "install is the user's decision (Settings); the socket can only install in a test window"
		if update_phase() != .Ready do return "no verified update is ready"
		update_request_install()
	case "status":
	case:
		return "action: status, check or install"
	}
	phases := [Update_Phase]string{.Idle = "idle", .Checking = "checking", .Up_To_Date = "up to date", .Downloading = "downloading", .Ready = "ready", .Waiting_For_Agents = "waiting for agents", .Installing = "installing", .Failed = "failed"}
	fmt.sbprintf(b, `{{"running":"%s","phase":"%s","available":`, VERSION, phases[update_phase()])
	engine.json_write_string(b, update.version)
	strings.write_string(b, `,"error":`)
	engine.json_write_string(b, update.error)
	strings.write_string(b, `,"feed":`)
	engine.json_write_string(b, update_feed())
	fmt.sbprintf(b, `,"auto":%v}}`, settings.auto_update)
	return ""
}

_ :: runtime

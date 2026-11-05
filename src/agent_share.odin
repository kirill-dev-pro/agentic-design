#+build !js
package agentic_design

import "engine"

import "core:encoding/json"
import "core:fmt"
import "core:strings"

// Agents put files in the cloud (decision 87): the MCP tools `share` and `unshare`. A file
// goes to the account of whoever is signed in on this Mac and is private unless the call
// asks for a link; making a link (anyone with it, or public) needs the user's yes in the
// window, since a document's text could ask an agent to publish it.

Agent_Share_Stage :: enum {
	None,
	Confirm, // the window asks the user
	Running, // the upload runs (cloud.odin's worker)
}

agent_share: struct {
	stage:    Agent_Share_Stage,
	req:      ^Request,
	path:     string,
	name:     string,
	access:   Share_Access,
	download: bool,
	embed:    bool,
	revoke:   bool,
	who:      string, // the agent, for the question
	method:   string, // "invite", "people", "remove_access" answer from cloud.job_result
	email:    string,
	role:     string,
}

SHARE_ACCESS_NAMES := [Share_Access]string {
	.Private = "private",
	.Link    = "link",
	.Public  = "public",
}

@(private = "file")
share_reset :: proc() {
	delete(agent_share.path)
	delete(agent_share.name)
	delete(agent_share.who)
	delete(agent_share.method)
	delete(agent_share.email)
	delete(agent_share.role)
	agent_share = {}
}

@(private = "file")
share_answer :: proc(ok: bool, text: string) {
	b := strings.builder_make(context.temp_allocator)
	if ok {
		fmt.sbprintf(&b, `{{"ok":true,"result":%s,"file":`, text)
		engine.json_write_string(&b, agent_share.path)
		strings.write_string(&b, "}")
	} else {
		strings.write_string(&b, api_error(text))
	}
	finish_request(agent_share.req, strings.clone(strings.to_string(b), big_allocator()))
	share_reset()
}

// The `share` and `unshare` requests, for the document in `app` (shown or visited).
// Deferred: answered when the upload ends, or when the user says no.
api_share :: proc(req: ^Request, params: json.Object, agent: json.Object, revoke: bool) -> (string, bool) {
	if app.file_path == "" do return api_error("no document: open one or pass \"document\""), false
	if agent_share.stage != .None || cloud.running do return api_error("Agentic Design is already uploading a file; try again in a moment."), false
	if !cloud_signed_in() {
		set_status("An agent wants to put a file in the cloud: sign in under Settings → Account")
		return api_error("Nobody is signed in to the Agentic Design cloud on this Mac, so nothing was uploaded. Ask the user to sign in: Settings → Account → Sign in with browser (the app never asks for a password). Then call this again."), false
	}
	access := Share_Access.Private
	switch string(params["access"].(json.String) or_else "private") {
	case "private": access = .Private
	case "link": access = .Link
	case "public": access = .Public
	case: return api_error("access: private (only you, in your cloud files), link (anyone with the link) or public"), false
	}
	if app.dirty do save_document(app.file_path)
	agent_share.req = req
	agent_share.path = strings.clone(app.file_path)
	agent_share.name = strings.clone(engine.file_title(app.file_path))
	agent_share.access = access
	agent_share.download = params["allow_download"].(json.Boolean) or_else false
	agent_share.embed = params["allow_embed"].(json.Boolean) or_else false
	agent_share.revoke = revoke
	who := string(agent["title"].(json.String) or_else "") if agent != nil else ""
	if who == "" do who = string(agent["client"].(json.String) or_else "") if agent != nil else ""
	if who == "" do who = "An agent"
	agent_share.who = strings.clone(who)
	if revoke {
		s, has := cloud_share_of(app.file_path)
		if !has || s.link_id == "" {
			share_answer(true, `{"access":"private","url":""}`)
			return "", true
		}
		cloud_share_revoke(app.file_path)
		agent_share.stage = .Running
		return "", true
	}
	if access == .Private {
		agent_share.stage = .Running
		if !cloud_share_as(agent_share.path, agent_share.name, access, false, false) do share_answer(false, "the upload could not start")
		return "", true
	}
	// a link: the user decides
	what := "anyone with the link" if access == .Link else "everyone (a public link)"
	dialog_open("agent.share", fmt.tprintf("Share “%s”?", agent_share.name), fmt.tprintf("%s wants to upload this file to your Agentic Design cloud and make it viewable by %s.%s", agent_share.who, what, "\nDownloads are allowed." if agent_share.download else ""), {"Don't allow", "Share"})
	agent_share.stage = .Confirm
	return "", true
}

// invite, people and remove_access (contract §10): who may open the document in the cloud.
api_people :: proc(req: ^Request, params: json.Object, agent: json.Object, method: string) -> (string, bool) {
	if app.file_path == "" do return api_error("no document: open one or pass \"document\""), false
	if agent_share.stage != .None || cloud.running do return api_error("Agentic Design is already uploading a file; try again in a moment."), false
	if !cloud_signed_in() {
		set_status("An agent wants to share a file: sign in under Settings → Account")
		return api_error("Nobody is signed in to the Agentic Design cloud on this Mac, so nothing changed. Ask the user to sign in: Settings → Account → Sign in with browser. Then call this again."), false
	}
	email := strings.to_lower(strings.trim_space(string(params["email"].(json.String) or_else "")), context.temp_allocator)
	role := string(params["role"].(json.String) or_else "viewer")
	if method != "people" && (email == "" || !strings.contains(email, "@")) do return api_error("pass \"email\": the person's email address"), false
	if role != "viewer" && role != "editor" do return api_error("role: viewer (sees the file) or editor (can change it)"), false
	if app.dirty do save_document(app.file_path)
	agent_share.req = req
	agent_share.path = strings.clone(app.file_path)
	agent_share.name = strings.clone(engine.file_title(app.file_path))
	agent_share.method = strings.clone(method)
	agent_share.email = strings.clone(email)
	agent_share.role = strings.clone(role)
	who := string(agent["title"].(json.String) or_else "") if agent != nil else ""
	if who == "" do who = string(agent["client"].(json.String) or_else "") if agent != nil else ""
	if who == "" do who = "An agent"
	agent_share.who = strings.clone(who)
	if method == "invite" {
		dialog_open("agent.share", fmt.tprintf("Invite %s?", email), fmt.tprintf("%s wants to give %s access to “%s” as %s. The file goes to your Agentic Design cloud if it is not there yet; they open it with an invitation link, signed in with that email.", agent_share.who, email, agent_share.name, "an editor (can change it)" if role == "editor" else "a viewer"), {"Don't allow", "Invite"})
		agent_share.stage = .Confirm
		return "", true
	}
	agent_share.stage = .Running
	kind := cloud_people_job_kind(method)
	if !cloud_people_job(agent_share.path, agent_share.name, kind, email, role) do share_answer(false, "the request could not start")
	return "", true
}

@(private = "file")
cloud_people_job_kind :: proc(method: string) -> (k: People_Job) {
	switch method {
	case "invite": k = .Invite
	case "people": k = .People
	case: k = .Remove
	}
	return
}

// Every frame: the user's answer, then the end of the upload.
agent_share_tick :: proc() {
	switch agent_share.stage {
	case .None:
	case .Confirm:
		if pick, ok := dialog_take("agent.share"); ok {
			if pick != 1 {
				share_answer(false, "The user did not allow sharing this file. Nothing was uploaded.")
				return
			}
			agent_share.stage = .Running
			started := false
			if agent_share.method != "" do started = cloud_people_job(agent_share.path, agent_share.name, cloud_people_job_kind(agent_share.method), agent_share.email, agent_share.role)
			else do started = cloud_share_as(agent_share.path, agent_share.name, agent_share.access, agent_share.download, agent_share.embed)
			if !started do share_answer(false, "the upload could not start")
		}
	case .Running:
		if cloud.running do return
		if cloud_phase() == .Failed {
			share_answer(false, fmt.tprintf("The upload failed: %s", cloud_text(&cloud.error)))
			return
		}
		if agent_share.method != "" {
			res := strings.clone(cloud_text(&cloud.job_result), context.temp_allocator)
			if agent_share.method == "invite" do set_status("Invitation for %s ready", agent_share.email)
			share_answer(true, res if res != "" else "{}")
			return
		}
		s, _ := cloud_share_of(agent_share.path)
		access := SHARE_ACCESS_NAMES[.Private if agent_share.revoke || s.url == "" else agent_share.access]
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"access":"%s","url":`, access)
		engine.json_write_string(&b, s.url)
		strings.write_string(&b, `,"files":`)
		engine.json_write_string(&b, fmt.tprintf("%s/files", cloud_url()))
		fmt.sbprintf(&b, `,"allowDownload":%v,"allowEmbed":%v,"missing":[`, s.allow_download, s.allow_embed)
		for m, i in s.missing do fmt.sbprintf(&b, `%s%s`, "," if i > 0 else "", json_quote(m))
		strings.write_string(&b, "]}")
		if access == "private" do set_status("“%s” is in your cloud files (only you can see it)", agent_share.name)
		else do set_status("“%s” is shared: %s", agent_share.name, s.url)
		share_answer(true, strings.to_string(b))
	}
}

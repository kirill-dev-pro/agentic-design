"use strict";
// The site's account pages (/signin, /signup, /account, /files): plain fetches to the API
// on this origin (docs: the M1 API contract, shared by the cloud agent). Auth is Better
// Auth under /api/auth/*, with a cookie session; errors come back as { message, code }
// (auth) or { error, code, details: { reason } } (the rest of /api).

const App = (() => {
	const $ = (sel, root = document) => root.querySelector(sel);

	class ApiError extends Error {
		constructor(status, body) {
			super((body && (body.message || body.error)) || `Request failed (${status})`);
			this.status = status;
			this.code = (body && body.code) || "";
			this.reason = (body && body.details && body.details.reason) || "";
			this.details = (body && body.details) || {};
		}
	}

	async function api(method, path, body) {
		const res = await fetch(path, {
			method,
			credentials: "same-origin",
			headers: body !== undefined ? { "content-type": "application/json" } : {},
			body: body !== undefined ? JSON.stringify(body) : undefined,
		});
		const text = await res.text();
		let data = null;
		try { data = text ? JSON.parse(text) : null; } catch (e) { data = { message: text }; }
		if (!res.ok) throw new ApiError(res.status, data);
		return data;
	}

	// The signed-in user and workspace, or null (GET /api/me answers 401 when signed out).
	let mePromise = null;
	function me() {
		mePromise ??= api("GET", "/api/me").catch((e) => {
			if (e.status === 401) return null;
			throw e;
		});
		return mePromise;
	}

	// ?next= keeps where to go after signing in: a path on this site only.
	function nextPath(fallback = "/files") {
		const n = new URLSearchParams(location.search).get("next") || "";
		return n.startsWith("/") && !n.startsWith("//") && !n.startsWith("/\\") ? n : fallback;
	}

	function requireSignIn() {
		location.replace("/signin?next=" + encodeURIComponent(location.pathname + location.search));
	}

	const messages = {
		INVALID_EMAIL_OR_PASSWORD: "That email and password do not match an account.",
		USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL: "There is already an account with this email. Sign in instead.",
		USER_ALREADY_EXISTS: "There is already an account with this email. Sign in instead.",
		PASSWORD_TOO_SHORT: "The password needs at least 10 characters.",
		PASSWORD_TOO_LONG: "The password is too long.",
		INVALID_EMAIL: "That does not look like an email address.",
		INVALID_PASSWORD: "The current password is not right.",
		TOO_MANY_REQUESTS: "Too many attempts. Wait a minute and try again.",
	};
	const say = (e) => messages[e.code] || messages[e.reason] || (e.status === 429 ? messages.TOO_MANY_REQUESTS : e.message);

	function formError(form, text) {
		const el = $(".form-error", form);
		el.textContent = text || "";
		el.hidden = !text;
		const ok = $(".form-ok", form);
		if (ok) ok.hidden = true;
	}

	function busy(form, on) {
		for (const b of form.querySelectorAll("button")) b.disabled = on;
	}

	const bytes = (n) => n === 0 ? "0 MB" : n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : n < 1024 ** 3 ? `${(n / 1048576).toFixed(1)} MB` : `${(n / 1024 ** 3).toFixed(2)} GB`;

	// The header: Account and My files when signed in, Sign in otherwise.
	async function header() {
		const user = await me().catch(() => null);
		for (const el of document.querySelectorAll("[data-signed-in]")) el.hidden = !user;
		for (const el of document.querySelectorAll("[data-signed-out]")) el.hidden = !!user;
		if (user) $("#nav-account").textContent = user.user.name || "Account";
		return user;
	}

	// ---------------------------------------------------------------- sign in and up

	async function providers() {
		const box = $(".providers");
		if (!box) return;
		let list = [];
		try { list = (await api("GET", "/api/auth/managed/providers")).providers || []; } catch (e) {}
		if (!list.length) return;
		$(".provider-list", box).replaceChildren(...list.map((p) => {
			const b = Object.assign(document.createElement("button"), { type: "button", className: "btn secondary provider", textContent: `Continue with ${p.label || p.id}` });
			b.addEventListener("click", async () => {
				b.disabled = true;
				try {
					const r = await api("POST", "/api/auth/managed/sign-in", { provider: p.id, callbackURL: nextPath() });
					// where to go if the provider's round trip ends on the home page instead (main.js)
					try { sessionStorage.setItem("ad-next", JSON.stringify({ to: nextPath(), t: Date.now() })); } catch (e) {}
					if (r && r.url) location.assign(r.url);
				} catch (e) {
					b.disabled = false;
					formError($("form"), say(e));
				}
			});
			return b;
		}));
		box.hidden = false;
	}

	function keepNext() {
		const n = new URLSearchParams(location.search).get("next");
		if (n) for (const a of document.querySelectorAll("[data-keep-next]")) a.search = "?next=" + encodeURIComponent(n);
	}

	async function signin() {
		if (await me()) return location.replace(nextPath());
		keepNext();
		providers();
		const form = $("#signin-form");
		form.addEventListener("submit", async (ev) => {
			ev.preventDefault();
			formError(form, "");
			const f = new FormData(form);
			if (!f.get("email") || !f.get("password")) return formError(form, "Enter your email and password.");
			busy(form, true);
			try {
				await api("POST", "/api/auth/sign-in/email", { email: f.get("email").trim(), password: f.get("password") });
				location.assign(nextPath());
			} catch (e) {
				formError(form, say(e));
				busy(form, false);
			}
		});
	}

	async function signup() {
		if (await me()) return location.replace(nextPath());
		keepNext();
		providers();
		const form = $("#signup-form");
		form.addEventListener("submit", async (ev) => {
			ev.preventDefault();
			formError(form, "");
			const f = new FormData(form);
			const name = (f.get("name") || "").trim(), email = (f.get("email") || "").trim(), password = f.get("password") || "";
			if (!name || !email) return formError(form, "Enter your name and email.");
			if (password.length < 10) return formError(form, messages.PASSWORD_TOO_SHORT);
			busy(form, true);
			try {
				await api("POST", "/api/auth/sign-up/email", { name, email, password });
				location.assign(nextPath());
			} catch (e) {
				formError(form, say(e));
				busy(form, false);
			}
		});
	}

	// ---------------------------------------------------------------- account

	async function account() {
		const m = await me();
		if (!m) return requireSignIn();
		const profile = $("#profile-form");
		profile.name.value = m.user.name || "";
		profile.email.value = m.user.email;
		$("#email-state").textContent = m.user.emailVerified ? "Verified." : "Not verified yet: links can be shared, but not made public.";
		profile.addEventListener("submit", async (ev) => {
			ev.preventDefault();
			formError(profile, "");
			const name = profile.name.value.trim();
			if (!name) return formError(profile, "Enter a name.");
			busy(profile, true);
			try {
				await api("POST", "/api/auth/update-user", { name });
				$(".form-ok", profile).hidden = false;
				$("#nav-account").textContent = name;
			} catch (e) { formError(profile, say(e)); }
			busy(profile, false);
		});

		const pw = $("#password-form");
		pw.addEventListener("submit", async (ev) => {
			ev.preventDefault();
			formError(pw, "");
			if (pw.newPassword.value.length < 10) return formError(pw, messages.PASSWORD_TOO_SHORT);
			busy(pw, true);
			try {
				await api("POST", "/api/auth/change-password", {
					currentPassword: pw.currentPassword.value,
					newPassword: pw.newPassword.value,
					revokeOtherSessions: pw.revokeOtherSessions.checked,
				});
				pw.reset();
				$(".form-ok", pw).hidden = false;
			} catch (e) { formError(pw, say(e)); }
			busy(pw, false);
		});

		const ent = m.workspace.entitlements, use = m.workspace.usage;
		$("#plan-name").textContent = m.workspace.plan === "free" ? "Free: share files by link. Cloud documents come later." : `Plan: ${m.workspace.plan}`;
		$("#usage-storage").textContent = `${bytes(use.storageBytes)} of ${bytes(ent.storageBytes)}`;
		$("#usage-files").textContent = `${use.sharedFiles} of ${ent.sharedFiles}`;
		$("#meter-storage").style.width = Math.min(100, (100 * use.storageBytes) / ent.storageBytes) + "%";
		$("#meter-files").style.width = Math.min(100, (100 * use.sharedFiles) / ent.sharedFiles) + "%";

		const del = $("#delete-form");
		del.addEventListener("submit", async (ev) => {
			ev.preventDefault();
			formError(del, "");
			if (del.confirmEmail.value.trim().toLowerCase() !== m.user.email.toLowerCase()) return formError(del, "Type the email of this account to confirm.");
			if (!confirm("Delete your account, your shared files and all their links for good?")) return;
			busy(del, true);
			try {
				await api("POST", "/api/account/delete", del.password.value ? { password: del.password.value } : {});
				location.assign("/?deleted");
			} catch (e) {
				busy(del, false);
				if (e.reason === "PASSWORD") formError(del, "The password is not right.");
				else if (e.reason === "SESSION_NOT_FRESH") formError(del, "For your safety, sign out and sign in again, then delete the account within a day.");
				else formError(del, say(e));
			}
		});

		$("#sign-out").addEventListener("click", async (ev) => {
			ev.target.disabled = true;
			try { await api("POST", "/api/auth/sign-out", {}); } catch (e) {}
			location.assign("/");
		});
	}

	// ---------------------------------------------------------------- my files

	const el = (tag, props = {}, ...kids) => {
		const n = Object.assign(document.createElement(tag), props);
		n.append(...kids.filter((k) => k !== null && k !== undefined));
		return n;
	};
	const when = (iso) => {
		const d = new Date(iso), days = (Date.now() - d) / 864e5;
		if (days < 1 / 24) return "just now";
		if (days < 1) return `${Math.round(days * 24)} h ago`;
		if (days < 7) return `${Math.round(days)} d ago`;
		return d.toLocaleDateString(undefined, { day: "numeric", month: "short", year: d.getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
	};
	const linkMessages = {
		EMAIL_NOT_VERIFIED: "A public link needs a verified email. Links shared by URL work without it.",
		QUOTA_EXCEEDED: "Your account allows no more links right now.",
	};
	// The viewer URL of the owner's own copy (cookie, same origin; the contract, §3)
	const ownerUrl = (f) => "/view/?file=" + encodeURIComponent(f.docUrl || `/api/docs/${f.id}/v/${f.versionId}/doc.pen`);
	const tokenOf = (url) => (url || "").split("/s/")[1] || "";

	async function files() {
		const m = await me();
		if (!m) return requireSignIn();
		const use = m.workspace.usage, ent = m.workspace.entitlements;
		$("#files-usage").textContent = `${use.sharedFiles} of ${ent.sharedFiles} files · ${bytes(use.storageBytes)} of ${bytes(ent.storageBytes)}`;
		const list = $("#files-list");
		const showError = (text) => { $("#files-error").textContent = text || ""; $("#files-error").hidden = !text; };

		async function load() {
			let data;
			try { data = await api("GET", "/api/docs"); }
			catch (e) { return showError(say(e)); }
			$("#files-empty").hidden = data.files.length > 0;
			list.replaceChildren(...data.files.map(card));
		}

		function card(f) {
			const thumb = el("a", { className: "thumb", href: ownerUrl(f), title: "Open" },
				f.thumbUrl ? el("img", { src: f.thumbUrl, alt: "", loading: "lazy" }) : null);
			const nLinks = f.links.length;
			const btn = (label, onClick, cls = "btn secondary") => { const b = el("button", { type: "button", className: cls, textContent: label }); b.addEventListener("click", onClick); return b; };
			const copy = btn(nLinks ? "Copy link" : "Make a link", async () => {
				try {
					const link = f.links[0] || (await api("POST", `/api/docs/${f.id}/links`, {}));
					await navigator.clipboard.writeText(link.url);
					copy.textContent = "Copied";
					if (!nLinks) load();
				} catch (e) { showError(say(e)); }
			}, "btn primary");
			return el("li", { className: "file" },
				thumb,
				el("div", { className: "meta" },
					el("span", { className: "name", textContent: f.name, title: f.name }),
					el("span", { className: "when", textContent: `${when(f.updatedAt)} · ${bytes(f.sizeBytes)} · ${nLinks} ${nLinks === 1 ? "link" : "links"}` })),
				el("div", { className: "actions" },
					copy,
					btn("Links", () => links(f, load)),
					el("a", { className: "btn secondary", href: `/view/?update=${encodeURIComponent(f.id)}&name=${encodeURIComponent(f.name)}`, textContent: "New version", title: "Open the new version in the viewer and press Share" }),
					btn("Rename", async () => {
						const name = prompt("Name", f.name);
						if (!name || name.trim() === f.name) return;
						try { await api("PATCH", `/api/docs/${f.id}`, { name: name.trim() }); load(); } catch (e) { showError(say(e)); }
					}),
					btn("Delete", async () => {
						if (!confirm(`Delete “${f.name}”? Its links stop working at once.`)) return;
						try { await api("DELETE", `/api/docs/${f.id}`); load(); } catch (e) { showError(say(e)); }
					}, "btn danger")));
		}

		await load();
	}

	// The links of one file: copy, settings, expiry, revoke, a new one.
	function links(f, reload) {
		const dlg = $("#links-dialog");
		$("#links-title").textContent = f.name;
		const err = (text) => { $("#links-error").textContent = text || ""; $("#links-error").hidden = !text; };
		err("");
		const render = () => {
			$("#links-list").replaceChildren(...(f.links.length ? f.links.map(row) : [el("li", { className: "sub", textContent: "No links. Make one to share the file." })]));
		};
		const patch = async (l, change) => {
			err("");
			try { Object.assign(l, await api("PATCH", `/api/links/${l.id}`, change)); }
			catch (e) { err(linkMessages[e.reason] || say(e)); }
			render();
		};
		function row(l) {
			const url = el("input", { type: "text", value: l.url || "", readOnly: true });
			const copyBtn = el("button", { type: "button", className: "btn primary small", textContent: "Copy" });
			copyBtn.addEventListener("click", async () => { try { await navigator.clipboard.writeText(l.url); copyBtn.textContent = "Copied"; } catch (e) { url.select(); } });
			const check = (label, key) => {
				const box = el("input", { type: "checkbox", checked: l[key] });
				box.addEventListener("change", () => patch(l, { [key]: box.checked }));
				return el("label", {}, box, label);
			};
			const vis = el("select", {}, el("option", { value: "link", textContent: "Anyone with the link" }), el("option", { value: "public", textContent: "Public (search engines too)" }));
			vis.value = l.visibility;
			vis.addEventListener("change", () => patch(l, { visibility: vis.value }));
			const exp = el("input", { type: "date", value: l.expiresAt ? l.expiresAt.slice(0, 10) : "" });
			exp.addEventListener("change", () => patch(l, { expiresAt: exp.value ? new Date(exp.value + "T23:59:59").toISOString() : null }));
			const revoke = el("button", { type: "button", className: "btn danger small", textContent: "Revoke" });
			revoke.addEventListener("click", async () => {
				if (!confirm("Revoke this link? Anyone who has it can no longer open the file.")) return;
				try { await api("DELETE", `/api/links/${l.id}`); f.links = f.links.filter((x) => x !== l); render(); reload(); } catch (e) { err(say(e)); }
			});
			const embed = l.allowEmbed && l.url
				? el("input", { type: "text", readOnly: true, className: "embed", value: `<iframe src="${location.origin}/embed/${tokenOf(l.url)}" width="800" height="450" style="border:0" allowfullscreen loading="lazy"></iframe>`, title: "Embed code" })
				: null;
			return el("li", { className: "link" },
				el("div", { className: "url" }, url, copyBtn),
				el("div", { className: "opts" }, vis, check("Allow download", "allowDownload"), check("Allow embedding", "allowEmbed"), el("label", {}, "Expires", exp)),
				embed,
				el("div", { className: "foot" }, el("span", { textContent: `${l.viewCount} ${l.viewCount === 1 ? "view" : "views"} · made ${when(l.createdAt)}` }), revoke));
		}
		$("#link-new").onclick = async () => {
			err("");
			try { f.links.unshift(await api("POST", `/api/docs/${f.id}/links`, {})); render(); reload(); } catch (e) { err(linkMessages[e.reason] || say(e)); }
		};
		render();
		dlg.showModal();
	}

	const pages = { signin, signup, account, files };

	document.addEventListener("DOMContentLoaded", async () => {
		const page = document.body.dataset.page;
		header();
		if (pages[page]) {
			try { await pages[page](); }
			catch (e) { console.error(e); }
		}
	});

	return { api, me, nextPath, requireSignIn, formError, busy, bytes, say, ApiError, $, pages };
})();

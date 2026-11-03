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

		$("#sign-out").addEventListener("click", async (ev) => {
			ev.target.disabled = true;
			try { await api("POST", "/api/auth/sign-out", {}); } catch (e) {}
			location.assign("/");
		});
	}

	const pages = { signin, signup, account };

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

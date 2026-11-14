/* Hosting-only launcher: the stable Flutter bundle is never rewritten. */
(() => {
	"use strict";
	const choiceKey = "betterkeep.web.channel.v1";
	let selected = false;
	let promoted = false;
	const sequenceKey = "betterkeep.web.release-sequence.v1";
	let sequence = 0;
	try {
		selected = localStorage.getItem(choiceKey) === "beta";
		sequence = Number(localStorage.getItem(sequenceKey)) || 0;
	} catch (_) {}

	// Keep launcher styles scoped: the stable app uses the same document.
	const style = document.createElement("style");
	style.textContent = `
		#beta-prompt {
			box-sizing: border-box; width: min(440px, calc(100% - 32px));
			max-height: calc(100% - 32px); overflow: auto; margin: auto;
			padding: 28px; border: 1px solid #494155; border-radius: 28px;
			background: #25212d; color: #eee6f4; color-scheme: dark;
			font: 400 15px/1.55 Roboto, system-ui, sans-serif;
			box-shadow: 0 24px 80px #0006;
		}
		#beta-prompt::backdrop { background: #121016b8; backdrop-filter: blur(8px); }
		#beta-prompt .beta-label, #beta-channel-tag {
			display: inline-flex; align-items: center; padding: 3px 10px;
			border-radius: 999px; background: #44335d; color: #ddc7ff;
			font: 500 12px/1.5 Roboto, system-ui, sans-serif; letter-spacing: .3px;
		}
		#beta-prompt h2 { margin: 18px 0 10px; font-size: 24px; line-height: 1.3; font-weight: 500; }
		#beta-prompt p { margin: 0; color: #cbc2d4; }
		#beta-prompt .beta-note { margin-top: 18px; padding: 14px 16px; border-radius: 16px; background: #302a3b; font-size: 13px; }
		#beta-prompt .beta-actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 26px; }
		#beta-prompt button {
			min-height: 46px; padding: 11px 22px; border-radius: 999px;
			border: 1px solid transparent; background: #d0bcff; color: #381e72;
			font: 500 14px/1.4 Roboto, system-ui, sans-serif; cursor: pointer;
		}
		#beta-prompt button + button { background: transparent; color: #d0bcff; }
		#beta-prompt button.beta-warning { color: #ffb4ab; border-color: #db8b83; }
		#beta-prompt button.beta-warning:hover { background: #493034; }
		#beta-prompt button:hover { filter: brightness(1.1); }
		#beta-prompt button:focus-visible { outline: 2px solid #eee6f4; outline-offset: 3px; }
		#beta-prompt .beta-progress { display: flex; align-items: center; gap: 12px; margin-top: 24px; color: #d0bcff; }
		#beta-prompt .beta-progress::before {
			content: ""; width: 16px; height: 16px; flex-shrink: 0;
			border: 2px solid #67517e; border-top-color: #d0bcff;
			border-radius: 50%; animation: beta-spin 1s linear infinite;
		}
		#beta-channel-tag {
			position: fixed; top: 50%; right: env(safe-area-inset-right, 0px);
			transform: translateY(-50%); z-index: 10000;
			writing-mode: vertical-rl; justify-content: center;
			padding: 8px 4px; min-width: 24px; min-height: 44px; border-radius: 10px 0 0 10px;
			cursor: pointer; border: 1px solid #67517e;
		}
		@keyframes beta-spin { to { transform: rotate(360deg); } }
		@media (prefers-reduced-motion: reduce) { #beta-prompt .beta-progress::before { animation: none; } }
		@media (max-width: 360px) { #beta-prompt { padding: 24px; } }
	`;
	document.head.append(style);

	function show(title, message, actions = [], note = "", cancelLabel) {
		document.getElementById("beta-prompt")?.remove();
		const dialog = document.createElement("dialog");
		dialog.id = "beta-prompt";
		dialog.setAttribute("aria-labelledby", "beta-prompt-title");
		dialog.setAttribute(
			"aria-describedby",
			note
				? "beta-prompt-description beta-prompt-note"
				: "beta-prompt-description",
		);
		const label = document.createElement("span");
		label.className = "beta-label";
		label.textContent = "Beta";
		const heading = document.createElement("h2");
		heading.id = "beta-prompt-title";
		heading.textContent = title;
		const text = document.createElement("p");
		text.id = "beta-prompt-description";
		text.textContent = message;
		if (!promoted) dialog.append(label);
		dialog.append(heading, text);
		if (note) {
			const detail = document.createElement("p");
			detail.id = "beta-prompt-note";
			detail.className = "beta-note";
			detail.textContent = note;
			dialog.append(detail);
		}
		const buttons = document.createElement("div");
		buttons.className = "beta-actions";
		for (const [label, action, className] of actions) {
			const button = document.createElement("button");
			button.type = "button";
			button.textContent = label;
			if (className) button.className = className;
			button.onclick = () => {
				dialog.close();
				dialog.remove();
				action();
			};
			buttons.append(button);
		}
		if (actions.length) dialog.append(buttons);
		else {
			const progress = document.createElement("div");
			progress.className = "beta-progress";
			progress.setAttribute("role", "status");
			progress.textContent = promoted ? "Loading app…" : "Loading beta…";
			dialog.append(progress);
		}
		// Escape chooses the non-destructive action when the dialog offers one.
		dialog.addEventListener("cancel", (event) => {
			event.preventDefault();
			const decline = actions.find(([label]) => label === cancelLabel);
			if (decline) {
				dialog.close();
				dialog.remove();
				decline[1]();
			}
		});
		document.body.append(dialog);
		dialog.showModal();
	}

	let canReturnToStable = false;
	function clearChannelRequest() {
		const url = new URL(location.href);
		if (!["beta", "stable"].includes(url.searchParams.get("channel"))) return;
		url.searchParams.delete("channel");
		history.replaceState(history.state, "", url);
	}
	function returnToStable() {
		try {
			localStorage.removeItem(choiceKey);
			clearChannelRequest();
			location.reload();
		} catch (_) {
			failed();
		}
	}

	function confirmReturnToStable(stay) {
		show(
			"Return to the stable version?",
			"Stable opens your original browser library. Sync or export any notes you created in beta before switching.",
			[
				["Stay in beta", stay],
				["Return to stable", returnToStable],
			],
			"",
			"Stay in beta",
		);
	}

	function failed() {
		show(
			"Unable to start the selected version",
			canReturnToStable
				? "Retry or return to your original browser library. Your beta notes stay on this device."
				: "Your saved browser data has not been cleared. Retry when your connection is available.",
			[
				["Retry", () => location.reload()],
				...(canReturnToStable ? [["Return to stable", returnToStable]] : []),
			],
		);
	}

	function start(base, beta = false) {
		// Keep /app/ as the document base for the deployed stable database worker.
		// Versioned bootstrap config supplies explicit URLs for all Flutter assets.
		document.title = beta ? "Better Keep Beta" : "Better Keep";
		canReturnToStable = beta;
		if (beta) {
			const badge = document.createElement("button");
			badge.type = "button";
			badge.id = "beta-channel-tag";
			badge.textContent = "Beta";
			badge.title = "Return to stable";
			badge.setAttribute("aria-label", "Beta. Return to stable");
			badge.onclick = () => confirmReturnToStable(() => badge.focus());
			document.body.append(badge);
		}
		const script = document.createElement("script");
		script.src = `${base}flutter_bootstrap.js`;
		script.onerror = failed;
		{
			const timer = setTimeout(failed, 60000);
			window.addEventListener(
				"flutter-first-frame",
				() => {
					clearTimeout(timer);
					document.getElementById("beta-prompt")?.remove();
				},
				{ once: true },
			);
		}
		document.body.append(script);
	}

	async function chooseBeta(release) {
		show("Opening Better Keep", "Your app will be ready in a moment.");
		try {
			// Check availability before changing the saved choice. Never fetch beta before consent.
			const response = await fetch(`${release.base}flutter_bootstrap.js`, {
				cache: "no-store",
				signal: AbortSignal.timeout(10000),
			});
			if (
				!response.ok ||
				!(response.headers.get("content-type") || "").includes("javascript")
			) {
				throw new Error("Beta bootstrap unavailable");
			}
			localStorage.setItem(choiceKey, "beta");
			selected = true;
			clearChannelRequest();
			rememberRelease(release);
			start(release.base, !promoted);
		} catch (_) {
			canReturnToStable = true;
			failed();
		}
	}

	function rememberRelease(release) {
		// A storage quota/privacy restriction must not block stable startup.
		try {
			if (release.sequence)
				localStorage.setItem(sequenceKey, String(release.sequence));
		} catch (_) {}
	}
	function startStable(release) {
		try {
			if (release.stable) rememberRelease(release);
			start(release.stable?.base || "/app/");
		} catch (_) {
			failed();
		}
	}

	async function launch() {
		let release, offline;
		try {
			const manifest = "/app/beta-release.json";
			let response;
			if (navigator.onLine !== false) {
				try {
					response = await fetch(manifest, {
						cache: "no-store",
						signal: AbortSignal.timeout(5000),
					});
				} catch {
					// The browser may abort the request before its worker can respond.
				}
			}
			if (!response) {
				response = await caches.match(manifest, {cacheName: "better-keep-offline-app-v1"});
				offline = true;
			} else {
				offline = response.headers.get("X-Better-Keep-Offline") === "1";
			}
			if (!response?.ok) throw new Error("No beta release");
			release = await response.json();
			if (
				!/^[a-z0-9-]{1,80}$/.test(release.version) ||
				release.base !== `/app/releases/${release.version}/` ||
				release.storage !== "isolated-v1" ||
				(release.status !== undefined &&
					!["beta", "promoted"].includes(release.status)) ||
				(release.sequence !== undefined &&
					(!Number.isSafeInteger(release.sequence) || release.sequence < 1)) ||
				(release.sequence || 0) < sequence ||
				(release.stable &&
					(!/^[a-z0-9-]{1,80}$/.test(release.stable.version) ||
						release.stable.base !==
							`/app/releases/${release.stable.version}/stable/`)) ||
				(release.status === "promoted" &&
					release.stable?.base !== `${release.base}stable/`)
			) {
				throw new Error("Invalid beta release");
			}
		} catch (_) {
			if (selected || sequence) failed();
			else start("/app/");
			return;
		}
		promoted = release.status === "promoted";
		const url = new URL(location.href);
		const invited = url.searchParams.get("channel") === "beta";
		const wantsStable = url.searchParams.get("channel") === "stable";
		if (selected) {
			clearChannelRequest();
			rememberRelease(release);
			const openSelected = () => start(release.base, !promoted);
			if (wantsStable) {
				canReturnToStable = true;
				confirmReturnToStable(openSelected);
			} else {
				openSelected();
			}
			return;
		}
		if (wantsStable) clearChannelRequest();
		if (promoted || offline || !invited) {
			startStable(release);
			return;
		}
		show(
			"Try the next Better Keep",
			"Beta may have bugs. Edits and deletions you sync here also affect the notes in your regular app.",
			[
				["Not now", () => {
					clearChannelRequest();
					startStable(release);
				}],
				["Try beta", () => void chooseBeta(release), "beta-warning"],
			],
			"Export local-only notes first. Beta has a separate sign-in. To open your original library again, select the Beta badge and return to stable.",
			"Not now",
		);
	}
	void launch();
})();

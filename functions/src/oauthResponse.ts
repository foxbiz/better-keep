import * as crypto from "node:crypto";

export interface RenderedOAuthHtml {
	html: string;
	contentSecurityPolicy: string;
}

function escapeHtml(value: string): string {
	return value
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#39;");
}

function shell({
	title,
	heading,
	message,
	success,
	nonce,
	script,
}: {
	title: string;
	heading: string;
	message: string;
	success: boolean;
	nonce: string;
	script: string;
}): string {
	return `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)}</title>
  <style nonce="${nonce}">
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      margin: 0;
    }
    .container {
      background: white;
      border-radius: 16px;
      padding: 40px;
      text-align: center;
      box-shadow: 0 20px 60px rgba(0,0,0,0.3);
      max-width: 400px;
    }
    h1 { color: ${success ? "#2E7D32" : "#D32F2F"}; margin-bottom: 16px; }
    p { color: #666; margin-bottom: 16px; }
    .button {
      background: #6750A4;
      color: white;
      padding: 14px 28px;
      border-radius: 8px;
      text-decoration: none;
      display: inline-block;
    }
  </style>
</head>
<body>
  <div class="container">
    <h1>${escapeHtml(heading)}</h1>
    <p id="status">${escapeHtml(message)}</p>
  </div>
  <script nonce="${nonce}">${script}</script>
</body>
</html>`;
}

function rendered(html: string, nonce: string): RenderedOAuthHtml {
	return {
		html,
		contentSecurityPolicy:
			"default-src 'none'; " +
			`script-src 'nonce-${nonce}'; ` +
			`style-src 'nonce-${nonce}'; ` +
			"base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
	};
}

export function renderOAuthPopup({
	title,
	heading,
	message,
	success,
	targetOrigin,
	payload,
}: {
	title: string;
	heading: string;
	message: string;
	success: boolean;
	targetOrigin: string;
	payload: Record<string, unknown>;
}): RenderedOAuthHtml {
	const nonce = crypto.randomBytes(18).toString("base64");
	const originJson = JSON.stringify(targetOrigin);
	const payloadJson = JSON.stringify(payload).replace(/</g, "\\u003c");
	const script = `
    const targetOrigin = ${originJson};
    const payload = ${payloadJson};
    if (window.opener) {
      let attempts = 0;
      const interval = window.setInterval(() => {
        attempts += 1;
        window.opener.postMessage(payload, targetOrigin);
        if (attempts >= 20) {
          window.clearInterval(interval);
          document.getElementById("status").textContent =
            "Please close this window and return to Better Keep.";
        }
      }, 500);
      window.addEventListener("message", (event) => {
        if (
          event.origin === targetOrigin &&
          event.source === window.opener &&
          event.data &&
          event.data.type === "oauth_close"
        ) {
          window.clearInterval(interval);
          window.close();
        }
      });
    }
  `;
	return rendered(
		shell({ title, heading, message, success, nonce, script }),
		nonce,
	);
}

export function renderOAuthMobileRedirect({
	title,
	heading,
	message,
	success,
	redirectUrl,
}: {
	title: string;
	heading: string;
	message: string;
	success: boolean;
	redirectUrl: string;
}): RenderedOAuthHtml {
	const nonce = crypto.randomBytes(18).toString("base64");
	const urlJson = JSON.stringify(redirectUrl).replace(/</g, "\\u003c");
	const script = `
    const redirectUrl = ${urlJson};
    const link = document.createElement("a");
    link.className = "button";
    link.href = redirectUrl;
    link.textContent = "Open Better Keep";
    document.querySelector(".container").appendChild(link);
    window.location.replace(redirectUrl);
  `;
	return rendered(
		shell({ title, heading, message, success, nonce, script }),
		nonce,
	);
}

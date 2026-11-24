import type { OtpEmailConfig } from "./types";

type EmailTone = "primary" | "warning" | "danger";

interface TransactionalEmailConfig {
	title: string;
	category?: string;
	preheader?: string;
	paragraphs: string[];
	details?: { label: string; value: string }[];
	list?: { title: string; items: string[] };
	notice?: { title: string; text: string };
	action?: { label: string; url: string };
	tone?: EmailTone;
	code?: { value: string; expiresInMinutes: number };
}

const support = "support@betterkeep.app";
const signature = "Better Keep by Foxbiz Software Pvt. Ltd.";

export function formatEmailDate(date: Date): string {
	if (!Number.isFinite(date.getTime())) return "N/A";
	return `${date.toLocaleDateString("en-GB", {
		day: "numeric",
		month: "short",
		year: "numeric",
		timeZone: "UTC",
	})} (UTC)`;
}

// All template inputs are plain text, including user names and provider labels.
function escapeHtml(value: string): string {
	return value.replace(/[&<>"']/g, (character) => {
		const entities: Record<string, string> = {
			"&": "&amp;",
			"<": "&lt;",
			">": "&gt;",
			'"': "&quot;",
			"'": "&#39;",
		};
		return entities[character];
	});
}

/** Shared, image-independent layout for all transactional email. */
export function generateTransactionalEmail(config: TransactionalEmailConfig): {
	html: string;
	text: string;
} {
	const { title, paragraphs, details, list, notice, action, code } = config;
	if (action && !/^(https:\/\/|mailto:)/i.test(action.url)) {
		throw new Error("Email actions must use HTTPS or mailto URLs");
	}
	const noticeColor =
		config.tone === "danger"
			? "#9B3731"
			: config.tone === "warning"
				? "#805716"
				: "#625C70";
	const paragraph = (text: string) =>
		`<p style="margin: 0 0 18px; color: #48464D; font-size: 16px; line-height: 26px;">${escapeHtml(text).replace(/\n/g, "<br>")}</p>`;
	const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(title)} — Better Keep</title>
  <style>
    @media only screen and (max-width: 600px) {
      .email-outer { padding: 16px 8px !important; }
      .email-content { padding: 28px 24px !important; }
      .email-title { font-size: 27px !important; line-height: 34px !important; }
    }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #F4F3F1; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; -webkit-text-size-adjust: 100%;">
  <div style="display: none; max-height: 0; overflow: hidden; mso-hide: all;">${escapeHtml(config.preheader ?? title)}</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background-color: #F4F3F1;">
    <tr><td class="email-outer" align="center" style="padding: 40px 16px;">
      <!--[if mso]><table role="presentation" width="560" cellspacing="0" cellpadding="0" border="0"><tr><td><![endif]-->
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width: 560px; text-align: left;">
        <tr><td class="email-content" style="padding: 36px 40px 40px; background-color: #FFFFFF; border: 1px solid #E4E1E7;">
          <p style="margin: 0; color: #554176; font-size: 20px; line-height: 28px; font-weight: 700; letter-spacing: -0.6px;">Better Keep<span style="color: #807788;">.</span></p>
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr><td style="height: 26px; border-bottom: 1px solid #EAE8ED; font-size: 0;">&nbsp;</td></tr></table>
          <p style="margin: 28px 0 10px; color: #77717E; font-size: 11px; line-height: 16px; font-weight: 600; letter-spacing: 1.6px; text-transform: uppercase;">${escapeHtml(config.category ?? "Account update")}</p>
          <h1 class="email-title" style="margin: 0 0 22px; color: #29262F; font-size: 30px; line-height: 38px; font-weight: 600; letter-spacing: -0.8px;">${escapeHtml(title)}</h1>
          ${paragraphs.map(paragraph).join("\n")}
          ${
						code
							? `
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin: 24px 0; background-color: #F7F6F9; border-top: 1px solid #EAE8ED; border-bottom: 1px solid #EAE8ED;">
            <tr><td style="padding: 22px 24px;">
              <p style="margin: 0 0 10px; color: #625C70; font-size: 13px; line-height: 20px;">Your verification code</p>
              <p style="margin: 0 0 12px; color: #29262F; font-family: 'Courier New', Courier, monospace; font-size: 34px; line-height: 40px; font-weight: 700; letter-spacing: 5px; white-space: nowrap;">${escapeHtml(code.value)}</p>
              <p style="margin: 0; color: #625C70; font-size: 13px; line-height: 20px;">Expires in ${code.expiresInMinutes} minutes. Don’t share this code.</p>
            </td></tr>
          </table>`
							: ""
					}
          ${
						details?.length
							? `
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin: 24px 0; border-top: 1px solid #EAE8ED;">
            ${details
							.map(
								({
									label,
									value,
								}) => `<tr><td style="padding: 14px 0; border-bottom: 1px solid #EAE8ED;">
              <p style="margin: 0 0 4px; color: #77717E; font-size: 12px; line-height: 18px;">${escapeHtml(label)}</p>
              <p style="margin: 0; color: #29262F; font-size: 16px; line-height: 24px; font-weight: 600;">${escapeHtml(value)}</p>
            </td></tr>`,
							)
							.join("\n")}
          </table>`
							: ""
					}
          ${
						list
							? `<h2 style="margin: 24px 0 10px; color: #29262F; font-size: 16px; line-height: 24px; font-weight: 600;">${escapeHtml(list.title)}</h2>
          <ul style="margin: 0 0 24px; padding-left: 20px; color: #48464D; font-size: 15px; line-height: 24px;">${list.items.map((item) => `<li style="padding-bottom: 6px;">${escapeHtml(item)}</li>`).join("")}</ul>`
							: ""
					}
          ${
						notice
							? `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="margin: 24px 0 0;"><tr><td style="padding: 0 0 0 16px; border-left: 2px solid ${noticeColor};">
            <p style="margin: 0 0 6px; color: ${noticeColor}; font-size: 14px; line-height: 22px; font-weight: 600;">${escapeHtml(notice.title)}</p>
            <p style="margin: 0; color: #625C70; font-size: 14px; line-height: 22px;">${escapeHtml(notice.text)}</p>
          </td></tr></table>`
							: ""
					}
          ${
						action
							? `<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin: 28px 0 0;"><tr><td bgcolor="#5E477D" style="border-radius: 4px; text-align: center; mso-padding-alt: 14px 22px;">
            <a href="${escapeHtml(action.url)}" style="display: inline-block; padding: 14px 22px; border: 1px solid #5E477D; border-radius: 4px; color: #FFFFFF; font-size: 14px; line-height: 20px; font-weight: 600; text-decoration: none;">${escapeHtml(action.label)}</a>
          </td></tr></table>`
							: ""
					}
        </td></tr>
        <tr><td style="padding: 22px 12px; color: #77717E; font-size: 12px; line-height: 20px;">
          Need a hand? <a href="mailto:${support}" style="color: #625572; text-decoration: underline;">${support}</a><br>
          ${signature}
        </td></tr>
      </table>
      <!--[if mso]></td></tr></table><![endif]-->
    </td></tr>
  </table>
</body>
</html>`;

	const text = [
		title,
		...paragraphs,
		...(code
			? [
					`Your verification code: ${code.value}\n\nThis code expires in ${code.expiresInMinutes} minutes. Don’t share this code.`,
				]
			: []),
		...(details?.map(({ label, value }) => `${label}: ${value}`) ?? []),
		...(list
			? [`${list.title}\n${list.items.map((item) => `- ${item}`).join("\n")}`]
			: []),
		...(notice ? [`${notice.title}\n${notice.text}`] : []),
		...(action ? [`${action.label}: ${action.url}`] : []),
		`If you have questions, contact us at ${support}`,
		signature,
	].join("\n\n");

	return { html, text };
}

function otpEmail(config: OtpEmailConfig) {
	return generateTransactionalEmail({
		title: config.title,
		category: "Account security",
		paragraphs: [config.description],
		code: {
			value: config.otp,
			expiresInMinutes: config.expiresInMinutes ?? 10,
		},
		tone: config.theme,
		notice: config.securityNote
			? { title: "Security note", text: config.securityNote }
			: undefined,
	});
}

export function generateOtpEmailHtml(config: OtpEmailConfig): string {
	return otpEmail(config).html;
}

export function generateOtpEmailText(config: OtpEmailConfig): string {
	return otpEmail(config).text;
}

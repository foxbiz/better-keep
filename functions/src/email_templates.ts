import type { OtpEmailConfig } from "./types";

/**
 * Generates a consistent, beautiful OTP email HTML template
 * Uses a unified design across all OTP emails in the app
 */
export function generateOtpEmailHtml(config: OtpEmailConfig): string {
	const {
		title,
		description,
		otp,
		theme,
		securityNote,
		expiresInMinutes = 10,
	} = config;

	// Theme colors
	const themeColors = {
		primary: { bg: "#6750A4", light: "#F3E5F5", text: "#6750A4" },
		warning: { bg: "#FF9800", light: "#FFF3E0", text: "#E65100" },
		danger: { bg: "#D32F2F", light: "#FFEBEE", text: "#C62828" },
	};
	const colors = themeColors[theme];

	return `
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
</head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
  <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
    <h1 style="color: ${colors.text}; font-size: 24px; margin-bottom: 16px; text-align: center;">${title}</h1>
    <p style="color: #333; font-size: 16px; line-height: 1.5; text-align: center;">
      ${description}
    </p>
    <div style="background: ${colors.bg}; border-radius: 12px; padding: 24px; text-align: center; margin: 24px 0;">
      <p style="color: rgba(255,255,255,0.8); font-size: 14px; margin: 0 0 8px 0;">Your verification code</p>
      <span style="font-size: 32px; font-weight: bold; letter-spacing: 12px; color: white; font-family: 'SF Mono', Monaco, 'Courier New', monospace; white-space: nowrap;">${otp}</span>
    </div>
    <p style="color: #666; font-size: 14px; line-height: 1.5; text-align: center;">
      This code expires in <strong>${expiresInMinutes} minutes</strong>.
    </p>
    ${
			securityNote
				? `
    <div style="background: ${colors.light}; border-radius: 8px; padding: 16px; margin: 16px 0; border-left: 4px solid ${colors.bg};">
      <p style="color: ${colors.text}; font-size: 14px; margin: 0;">
        <strong>⚠️ Security:</strong> ${securityNote}
      </p>
    </div>
    `
				: ""
		}
    <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
    <p style="color: #999; font-size: 12px; text-align: center;">
      If you have questions, contact us at support@betterkeep.app
    </p>
    <p style="color: #bbb; font-size: 11px; margin-top: 8px; text-align: center;">
      Better Keep by Foxbiz Software Pvt. Ltd.
    </p>
  </div>
</body>
</html>
`;
}

/**
 * Generates plain text version of OTP email
 */
export function generateOtpEmailText(config: OtpEmailConfig): string {
	const {
		title,
		description,
		otp,
		securityNote,
		expiresInMinutes = 10,
	} = config;

	return `
${title}

${description}

Your verification code: ${otp}

This code expires in ${expiresInMinutes} minutes.
${securityNote ? `\nSecurity: ${securityNote}\n` : ""}
If you have questions, contact us at support@betterkeep.app

Better Keep by Foxbiz Software Pvt. Ltd.
`.trim();
}

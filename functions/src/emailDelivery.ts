import type * as nodemailer from "nodemailer";

export type EmailDeliveryResult = "sent" | "logged";

export function wasEmailDelivered(
	result: EmailDeliveryResult | "skipped",
): result is EmailDeliveryResult {
	return result === "sent" || result === "logged";
}

export interface EmailDeliveryDependencies {
	isEmulator: boolean;
	createTransporter: () => nodemailer.Transporter;
	log?: (...values: unknown[]) => void;
}

/**
 * Delivers an email in production and records its complete plaintext payload
 * in the Functions emulator.
 *
 * The transporter factory is deliberately lazy so emulator delivery cannot
 * read SMTP configuration, access a secret, construct Nodemailer, or touch the
 * network.
 */
export async function deliverEmail(
	mailOptions: nodemailer.SendMailOptions,
	dependencies: EmailDeliveryDependencies,
): Promise<EmailDeliveryResult> {
	if (dependencies.isEmulator) {
		const log = dependencies.log ?? console.log;
		log("📧 [EMULATOR] Email logged");
		log("  From:", mailOptions.from);
		log("  To:", mailOptions.to);
		log("  Subject:", mailOptions.subject);
		log(
			"  Text:",
			typeof mailOptions.text === "string"
				? mailOptions.text
				: "(no plaintext body)",
		);
		return "logged";
	}

	try {
		const transporter = dependencies.createTransporter();
		await transporter.sendMail(mailOptions);
	} catch (error) {
		// SMTP errors can include recipient addresses and server responses. Keep
		// a diagnostic code without propagating those payloads into caller logs.
		const errorCode = (error as { code?: unknown } | null)?.code;
		const code =
			typeof errorCode === "string" && /^[A-Z_]{1,32}$/.test(errorCode)
				? errorCode
				: "SMTP_ERROR";
		throw new Error(`Email delivery failed (${code})`);
	}
	return "sent";
}

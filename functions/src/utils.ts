import * as crypto from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { google } from "googleapis";
import * as jose from "jose";
import * as nodemailer from "nodemailer";
import {
	appStoreSharedSecret,
	auth,
	db,
	emailPassword,
	IOS_BUNDLE_ID,
	IOS_PRODUCT_IDS,
	isEmulator,
} from "./config";
import { mergeSubscriptionClaims } from "./customClaims";
import { deliverEmail, type EmailDeliveryResult } from "./emailDelivery";
import { refreshGooglePlaySubscription } from "./googlePlayService";
import { enqueueRevenueEventInTransaction } from "./revenueOutbox";
import {
	normalizedSubscriptionFields,
	requireVerifiedEntitlementPayload,
} from "./subscriptionEntitlement";
import { reconcileUserEntitlement } from "./subscriptionReconciler";
import type { AppStoreJWSTransactionPayload } from "./types";

/**
 * Set custom claims on user's Firebase Auth token for subscription status.
 * This enables server-side enforcement of subscription gating in Firestore/Storage rules.
 *
 * @param userId - The Firebase Auth user ID
 * @param plan - The subscription plan ('pro' or 'free')
 * @param expiresAt - When the subscription expires (null for free plan)
 */
export async function setSubscriptionClaims(
	userId: string,
	plan: "pro" | "free",
	expiresAt: Date | null,
): Promise<void> {
	try {
		const user = await auth.getUser(userId);
		const claims = mergeSubscriptionClaims(user.customClaims, plan, expiresAt);
		await auth.setCustomUserClaims(userId, claims);

		if (plan === "pro" && expiresAt) {
			console.log(
				`Set Pro claims for user ${userId}, expires ${expiresAt.toISOString()}`,
			);
		} else {
			console.log(`Cleared Pro claims for user ${userId} (now free)`);
		}
	} catch (error) {
		console.error(`Error setting subscription claims for ${userId}:`, error);
		// Don't throw - claims are a security enhancement, not critical path
	}
}

/**
 * Get Google Play Android Publisher API client
 */
export async function getPlayDeveloperApi(credentialsJson: string) {
	const credentials = JSON.parse(credentialsJson);
	const authClient = new google.auth.GoogleAuth({
		credentials,
		scopes: ["https://www.googleapis.com/auth/androidpublisher"],
	});

	return google.androidpublisher({
		version: "v3",
		auth: authClient,
	});
}

export function getEmailTransporter(password: string) {
	const host = process.env.EMAIL_HOST;
	const port = process.env.EMAIL_PORT;

	if (!host || !port) {
		throw new Error(
			"EMAIL_HOST and EMAIL_PORT environment variables must be set",
		);
	}

	return nodemailer.createTransport({
		host: host,
		port: Number.parseInt(port, 10),
		secure: process.env.EMAIL_SECURE !== "false", // default true for port 465
		auth: {
			user: process.env.EMAIL_USER,
			pass: password,
		},
	});
}

/**
 * Send an email or log it in emulator mode
 * In emulator mode, emails are logged instead of being sent
 */
export async function sendEmail(
	mailOptions: nodemailer.SendMailOptions,
): Promise<EmailDeliveryResult> {
	return deliverEmail(mailOptions, {
		isEmulator,
		createTransporter: () => getEmailTransporter(emailPassword.value()),
	});
}

/**
 * Generates a cryptographically secure 6-digit OTP
 */
export function generateOtp(): string {
	const randomBytes = crypto.randomBytes(4);
	const randomNumber = randomBytes.readUInt32BE(0);
	// Map to 6-digit range (100000-999999)
	const otp = 100000 + (randomNumber % 900000);
	return otp.toString();
}

/**
 * Send trial welcome email to new user
 */
export async function sendTrialWelcomeEmail(
	email: string,
	displayName: string,
	expiresAt: Date,
): Promise<void> {
	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	const expiryDateStr = expiresAt.toLocaleDateString("en-US", {
		weekday: "long",
		year: "numeric",
		month: "long",
		day: "numeric",
	});

	const mailOptions = {
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: "Welcome to Better Keep Pro - Your Free Trial Has Started! 🎉",
		html: `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
      </head>
      <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
        <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
          <h1 style="color: #6750A4; font-size: 24px; margin-bottom: 16px;">Welcome to Better Keep Pro! 🎉</h1>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Hi ${displayName},
          </p>
          <p style="color: #333; font-size: 16px; line-height: 1.5;">
            Thank you for signing up! We've activated your <strong>free Pro trial</strong> so you can experience all the premium features.
          </p>
          <div style="background: linear-gradient(135deg, #6750A4 0%, #9C27B0 100%); border-radius: 8px; padding: 20px; text-align: center; margin: 24px 0; color: white;">
            <p style="margin: 0; font-size: 14px; opacity: 0.9;">Your trial expires on</p>
            <p style="margin: 8px 0 0 0; font-size: 20px; font-weight: bold;">${expiryDateStr}</p>
          </div>
          <p style="color: #333; font-size: 16px; line-height: 1.5; font-weight: 600;">
            During your trial, you can:
          </p>
          <ul style="color: #333; font-size: 14px; line-height: 1.8;">
            <li>🔒 Lock unlimited notes with biometric or PIN</li>
            <li>☁️ Sync notes across all your devices with end-to-end encryption</li>
          </ul>
          <p style="color: #666; font-size: 14px; line-height: 1.5;">
            We hope you enjoy using Better Keep! If you have any questions, reach out to us at <a href="mailto:support@betterkeep.app" style="color: #6750A4;">support@betterkeep.app</a>.
          </p>
          <hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
          <p style="color: #999; font-size: 12px;">
            Better Keep by Foxbiz Software Pvt. Ltd.
          </p>
        </div>
      </body>
      </html>
    `,
		text: `
Welcome to Better Keep Pro! 🎉

Hi ${displayName},

Thank you for signing up! We've activated your free Pro trial so you can experience all the premium features.

Your trial expires on: ${expiryDateStr}

During your trial, you can:
- Lock unlimited notes with biometric or PIN
- Sync notes across all your devices with end-to-end encryption

We hope you enjoy using Better Keep! If you have any questions, reach out to us at support@betterkeep.app.

Better Keep by Foxbiz Software Pvt. Ltd.
    `,
	};

	await sendEmail(mailOptions);
}

/**
 * Verify Google Play subscription purchase
 */
export async function verifyGooglePlayPurchase(
	userId: string,
	productId: string,
	purchaseToken: string,
): Promise<{
	valid: boolean;
	sendWelcomeEmail?: boolean;
	message: string;
	subscription?: object;
}> {
	const subscriptionRef = db.collection("subscriptions").doc(purchaseToken);
	const before = await subscriptionRef.get();
	const refreshed = await refreshGooglePlaySubscription({
		productId,
		purchaseToken,
		requestedUserId: userId,
	});
	if (refreshed.status === "mismatch") {
		throw new HttpsError(
			"failed-precondition",
			"This Google Play purchase could not be matched to this account",
		);
	}
	if (!refreshed.entitled || !refreshed.expiresAt) {
		return {
			valid: false,
			message: "Subscription is not currently entitled",
		};
	}
	const welcomeEmailAlreadySent = before.data()?.welcomeEmailSent === true;
	if (!welcomeEmailAlreadySent) {
		await subscriptionRef.set(
			{ welcomeEmailSent: true, updatedAt: FieldValue.serverTimestamp() },
			{ merge: true },
		);
	}

	console.log(
		`Successfully verified and linked Play subscription for user ${userId}`,
	);

	return {
		valid: true,
		sendWelcomeEmail: !welcomeEmailAlreadySent,
		message: "Subscription verified and activated",
		subscription: requireVerifiedEntitlementPayload(refreshed.data),
	};
}

/**
 * Send Razorpay subscription email (welcome, cancelled, resumed, renewal)
 */
export async function sendRazorpaySubscriptionEmail(
	userId: string,
	type: "welcome" | "cancelled" | "resumed" | "renewed" | "expired",
	expiryDate?: Date | null,
): Promise<EmailDeliveryResult | "skipped"> {
	const userRecord = await auth.getUser(userId);
	const email = userRecord.email;

	if (!email) {
		console.warn(`No email found for user ${userId}`);
		return "skipped";
	}

	const senderEmail = process.env.EMAIL_FROM;
	const senderName = process.env.EMAIL_NAME;

	let subject = "";
	let heading = "";
	let message = "";
	let ctaText = "";
	let ctaUrl = "";

	const expiryStr = expiryDate ? expiryDate.toLocaleDateString() : "N/A";

	switch (type) {
		case "welcome":
			subject = "Welcome to Better Keep Notes Pro! 🎉";
			heading = "Welcome to Better Keep Notes Pro";
			message = `Thank you for subscribing! Your account has been upgraded and you now have access to all Pro features including unlimited locked notes, real-time encrypted sync, and priority support.\n\nYour subscription will renew on ${expiryStr}.`;
			ctaText = "Open Better Keep Notes";
			ctaUrl = "https://betterkeep.app";
			break;
		case "cancelled":
			subject = "Your Better Keep Notes subscription has been cancelled";
			heading = "Subscription Cancelled";
			message = `Your subscription has been cancelled. You'll continue to have Pro access until ${expiryStr}, after which you'll be switched to the free plan.\n\nYou can resume your subscription anytime before it expires to keep your Pro benefits.`;
			ctaText = "Resume Subscription";
			ctaUrl = "https://betterkeep.app";
			break;
		case "resumed":
			subject = "Your Better Keep Notes subscription has been resumed";
			heading = "Subscription Resumed";
			message = `Great news! Your subscription has been resumed and will renew automatically on ${expiryStr}. You'll continue to enjoy all Pro features.`;
			ctaText = "Open Better Keep Notes";
			ctaUrl = "https://betterkeep.app";
			break;
		case "renewed":
			subject = "Your Better Keep Notes subscription has been renewed";
			heading = "Subscription Renewed";
			message = `Your Pro subscription has been renewed successfully. Your next billing date is ${expiryStr}. Thank you for your continued support!`;
			ctaText = "Open Better Keep Notes";
			ctaUrl = "https://betterkeep.app";
			break;
		case "expired":
			subject = "Your Better Keep Notes Pro subscription has expired";
			heading = "Subscription Expired";
			message =
				"Your Pro subscription has expired and your account has been switched to the free plan. You can resubscribe anytime to regain access to Pro features.";
			ctaText = "Resubscribe to Pro";
			ctaUrl = "https://betterkeep.app";
			break;
	}

	const htmlContent = `
			<!DOCTYPE html>
			<html>
			<head>
				<meta charset="utf-8">
				<meta name="viewport" content="width=device-width, initial-scale=1.0">
			</head>
			<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
				<div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
					<div style="text-align: center; margin-bottom: 24px;">
						<img src="https://betterkeep.app/icons/logo.png" alt="Better Keep Notes" style="width: 64px; height: 64px;">
					</div>
					<h1 style="color: #333; font-size: 22px; margin-bottom: 20px;">${heading}</h1>
					<p style="color: #555; font-size: 15px; line-height: 1.6; margin-bottom: 16px; white-space: pre-line;">
						${message}
					</p>
					<div style="text-align: center; margin: 24px 0;">
						<a href="${ctaUrl}" style="background: #6366f1; color: white; padding: 12px 24px; border-radius: 8px; text-decoration: none; font-weight: 600; display: inline-block;">${ctaText}</a>
					</div>
					<p style="color: #555; font-size: 15px; line-height: 1.6;">
						If you have any questions, contact us at <a href="mailto:support@betterkeep.app" style="color: #6366f1;">support@betterkeep.app</a>.
					</p>
					<hr style="border: none; border-top: 1px solid #eee; margin: 24px 0;">
					<p style="color: #999; font-size: 13px;">
						<strong>Better Keep Notes</strong> by Foxbiz Software Pvt. Ltd.
					</p>
				</div>
			</body>
			</html>
		`;

	const result = await sendEmail({
		from: `"${senderName}" <${senderEmail}>`,
		to: email,
		subject: subject,
		html: htmlContent,
		text: `${heading}\n\n${message}\n\n${ctaText}: ${ctaUrl}\n\nBetter Keep Notes by Foxbiz Software Pvt. Ltd.`,
	});

	console.log(
		`${result === "logged" ? "Logged" : "Sent"} Razorpay ${type} email to ${email}`,
	);
	return result;
}
/**
 * Helper function to make Razorpay API requests
 */
export async function razorpayRequest(
	keyId: string,
	keySecret: string,
	method: string,
	endpoint: string,
	body?: Record<string, unknown>,
): Promise<unknown> {
	if (!keyId || !keySecret) {
		throw new Error("Razorpay credentials not configured");
	}

	const auth = Buffer.from(`${keyId}:${keySecret}`).toString("base64");

	let response: Response;
	try {
		response = await fetch(`https://api.razorpay.com/v1${endpoint}`, {
			method,
			headers: {
				Authorization: `Basic ${auth}`,
				"Content-Type": "application/json",
			},
			body: body ? JSON.stringify(body) : undefined,
		});
	} catch {
		throw new RazorpayApiError(null);
	}

	if (!response.ok) {
		await response.body?.cancel().catch(() => {});
		throw new RazorpayApiError(response.status);
	}

	return response.json();
}

/**
 * Sanitized provider failure. Deliberately excludes request URLs, identifiers,
 * credentials, signatures, and response bodies so callers can safely report it.
 */
export class RazorpayApiError extends Error {
	readonly status: number | null;

	constructor(status: number | null) {
		super(
			status === null
				? "Razorpay API request failed"
				: `Razorpay API request failed (${status})`,
		);
		this.name = "RazorpayApiError";
		this.status = status;
	}
}

// Apple Root CA - G3 (ECC, valid through 2039-04-30)
// Downloaded from https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

/**
 * Check whether a string looks like a JWS compact serialization (3 dot-separated base64url segments).
 */
function isJWSToken(payload: string): boolean {
	const parts = payload.split(".");
	if (parts.length !== 3) return false;
	// Each segment must be non-empty and contain only base64url characters
	const b64urlRegex = /^[A-Za-z0-9_-]+$/;
	return parts.every((p) => p.length > 0 && b64urlRegex.test(p));
}

/**
 * Verify and decode a StoreKit 2 JWS signed transaction from the App Store.
 *
 * 1. Decode the JWS header to extract the x5c certificate chain.
 * 2. Validate the chain: leaf → intermediate → Apple Root CA G3.
 * 3. Verify the JWS signature using the leaf certificate's public key.
 * 4. Return the decoded transaction payload.
 */
async function verifyAndDecodeAppStoreJWS(
	jwsToken: string,
): Promise<AppStoreJWSTransactionPayload> {
	// 1. Decode the protected header to get the x5c chain
	const protectedHeader = jose.decodeProtectedHeader(jwsToken);
	const x5c = protectedHeader.x5c;
	if (!x5c || x5c.length < 2) {
		throw new HttpsError(
			"invalid-argument",
			"JWS header missing x5c certificate chain",
		);
	}

	// 2. Build X509 certificates from the chain
	const leafCertPem = `-----BEGIN CERTIFICATE-----\n${x5c[0]}\n-----END CERTIFICATE-----`;

	// Validate chain: each certificate should be issued by the next one
	for (let i = 0; i < x5c.length - 1; i++) {
		const certPem = `-----BEGIN CERTIFICATE-----\n${x5c[i]}\n-----END CERTIFICATE-----`;
		const issuerPem = `-----BEGIN CERTIFICATE-----\n${x5c[i + 1]}\n-----END CERTIFICATE-----`;
		const cert = new crypto.X509Certificate(certPem);
		const issuer = new crypto.X509Certificate(issuerPem);
		if (!cert.checkIssued(issuer)) {
			throw new HttpsError(
				"invalid-argument",
				`JWS certificate chain broken at index ${i}`,
			);
		}
	}

	// Validate the root of the chain against the embedded Apple Root CA G3
	const lastInChainPem = `-----BEGIN CERTIFICATE-----\n${x5c[x5c.length - 1]}\n-----END CERTIFICATE-----`;
	const lastInChain = new crypto.X509Certificate(lastInChainPem);
	const appleRootCert = new crypto.X509Certificate(APPLE_ROOT_CA_G3_PEM);

	// The last cert in x5c should either BE the Apple Root CA or be issued by it
	const lastFingerprint = lastInChain.fingerprint256;
	const rootFingerprint = appleRootCert.fingerprint256;
	if (lastFingerprint === rootFingerprint) {
		// x5c includes the root itself — valid
	} else if (lastInChain.checkIssued(appleRootCert)) {
		// x5c ends at an intermediate signed by the root — valid
	} else {
		throw new HttpsError(
			"invalid-argument",
			"JWS certificate chain does not anchor to Apple Root CA G3",
		);
	}

	// 3. Validate algorithm and import the leaf certificate's public key
	if (protectedHeader.alg !== "ES256") {
		throw new HttpsError(
			"invalid-argument",
			`Unexpected JWS algorithm: ${protectedHeader.alg}`,
		);
	}
	const publicKey = await jose.importX509(leafCertPem, "ES256");
	const { payload } = await jose.compactVerify(jwsToken, publicKey);
	const decoded = JSON.parse(
		new TextDecoder().decode(payload),
	) as AppStoreJWSTransactionPayload;

	return decoded;
}

/**
 * Handle a verified StoreKit 2 JWS transaction: validate fields, write Firestore, set claims.
 */
async function handleVerifiedJWSTransaction(
	userId: string,
	transaction: AppStoreJWSTransactionPayload,
): Promise<{
	valid: boolean;
	sendWelcomeEmail?: boolean;
	message: string;
	subscription?: object;
}> {
	// Validate bundle ID
	if (transaction.bundleId !== IOS_BUNDLE_ID) {
		return {
			valid: false,
			message: `Bundle ID mismatch: expected ${IOS_BUNDLE_ID}, got ${transaction.bundleId}`,
		};
	}

	// Log sandbox transactions (Apple review and TestFlight always use sandbox)
	if (transaction.environment === "Sandbox") {
		console.log(
			`App Store JWS: accepting Sandbox transaction for user=${userId}, ` +
				`product=${transaction.productId}, txn=${transaction.transactionId}`,
		);
	}

	// Validate product ID
	const knownProductIds = Object.values(IOS_PRODUCT_IDS) as string[];
	if (!knownProductIds.includes(transaction.productId)) {
		return {
			valid: false,
			message: `Unknown product ID: ${transaction.productId}`,
		};
	}

	// Validate expiry
	const now = Date.now();
	if (!transaction.expiresDate || transaction.expiresDate <= now) {
		return {
			valid: false,
			message: "Subscription has expired",
		};
	}

	const originalTransactionId = transaction.originalTransactionId;
	const resolvedProductId = transaction.productId;
	const expiresMs = transaction.expiresDate;
	const billingPeriod =
		resolvedProductId === IOS_PRODUCT_IDS.yearly ? "yearly" : "monthly";
	const expiresAt = Timestamp.fromMillis(expiresMs);

	// Atomically read the subscription doc and write the new owner inside a
	// Firestore transaction to prevent two concurrent verifications from
	// racing to claim the same subscription.
	const existingRef = db
		.collection("subscriptions")
		.doc(`ios_${originalTransactionId}`);
	const revenueEvent =
		transaction.environment === "Production" &&
		typeof transaction.price === "number" &&
		Number.isSafeInteger(transaction.price) &&
		transaction.price >= 0 &&
		Number.isSafeInteger(transaction.price * 1000) &&
		typeof transaction.currency === "string"
			? ({
					provider: "app_store",
					providerTransactionId: transaction.revocationDate
						? `${transaction.transactionId}:refund:${transaction.revocationDate}`
						: transaction.transactionId,
					userId,
					amountMicros: transaction.price * 1000,
					currency: transaction.currency,
					kind: transaction.revocationDate ? "refund" : "charge",
					environment: "production",
					occurredAt: new Date(
						transaction.purchaseDate ?? transaction.signedDate,
					),
					metadata: {
						originalTransactionId,
						productId: resolvedProductId,
					},
				} as const)
			: null;

	const { oldUserId, welcomeEmailAlreadySent, autoRenew, subState } =
		await db.runTransaction(async (txn) => {
			const snap = await txn.get(existingRef);
			const data = snap.exists ? snap.data() : undefined;
			if (revenueEvent) {
				await enqueueRevenueEventInTransaction(txn, revenueEvent);
			}

			// Determine willAutoRenew from webhook state or defaults
			const revoked = transaction.revocationDate != null;
			let autoRenew: boolean;
			if (revoked) {
				autoRenew = false;
			} else if (data?.willAutoRenew != null) {
				autoRenew = data.willAutoRenew as boolean;
			} else {
				autoRenew = true; // New subscription, no webhook data yet
			}
			const subState = autoRenew
				? "SUBSCRIPTION_STATE_ACTIVE"
				: "SUBSCRIPTION_STATE_CANCELED";

			const weSent = data?.welcomeEmailSent === true;
			let prevOwner: string | null = null;

			if (snap.exists && data?.userId && data.userId !== userId) {
				prevOwner = data.userId as string;
			}

			txn.set(
				existingRef,
				{
					...normalizedSubscriptionFields(
						{
							billingPeriod,
							environment:
								transaction.environment === "Production"
									? "production"
									: "test",
							expiresAt,
							plan: "pro",
							source: "app_store",
							subscriptionState: subState,
							willAutoRenew: autoRenew,
						},
						Date.now(),
					),
					userId,
					productId: resolvedProductId,
					purchaseToken: originalTransactionId,
					originalTransactionId,
					billingPeriod,
					expiresAt,
					externalAccountVerified: true,
					lastVerifiedAt: FieldValue.serverTimestamp(),
					jwsTransactionId: transaction.transactionId,
					...(!weSent ? { welcomeEmailSent: true } : {}),
					...(!snap.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);

			return {
				autoRenew,
				oldUserId: prevOwner,
				subState,
				welcomeEmailAlreadySent: weSent,
			};
		});

	// Recompute both owners from all providers; never clear an overlapping entitlement.
	if (oldUserId) {
		console.log(
			`Transferring App Store subscription ${originalTransactionId} ` +
				`from user ${oldUserId} to ${userId} (JWS path)`,
		);
		await reconcileUserEntitlement(oldUserId);
	}

	await reconcileUserEntitlement(userId);

	console.log(
		`App Store (JWS): verified subscription for user ${userId}, product: ${resolvedProductId}`,
	);

	return {
		valid: true,
		sendWelcomeEmail: !welcomeEmailAlreadySent,
		message: "Subscription verified and activated",
		subscription: requireVerifiedEntitlementPayload({
			plan: "pro",
			source: "app_store",
			billingPeriod,
			expiresAt: Timestamp.fromMillis(expiresMs),
			willAutoRenew: autoRenew,
			subscriptionState: subState,
		}),
	};
}

/**
 * Verify an App Store subscription purchase.
 * Supports both StoreKit 2 JWS signed transactions and legacy base64 app receipts.
 * Handles sandbox/production routing automatically.
 */
export async function verifyAppStorePurchase(
	userId: string,
	productId: string,
	receiptData: string,
): Promise<{
	valid: boolean;
	sendWelcomeEmail?: boolean;
	message: string;
	subscription?: object;
}> {
	console.log(
		`App Store verify start: user=${userId}, product=${productId}, receiptLen=${receiptData.length}`,
	);

	const rawReceiptData = receiptData.trim();
	if (!rawReceiptData) {
		throw new HttpsError("invalid-argument", "receiptData is empty");
	}

	// StoreKit 2 sends a JWS signed transaction instead of a base64 app receipt.
	// Detect and handle the JWS path first.
	if (isJWSToken(rawReceiptData)) {
		console.log(
			`App Store: detected JWS signed transaction for user=${userId}, verifying...`,
		);
		try {
			const transaction = await verifyAndDecodeAppStoreJWS(rawReceiptData);
			console.log(
				`App Store JWS decoded: product=${transaction.productId}, ` +
					`originalTxn=${transaction.originalTransactionId}, ` +
					`env=${transaction.environment}, expires=${new Date(transaction.expiresDate).toISOString()}`,
			);
			return handleVerifiedJWSTransaction(userId, transaction);
		} catch (error) {
			if (error instanceof HttpsError) throw error;
			console.error("App Store JWS verification failed:", error);
			return {
				valid: false,
				message: `JWS verification failed: ${error instanceof Error ? error.message : String(error)}`,
			};
		}
	}

	// Legacy path: base64 app receipt → Apple /verifyReceipt endpoint
	const sharedSecret = appStoreSharedSecret.value();
	if (!sharedSecret) {
		throw new HttpsError(
			"failed-precondition",
			"APP_STORE_SHARED_SECRET is not configured on the server",
		);
	}

	let receiptPayload = rawReceiptData;
	try {
		const parsed = JSON.parse(rawReceiptData) as Record<string, unknown>;

		// Some clients mistakenly send transaction metadata JSON instead of base64 receipt.
		if (
			typeof parsed.transactionId === "string" ||
			typeof parsed.originalTransactionId === "string"
		) {
			throw new HttpsError(
				"invalid-argument",
				"Invalid App Store payload: send the base64 app receipt, not transaction JSON",
			);
		}

		// Accept wrapped payloads for compatibility.
		if (typeof parsed["receipt-data"] === "string") {
			receiptPayload = parsed["receipt-data"];
		} else if (typeof parsed.receiptData === "string") {
			receiptPayload = parsed.receiptData;
		}
	} catch (error) {
		if (error instanceof HttpsError) {
			throw error;
		}
		// Not JSON is fine - valid clients usually send raw base64 receipt text.
	}

	async function callVerifyReceipt(
		url: string,
	): Promise<Record<string, unknown>> {
		const response = await fetch(url, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				"receipt-data": receiptPayload,
				password: sharedSecret,
				"exclude-old-transactions": true,
			}),
		});

		if (!response.ok) {
			throw new Error(`Apple API HTTP error: ${response.status}`);
		}
		return response.json() as Promise<Record<string, unknown>>;
	}

	let receiptEnvironment: "production" | "test" = "production";
	let appleResponse = await callVerifyReceipt(
		"https://buy.itunes.apple.com/verifyReceipt",
	);

	let status = appleResponse.status as number;
	if (status === 21007) {
		receiptEnvironment = "test";
		appleResponse = await callVerifyReceipt(
			"https://sandbox.itunes.apple.com/verifyReceipt",
		);
		status = appleResponse.status as number;
	}

	if (status !== 0) {
		return {
			valid: false,
			message: `Receipt validation failed (status: ${status})`,
		};
	}

	const knownProductIds = Object.values(IOS_PRODUCT_IDS) as string[];
	const latestReceiptInfo =
		(appleResponse.latest_receipt_info as Array<Record<string, string>>) || [];
	const receiptRoot =
		(appleResponse.receipt as Record<string, unknown> | undefined) || {};
	const inAppReceipts =
		(receiptRoot.in_app as Array<Record<string, string>> | undefined) || [];
	const receiptEntries =
		latestReceiptInfo.length > 0 ? latestReceiptInfo : inAppReceipts;
	const pendingRenewalInfo =
		(appleResponse.pending_renewal_info as Array<Record<string, string>>) || [];
	const now = Date.now();

	const activeReceipts = receiptEntries.filter((r) => {
		const expiresMs = Number.parseInt(r.expires_date_ms || "0", 10);
		return (
			knownProductIds.includes(r.product_id) &&
			!r.cancellation_date_ms &&
			expiresMs > now
		);
	});

	if (activeReceipts.length === 0) {
		console.warn(
			`App Store verify: no active receipts. latest_receipt_info=${latestReceiptInfo.length}, in_app=${inAppReceipts.length}`,
		);
		return { valid: false, message: "No active subscription found in receipt" };
	}

	activeReceipts.sort(
		(a, b) =>
			Number.parseInt(b.expires_date_ms, 10) -
			Number.parseInt(a.expires_date_ms, 10),
	);
	const latest = activeReceipts[0];

	const originalTransactionId = latest.original_transaction_id;
	const expiresMs = Number.parseInt(latest.expires_date_ms, 10);
	const resolvedProductId = latest.product_id;
	if (
		!originalTransactionId ||
		!resolvedProductId ||
		!Number.isFinite(expiresMs)
	) {
		return {
			valid: false,
			message: "Receipt payload missing required subscription fields",
		};
	}
	const billingPeriod =
		resolvedProductId === IOS_PRODUCT_IDS.yearly ? "yearly" : "monthly";

	const expiresAt = Timestamp.fromMillis(expiresMs);

	// Determine willAutoRenew from pending_renewal_info
	// auto_renew_status: "1" = will renew, "0" = won't renew (user cancelled)
	const renewalInfo =
		pendingRenewalInfo.find(
			(r) => r.original_transaction_id === originalTransactionId,
		) ?? pendingRenewalInfo.find((r) => r.product_id === resolvedProductId);
	console.log(
		`App Store pending_renewal_info: ${JSON.stringify(pendingRenewalInfo)}, ` +
			`matched renewalInfo: ${JSON.stringify(renewalInfo)}`,
	);
	// Default to false (cancelled) when renewal info is missing — safer than
	// assuming active. Use String() to handle both "1"/"0" and numeric 1/0.
	const willAutoRenew =
		renewalInfo != null && String(renewalInfo.auto_renew_status) === "1";
	const subscriptionState = willAutoRenew
		? "SUBSCRIPTION_STATE_ACTIVE"
		: "SUBSCRIPTION_STATE_CANCELED";

	// Atomically read the subscription doc and write the new owner inside a
	// Firestore transaction to prevent concurrent verifications from racing.
	const existingRef = db
		.collection("subscriptions")
		.doc(`ios_${originalTransactionId}`);

	const { oldUserId: legacyOldUserId, appStoreWelcomeEmailAlreadySent } =
		await db.runTransaction(async (txn) => {
			const snap = await txn.get(existingRef);
			const data = snap.exists ? snap.data() : undefined;
			const weSent = snap.exists && data?.welcomeEmailSent === true;
			let prevOwner: string | null = null;

			if (snap.exists && data?.userId && data.userId !== userId) {
				prevOwner = data.userId as string;
			}

			txn.set(
				existingRef,
				{
					...normalizedSubscriptionFields(
						{
							billingPeriod,
							environment: receiptEnvironment,
							expiresAt,
							plan: "pro",
							source: "app_store",
							subscriptionState,
							willAutoRenew,
						},
						Date.now(),
					),
					userId,
					productId: resolvedProductId,
					purchaseToken: originalTransactionId,
					originalTransactionId,
					billingPeriod,
					receiptData: receiptPayload,
					expiresAt,
					externalAccountVerified: true,
					lastVerifiedAt: FieldValue.serverTimestamp(),
					...(!weSent ? { welcomeEmailSent: true } : {}),
					...(!snap.exists ? { createdAt: FieldValue.serverTimestamp() } : {}),
					updatedAt: FieldValue.serverTimestamp(),
				},
				{ merge: true },
			);

			return {
				oldUserId: prevOwner,
				appStoreWelcomeEmailAlreadySent: weSent,
			};
		});

	// Recompute both owners from all providers; never clear an overlapping entitlement.
	if (legacyOldUserId) {
		console.log(
			`Transferring App Store subscription ${originalTransactionId} ` +
				`from user ${legacyOldUserId} to ${userId}`,
		);
		await reconcileUserEntitlement(legacyOldUserId);
	}

	await reconcileUserEntitlement(userId);

	console.log(
		`App Store: verified subscription for user ${userId}, product: ${resolvedProductId}`,
	);

	return {
		valid: true,
		sendWelcomeEmail: !appStoreWelcomeEmailAlreadySent,
		message: "Subscription verified and activated",
		subscription: requireVerifiedEntitlementPayload({
			plan: "pro",
			source: "app_store",
			billingPeriod,
			expiresAt: Timestamp.fromMillis(expiresMs),
			willAutoRenew,
			subscriptionState,
		}),
	};
}

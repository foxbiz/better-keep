import * as crypto from "node:crypto";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { google } from "googleapis";
import * as nodemailer from "nodemailer";
import {
	ANDROID_PACKAGE_NAME,
	IOS_PRODUCT_IDS,
	REVIEW_ACCOUNT_EMAIL,
	SUBSCRIPTION_PLANS,
	appStoreSharedSecret,
	auth,
	db,
	emailPassword,
	googlePlayCredentials,
	isEmulator,
} from "./config";

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
		if (plan === "pro" && expiresAt) {
			await auth.setCustomUserClaims(userId, {
				plan: "pro",
				planExpiresAt: expiresAt.getTime(),
			});
			console.log(
				`Set Pro claims for user ${userId}, expires ${expiresAt.toISOString()}`,
			);
		} else {
			// Clear claims for free users
			await auth.setCustomUserClaims(userId, {
				plan: "free",
				planExpiresAt: null,
			});
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
	transporter: nodemailer.Transporter,
	mailOptions: nodemailer.SendMailOptions,
): Promise<void> {
	if (isEmulator) {
		console.log("📧 [EMULATOR] Email would be sent:");
		console.log("  From:", mailOptions.from);
		console.log("  To:", mailOptions.to);
		console.log("  Subject:", mailOptions.subject);
		console.log(
			"  Text preview:",
			typeof mailOptions.text === "string"
				? `${mailOptions.text.substring(0, 200)}...`
				: "(HTML only)",
		);
		return;
	}
	await transporter.sendMail(mailOptions);
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
	const transporter = getEmailTransporter(emailPassword.value());
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

	await sendEmail(transporter, mailOptions);
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
	const playApi = await getPlayDeveloperApi(googlePlayCredentials.value());

	// Get subscription details from Google Play
	const response = await playApi.purchases.subscriptionsv2.get({
		packageName: ANDROID_PACKAGE_NAME,
		token: purchaseToken,
	});

	const subscription = response.data;
	console.log(
		"Google Play subscription response:",
		JSON.stringify(subscription),
	);

	if (!subscription) {
		return { valid: false, message: "Subscription not found" };
	}

	// Check subscription state
	const subscriptionState = subscription.subscriptionState;

	// Valid states: SUBSCRIPTION_STATE_ACTIVE, SUBSCRIPTION_STATE_IN_GRACE_PERIOD
	const validStates = [
		"SUBSCRIPTION_STATE_ACTIVE",
		"SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
	];

	if (!subscriptionState || !validStates.includes(subscriptionState)) {
		console.log(`Subscription state is ${subscriptionState}, not valid`);
		return {
			valid: false,
			message: `Subscription is not active (state: ${subscriptionState})`,
		};
	}

	// Extract line item details (base plan info)
	const lineItems = subscription.lineItems || [];
	let basePlanId = "pro-monthly"; // Default
	let expiryTimeMillis: number | undefined;

	for (const lineItem of lineItems) {
		if (lineItem.productId === productId) {
			basePlanId = lineItem.offerDetails?.basePlanId || "pro-monthly";
			expiryTimeMillis = lineItem.expiryTime
				? new Date(lineItem.expiryTime).getTime()
				: undefined;
			break;
		}
	}

	// Check if this subscription is already linked to another account
	const existingSubscription = await db
		.collection("subscriptions")
		.where("purchaseToken", "==", purchaseToken)
		.limit(1)
		.get();

	let welcomeEmailAlreadySent = false;
	if (!existingSubscription.empty) {
		const existingDoc = existingSubscription.docs[0];
		const existingData = existingDoc.data();
		welcomeEmailAlreadySent = existingData.welcomeEmailSent === true;

		if (existingData.userId !== userId) {
			// Allow review account to bypass duplicate check
			const userRecord = await auth.getUser(userId);
			if (userRecord.email !== REVIEW_ACCOUNT_EMAIL) {
				console.warn(
					`Subscription already linked to user ${existingData.userId}, ` +
						`attempted by ${userId}`,
				);
				throw new HttpsError(
					"already-exists",
					"This subscription is already linked to another account. " +
						"Please contact support at support@betterkeep.app if you believe this is an error.",
				);
			}
			console.log(`Bypassing duplicate check for review account ${userId}`);
		}
	}

	// Calculate expiry date
	const expiresAt = expiryTimeMillis
		? Timestamp.fromMillis(expiryTimeMillis)
		: Timestamp.fromMillis(
				Date.now() +
					(SUBSCRIPTION_PLANS[basePlanId]?.periodDays || 30) *
						24 *
						60 *
						60 *
						1000,
			);

	// Store subscription in subscriptions collection (for global lookup)
	await db
		.collection("subscriptions")
		.doc(purchaseToken)
		.set(
			{
				userId,
				productId,
				purchaseToken,
				basePlanId,
				source: "play_store",
				subscriptionState,
				expiresAt,
				linkedToken: subscription.linkedPurchaseToken || null,
				orderId: subscription.latestOrderId || null,
				startTime: subscription.startTime
					? Timestamp.fromDate(new Date(subscription.startTime))
					: null,
				// Set welcomeEmailSent only on first-time creation to prevent repeat welcome emails
				...(!welcomeEmailAlreadySent ? { welcomeEmailSent: true } : {}),
				createdAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);

	// Update user's subscription status
	await db
		.collection("users")
		.doc(userId)
		.collection("subscription")
		.doc("status")
		.set(
			{
				plan: "pro",
				billingPeriod: basePlanId === "pro-yearly" ? "yearly" : "monthly",
				expiresAt,
				willAutoRenew: subscriptionState === "SUBSCRIPTION_STATE_ACTIVE",
				purchaseToken,
				source: "play_store",
				basePlanId,
				verifiedAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);

	// Set custom claims for server-side subscription enforcement
	await setSubscriptionClaims(userId, "pro", expiresAt.toDate());

	console.log(
		`Successfully verified and linked subscription for user ${userId}`,
	);

	return {
		valid: true,
		sendWelcomeEmail: !welcomeEmailAlreadySent,
		message: "Subscription verified and activated",
		subscription: {
			plan: "pro",
			billingPeriod: basePlanId === "pro-yearly" ? "yearly" : "monthly",
			expiresAt: expiresAt.toDate().toISOString(),
		},
	};
}

/**
 * Send Razorpay subscription email (welcome, cancelled, resumed, renewal)
 */
export async function sendRazorpaySubscriptionEmail(
	userId: string,
	type: "welcome" | "cancelled" | "resumed" | "renewed" | "expired",
	expiryDate?: Date | null,
): Promise<void> {
	try {
		const userRecord = await auth.getUser(userId);
		const email = userRecord.email;

		if (!email) {
			console.warn(`No email found for user ${userId}`);
			return;
		}

		const transporter = getEmailTransporter(emailPassword.value());
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

		await sendEmail(transporter, {
			from: `"${senderName}" <${senderEmail}>`,
			to: email,
			subject: subject,
			html: htmlContent,
			text: `${heading}\n\n${message}\n\n${ctaText}: ${ctaUrl}\n\nBetter Keep Notes by Foxbiz Software Pvt. Ltd.`,
		});

		console.log(`Sent Razorpay ${type} email to ${email}`);
	} catch (error) {
		console.error(
			`Failed to send Razorpay subscription email to user ${userId}:`,
			error,
		);
	}
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
	// Debug: log key lengths to verify they're populated (not the actual keys)
	console.log(
		`Razorpay request: ${method} ${endpoint}, keyId length: ${keyId?.length}, keySecret length: ${keySecret?.length}`,
	);

	if (!keyId || !keySecret) {
		throw new Error("Razorpay credentials not configured");
	}

	const auth = Buffer.from(`${keyId}:${keySecret}`).toString("base64");

	const response = await fetch(`https://api.razorpay.com/v1${endpoint}`, {
		method,
		headers: {
			Authorization: `Basic ${auth}`,
			"Content-Type": "application/json",
		},
		body: body ? JSON.stringify(body) : undefined,
	});

	if (!response.ok) {
		const errorText = await response.text();
		console.error(`Razorpay API error: ${response.status} - ${errorText}`);
		throw new Error(`Razorpay API error: ${response.status}`);
	}

	return response.json();
}

/**
 * Verify an App Store subscription purchase using the receipt validation API.
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
	const sharedSecret = appStoreSharedSecret.value();
	if (!sharedSecret) {
		throw new HttpsError(
			"failed-precondition",
			"APP_STORE_SHARED_SECRET is not configured on the server",
		);
	}

	console.log(
		`App Store verify start: user=${userId}, product=${productId}, receiptLen=${receiptData.length}`,
	);

	const rawReceiptData = receiptData.trim();
	if (!rawReceiptData) {
		throw new HttpsError("invalid-argument", "receiptData is empty");
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

	let appleResponse = await callVerifyReceipt(
		"https://buy.itunes.apple.com/verifyReceipt",
	);

	let status = appleResponse.status as number;
	if (status === 21007) {
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

	const existingRef = db
		.collection("subscriptions")
		.doc(`ios_${originalTransactionId}`);
	const existingSnap = await existingRef.get();

	const appStoreWelcomeEmailAlreadySent =
		existingSnap.exists && existingSnap.data()?.welcomeEmailSent === true;

	if (existingSnap.exists) {
		const existingData = existingSnap.data();
		if (existingData?.userId && existingData.userId !== userId) {
			// Allow review account to bypass duplicate check
			const userRecord = await auth.getUser(userId);
			if (userRecord.email !== REVIEW_ACCOUNT_EMAIL) {
				console.warn(
					`App Store subscription ${originalTransactionId} already linked to ` +
						`user ${existingData.userId}, attempted by ${userId}`,
				);
				throw new HttpsError(
					"already-exists",
					"This subscription is already linked to another account. " +
						"Please contact support at support@betterkeep.app if you believe this is an error.",
				);
			}
			console.log(
				`Bypassing App Store duplicate check for review account ${userId}`,
			);
		}
	}

	await existingRef.set(
		{
			userId,
			productId: resolvedProductId,
			purchaseToken: originalTransactionId,
			originalTransactionId,
			billingPeriod,
			source: "app_store",
			subscriptionState,
			willAutoRenew,
			receiptData: receiptPayload,
			expiresAt,
			// Set welcomeEmailSent only on first-time creation to prevent repeat welcome emails
			...(!appStoreWelcomeEmailAlreadySent ? { welcomeEmailSent: true } : {}),
			createdAt: FieldValue.serverTimestamp(),
			updatedAt: FieldValue.serverTimestamp(),
		},
		{ merge: true },
	);

	await db
		.collection("users")
		.doc(userId)
		.collection("subscription")
		.doc("status")
		.set(
			{
				plan: "pro",
				billingPeriod,
				expiresAt,
				willAutoRenew,
				subscriptionState,
				purchaseToken: originalTransactionId,
				productId: resolvedProductId,
				source: "app_store",
				verifiedAt: FieldValue.serverTimestamp(),
				updatedAt: FieldValue.serverTimestamp(),
			},
			{ merge: true },
		);

	await setSubscriptionClaims(userId, "pro", expiresAt.toDate());

	console.log(
		`App Store: verified subscription for user ${userId}, product: ${resolvedProductId}`,
	);

	return {
		valid: true,
		sendWelcomeEmail: !appStoreWelcomeEmailAlreadySent,
		message: "Subscription verified and activated",
		subscription: {
			plan: "pro",
			billingPeriod,
			expiresAt: new Date(expiresMs).toISOString(),
		},
	};
}

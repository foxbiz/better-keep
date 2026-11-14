import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
	deletionDateLabel,
	isVerifiedDeletion,
	markDeletionReminderSent,
} from "../accountDeletionLifecycle";
import { auth, db, emailPassword } from "../config";
import { sendEmail } from "../utils";

/**
 * Scheduled function that runs daily at 8:00 AM UTC
 * Sends reminders for verified pending requests approaching their deadline.
 */
export default onSchedule(
	{
		schedule: "0 8 * * *", // Cron: every day at 8:00 AM UTC
		timeZone: "UTC",
		secrets: [emailPassword],
		retryCount: 3,
		maxInstances: 1,
		concurrency: 1,
		timeoutSeconds: 540,
	},
	async () => {
		if (process.env.ACCOUNT_DELETION_ENABLED !== "true") return;
		const now = Timestamp.now();

		console.log(
			`Processing deletion reminders at ${now.toDate().toISOString()}`,
		);

		// Query users whose reminder time has passed and haven't received reminder
		const snapshot = await db
			.collection("users")
			.where("scheduledDeletion.reminderAt", "<=", now)
			.where("scheduledDeletion.reminderSent", "==", false)
			.get();

		console.log(`Found ${snapshot.size} users to send reminders`);

		const results = {
			processed: 0,
			succeeded: 0,
			failed: 0,
		};

		const senderEmail = process.env.EMAIL_FROM;
		const senderName = process.env.EMAIL_NAME;

		for (const doc of snapshot.docs) {
			const userId = doc.id;
			// Fresh state prevents using a cancelled/rescheduled query snapshot.
			const current = await doc.ref.get();
			const userData = current.data();
			const schedule = userData?.scheduledDeletion;
			if (
				schedule?.version !== 2 ||
				schedule.state !== "pending" ||
				typeof schedule.requestId !== "string" ||
				schedule.reminderSent !== false ||
				!(schedule.reminderAt instanceof Timestamp) ||
				schedule.reminderAt.toMillis() > now.toMillis() ||
				!(schedule.deleteAt instanceof Timestamp) ||
				schedule.deleteAt.toMillis() <= now.toMillis()
			)
				continue;
			results.processed++;

			try {
				// Get user email
				const userRecord = await auth.getUser(userId).catch((error) => {
					if (error?.code === "auth/user-not-found") return null;
					throw error;
				});
				if (!userRecord) continue;
				const email = userRecord.email;

				if (!email) {
					console.log(`No email for user ${userId}, skipping reminder`);
					continue;
				}

				const deleteAt = schedule.deleteAt;

				const deleteDate = deletionDateLabel(deleteAt);

				const mailOptions = {
					from: `"${senderName}" <${senderEmail}>`,
					to: email,
					subject: "⚠️ Reminder: Scheduled Account Deletion - Better Keep Notes",
					html: `
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
            </head>
            <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 20px;">
              <div style="max-width: 480px; margin: 0 auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
                <div style="background: #d32f2f; color: white; padding: 16px; border-radius: 8px; text-align: center; margin-bottom: 24px;">
                  <h1 style="margin: 0; font-size: 24px;">⚠️ Account Deletion Reminder</h1>
                </div>
                <p style="color: #333; font-size: 16px; line-height: 1.5;">
                  Your Better Keep Notes account is scheduled for <strong>permanent deletion</strong>.
                </p>
                <div style="background: #ffebee; border-radius: 8px; padding: 16px; margin: 24px 0; border: 2px solid #d32f2f;">
                  <p style="color: #c62828; font-size: 16px; margin: 0; font-weight: bold; text-align: center;">
                    Eligible for deletion from: ${deleteDate}
                  </p>
                </div>
                <h2 style="color: #333; font-size: 18px; margin-top: 24px;">What will be deleted:</h2>
                <ul style="color: #666; font-size: 14px; line-height: 1.8; padding-left: 20px;">
                  <li>All your notes and their contents</li>
                  <li>All attachments and media files</li>
                  <li>All labels and organization data</li>
                  <li>Your account and login credentials</li>
                </ul>
                <div style="background: #e3f2fd; border-radius: 8px; padding: 20px; margin: 24px 0; text-align: center;">
                  <h2 style="color: #1565c0; font-size: 18px; margin-top: 0;">Want to keep your account?</h2>
                  <p style="color: #1976d2; font-size: 14px; margin-bottom: 0;">
                    Simply <strong>sign in to the Better Keep app</strong> before the date above to cancel pending deletion.
                  </p>
                </div>
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
          `,
					text: `
ACCOUNT DELETION REMINDER

Your Better Keep Notes account is scheduled for permanent deletion.

Eligible for deletion from: ${deleteDate}

What will be deleted:
- All your notes and their contents
- All attachments and media files
- All labels and organization data
- Your account and login credentials

Want to keep your account?
Simply sign in to the Better Keep app before the date above to cancel pending deletion.

This is an automated reminder. If you did not schedule this deletion, please sign in immediately or contact support.
          `,
				};

				const latest = (await doc.ref.get()).data()?.scheduledDeletion;
				if (
					latest?.requestId !== schedule.requestId ||
					latest.state !== "pending" ||
					latest.reminderSent
				)
					continue;
				const proof = /^[a-f0-9-]{36}$/.test(schedule.requestId)
					? (
							await db
								.collection("accountDeletionRequests")
								.doc(schedule.requestId)
								.get()
						).data()
					: undefined;
				if (!isVerifiedDeletion(latest, proof, userId)) {
					console.warn("Holding reminder without valid deletion proof", {
						userId,
					});
					continue;
				}
				// SMTP cannot transact with Firestore: cancellation during send can still
				// deliver a stale email, but completion must never recreate the request.
				await sendEmail(mailOptions);

				// Mark reminder as sent
				await markDeletionReminderSent(db, userId, schedule.requestId);

				results.succeeded++;
				console.log(`✓ Sent reminder to user: ${userId}`);
			} catch (error) {
				results.failed++;
				console.error(`✗ Failed to send reminder to ${userId}: ${error}`);
			}
		}

		console.log(
			`Reminders complete: ${results.succeeded}/${results.processed} succeeded, ` +
				`${results.failed} failed`,
		);
		if (results.failed > 0)
			throw new Error(`${results.failed} deletion reminder(s) failed`);
	},
);

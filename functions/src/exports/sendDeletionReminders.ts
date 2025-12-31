import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { auth, db, emailPassword } from "../config";
import { getEmailTransporter, sendEmail } from "../utils";

/**
 * Scheduled function that runs daily at 8:00 AM UTC
 * Sends reminder emails to users whose accounts will be deleted tomorrow.
 */
export default onSchedule(
	{
		schedule: "0 8 * * *", // Cron: every day at 8:00 AM UTC
		timeZone: "UTC",
		secrets: [emailPassword],
	},
	async () => {
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

		for (const doc of snapshot.docs) {
			const userId = doc.id;
			const userData = doc.data();
			results.processed++;

			try {
				// Get user email
				const userRecord = await auth.getUser(userId);
				const email = userRecord.email;

				if (!email) {
					console.log(`No email for user ${userId}, skipping reminder`);
					continue;
				}

				const deleteAt = userData.scheduledDeletion?.deleteAt;
				if (!deleteAt) continue;

				const deleteDate = deleteAt.toDate().toLocaleDateString("en-US", {
					weekday: "long",
					year: "numeric",
					month: "long",
					day: "numeric",
				});

				const transporter = getEmailTransporter(emailPassword.value());
				const senderEmail = process.env.EMAIL_FROM;
				const senderName = process.env.EMAIL_NAME;

				const mailOptions = {
					from: `"${senderName}" <${senderEmail}>`,
					to: email,
					subject:
						"⚠️ Final Reminder: Account Deletion Tomorrow - Better Keep Notes",
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
                  <h1 style="margin: 0; font-size: 24px;">⚠️ Final Reminder</h1>
                </div>
                <p style="color: #333; font-size: 16px; line-height: 1.5;">
                  Your Better Keep Notes account will be <strong>permanently deleted tomorrow</strong>.
                </p>
                <div style="background: #ffebee; border-radius: 8px; padding: 16px; margin: 24px 0; border: 2px solid #d32f2f;">
                  <p style="color: #c62828; font-size: 16px; margin: 0; font-weight: bold; text-align: center;">
                    Deletion Date: ${deleteDate}
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
                    Simply <strong>sign in to the Better Keep app</strong> before tomorrow and your account will be restored.
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
⚠️ FINAL REMINDER - Account Deletion Tomorrow

Your Better Keep Notes account will be permanently deleted tomorrow.

Deletion Date: ${deleteDate}

What will be deleted:
- All your notes and their contents
- All attachments and media files
- All labels and organization data
- Your account and login credentials

Want to keep your account?
Simply sign in to the Better Keep app before tomorrow and your account will be restored.

This is an automated reminder. If you did not schedule this deletion, please sign in immediately or contact support.
          `,
				};

				await sendEmail(transporter, mailOptions);

				// Mark reminder as sent
				await doc.ref.update({
					"scheduledDeletion.reminderSent": true,
				});

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
	},
);

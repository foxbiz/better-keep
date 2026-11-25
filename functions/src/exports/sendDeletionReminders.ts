import { Timestamp } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import {
	deletionDateLabel,
	isVerifiedDeletion,
	markDeletionReminderSent,
} from "../accountDeletionLifecycle";
import { auth, db, emailPassword } from "../config";
import { generateTransactionalEmail } from "../email_templates";
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
					subject: "Reminder: Scheduled Account Deletion - Better Keep Notes",
					...generateTransactionalEmail({
						title: "Your account is scheduled for deletion",
						category: "Account reminder",
						tone: "danger",
						paragraphs: [
							"This is a reminder that your Better Keep Notes account is scheduled for permanent deletion.",
						],
						details: [
							{ label: "Eligible for deletion from", value: deleteDate },
						],
						list: {
							title: "What will be deleted",
							items: [
								"All your notes and their contents",
								"All attachments and media files",
								"All labels and organization data",
								"Your account and login credentials",
							],
						},
						notice: {
							title: "To keep your account",
							text: `Sign in to Better Keep before ${deleteDate} to cancel pending deletion. If you did not schedule this deletion, sign in immediately or contact support.`,
						},
					}),
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

import { FieldValue } from "firebase-admin/firestore";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { auth, databaseId, db, emailPassword } from "../config";
import { sendEmail } from "../utils";

// Sign-in hooks cancel before the client runs. Observe the durable lifecycle
// transition so notification does not depend on a second client cancellation.
export default onDocumentUpdated(
	{
		document: "accountDeletionRequests/{requestId}",
		database: databaseId,
		secrets: [emailPassword],
		maxInstances: 1,
		concurrency: 1,
		retry: true,
	},
	async (event) => {
		if (
			event.data?.before.data().state !== "pending" ||
			event.data.after.data().state !== "cancelled"
		)
			return;
		const ref = db
			.collection("accountDeletionRequests")
			.doc(event.params.requestId);
		const record = (await ref.get()).data();
		if (
			record?.state !== "cancelled" ||
			record.cancellationEmailSentAt ||
			record.cancellationEmailSkippedAt ||
			typeof record.uid !== "string"
		)
			return;
		const user = await auth.getUser(record.uid).catch((error) => {
			if (error?.code === "auth/user-not-found") return null;
			throw error;
		});
		if (!user?.email) {
			await ref.update({
				cancellationEmailSkippedAt: FieldValue.serverTimestamp(),
				cancellationEmailSkippedReason: user ? "no-email" : "user-not-found",
			});
			return;
		}
		await sendEmail({
			from: `"${process.env.EMAIL_NAME}" <${process.env.EMAIL_FROM}>`,
			to: user.email,
			subject: "Account deletion request cancelled - Better Keep Notes",
			text: "Signing in cancelled your previous account deletion request. That request will not delete your account. If you did not sign in, secure your account and contact support@betterkeep.app.",
		});
		// SMTP is not transactional. A crash after delivery can repeat the notice;
		// successful delivery markers suppress subsequent event retries.
		await ref.update({ cancellationEmailSentAt: FieldValue.serverTimestamp() });
	},
);

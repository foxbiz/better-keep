import { db } from "../config";
import { stampLegacySyncDocument } from "../legacySyncStamp";
import { onNonReviewCall } from "../nonReviewCallable";

export default onNonReviewCall<{ kind?: unknown; entityId?: unknown }>(
	(request) => stampLegacySyncDocument(db, request.auth?.uid, request.data),
);

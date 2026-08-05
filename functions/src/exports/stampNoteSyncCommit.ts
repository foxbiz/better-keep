import { createSyncCommitStampTrigger } from "../syncCommitStamp";

export default createSyncCommitStampTrigger(
	"users/{userId}/notes/{noteId}",
);

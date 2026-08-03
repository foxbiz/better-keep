import { createSyncCommitStampTrigger } from "../syncCommitStamp";

export default createSyncCommitStampTrigger(
	"users/{userId}/labels/{labelId}",
);

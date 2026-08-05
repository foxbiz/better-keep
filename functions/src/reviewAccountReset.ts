export interface ReviewResetIdentity {
	uid: string;
	providerIds: readonly string[];
}

interface ReviewAccountResetOperations<TCleanup> {
	existingIdentity: ReviewResetIdentity | null;
	revokeSessions(uid: string): Promise<void>;
	disableIdentity(uid: string): Promise<ReviewResetIdentity>;
	createDisabledIdentity(): Promise<ReviewResetIdentity>;
	cleanup(identity: ReviewResetIdentity): Promise<TCleanup>;
	resetAuthentication(identity: ReviewResetIdentity): Promise<void>;
	restoreEntitlement(uid: string): Promise<void>;
	restoreClaims(uid: string): Promise<void>;
	enableIdentity(uid: string): Promise<void>;
}

export interface ReviewAccountResetResult<TCleanup> {
	uid: string;
	cleanup: TCleanup;
}

/**
 * Executes the destructive review-account sequence with enablement as the
 * final operation. A failure at any earlier point therefore leaves the
 * identity disabled, and every operation is safe to run again.
 */
export async function executeReviewAccountReset<TCleanup>({
	existingIdentity,
	revokeSessions,
	disableIdentity,
	createDisabledIdentity,
	cleanup,
	resetAuthentication,
	restoreEntitlement,
	restoreClaims,
	enableIdentity,
}: ReviewAccountResetOperations<TCleanup>): Promise<
	ReviewAccountResetResult<TCleanup>
> {
	let identity: ReviewResetIdentity;
	if (existingIdentity) {
		identity = await disableIdentity(existingIdentity.uid);
		await revokeSessions(existingIdentity.uid);
	} else {
		identity = await createDisabledIdentity();
	}

	const cleanupResult = await cleanup(identity);
	await resetAuthentication(identity);
	await restoreEntitlement(identity.uid);
	await restoreClaims(identity.uid);
	await enableIdentity(identity.uid);
	return { uid: identity.uid, cleanup: cleanupResult };
}

export async function forEachBounded<T>(
	values: readonly T[],
	limit: number,
	operation: (value: T, index: number) => Promise<void>,
): Promise<void> {
	if (!Number.isInteger(limit) || limit < 1) {
		throw new Error("Concurrency limit must be a positive integer");
	}
	let nextIndex = 0;
	const worker = async (): Promise<void> => {
		while (nextIndex < values.length) {
			const index = nextIndex;
			nextIndex += 1;
			await operation(values[index], index);
		}
	};
	await Promise.all(
		Array.from({ length: Math.min(limit, values.length) }, () => worker()),
	);
}

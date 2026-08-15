import { parse } from "csv-parse/sync";
import { unzipSync } from "fflate";
import { google } from "googleapis";
import { ANDROID_PACKAGE_NAME, googlePlayCredentials } from "./config";
import { decimalToMicros } from "./revenueLedger";
import { enqueueRevenueEvent } from "./revenueOutbox";

export interface GooglePlaySalesRow {
	"Base Plan or Purchase Option ID"?: string;
	"Charged Amount"?: string;
	"Currency of Sale"?: string;
	"Financial Status"?: string;
	"Offer ID"?: string;
	"Order Charged Timestamp"?: string;
	"Order Number"?: string;
	"Package ID"?: string;
	"Product Type"?: string;
	"SKU ID"?: string;
	[key: string]: string | undefined;
}

export interface ParsedGooglePlayRevenue {
	amountMicros: number;
	currency: string;
	kind: "charge" | "refund";
	occurredAt: Date;
	providerTransactionId: string;
	metadata: Record<string, unknown>;
}

export function isGooglePlaySubscriptionSalesRow(
	row: GooglePlaySalesRow,
): boolean {
	return (
		row["Package ID"] === ANDROID_PACKAGE_NAME &&
		(row["Product Type"] ?? "").trim().toLowerCase() === "subscription"
	);
}

export function normalizeGooglePlayReportBucket(value: string): string {
	const bucket = value
		.trim()
		.replace(/^gs:\/\//, "")
		.replace(/\/(?:sales|earnings)\/?$/, "")
		.replace(/\/$/, "");
	if (!/^pubsite_prod_(?:rev_)?[a-zA-Z0-9._-]+$/.test(bucket)) {
		throw new Error("Invalid Google Play report bucket");
	}
	return bucket;
}

export function parseGooglePlayRevenueRow(
	row: GooglePlaySalesRow,
): ParsedGooglePlayRevenue | null {
	if (!isGooglePlaySubscriptionSalesRow(row)) return null;

	const status = (row["Financial Status"] ?? "").trim().toLowerCase();
	const partialRefund = status.includes("partial refund");
	const kind = status.includes("refund")
		? "refund"
		: status.includes("charg")
			? "charge"
			: null;
	if (!kind) return null;

	const orderNumber = row["Order Number"]?.trim();
	const currency = row["Currency of Sale"]?.trim().toUpperCase();
	const amount = row["Charged Amount"]?.trim().replace(/^-/, "");
	const timestampSeconds = Number(row["Order Charged Timestamp"]);
	if (
		!orderNumber ||
		!currency ||
		!amount ||
		!Number.isFinite(timestampSeconds)
	) {
		return null;
	}

	const amountMicros = decimalToMicros(amount);
	return {
		providerTransactionId:
			kind === "charge"
				? `${orderNumber}:charge`
				: partialRefund
					? `${orderNumber}:refund:partial:${timestampSeconds}:${amountMicros}`
					: `${orderNumber}:refund:full`,
		amountMicros,
		currency,
		kind,
		occurredAt: new Date(timestampSeconds * 1000),
		metadata: {
			orderNumber,
			skuId: row["SKU ID"] ?? null,
			basePlanId: row["Base Plan or Purchase Option ID"] ?? null,
			offerId: row["Offer ID"] ?? null,
			financialStatus: row["Financial Status"] ?? null,
		},
	};
}

function decodeReport(buffer: Buffer): string {
	if (buffer[0] === 0xff && buffer[1] === 0xfe) {
		return new TextDecoder("utf-16le").decode(buffer.subarray(2));
	}
	const zeroBytes = buffer
		.subarray(0, 100)
		.filter((value) => value === 0).length;
	if (zeroBytes > 10) return new TextDecoder("utf-16le").decode(buffer);
	return buffer.toString("utf8").replace(/^\uFEFF/, "");
}

export function parseGooglePlaySalesArchive(
	buffer: Buffer,
): GooglePlaySalesRow[] {
	const entries = unzipSync(new Uint8Array(buffer));
	const entry = Object.entries(entries).find(([name]) => name.endsWith(".csv"));
	if (!entry)
		throw new Error("Google Play sales archive contains no CSV report");
	return parse(decodeReport(Buffer.from(entry[1])), {
		columns: true,
		skip_empty_lines: true,
		relax_column_count: true,
		trim: true,
	}) as GooglePlaySalesRow[];
}

function reportMonth(date: Date): string {
	return `${date.getUTCFullYear()}${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

function reportingMonths(now = new Date()): string[] {
	const previous = new Date(
		Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, 1),
	);
	return [reportMonth(now), reportMonth(previous)];
}

interface GoogleMoney {
	currencyCode?: string | null;
	nanos?: number | null;
	units?: string | number | null;
}

export interface GooglePlayOrder {
	createTime?: string | null;
	orderHistory?: {
		partialRefundEvents?: Array<{
			processTime?: string | null;
			state?: string | null;
			refundDetails?: { total?: GoogleMoney | null } | null;
		}> | null;
		processedEvent?: { eventTime?: string | null } | null;
		refundEvent?: {
			eventTime?: string | null;
			refundDetails?: { total?: GoogleMoney | null } | null;
		} | null;
	} | null;
	orderId?: string | null;
	purchaseToken?: string | null;
	total?: GoogleMoney | null;
}

export interface EnqueuedGooglePlayRevenueItem {
	amountMicros: number;
	currency: string;
	eventId: string;
	kind: "charge" | "refund";
	occurredAt: Date;
}

export interface EnqueuedGooglePlayOrder {
	charge: EnqueuedGooglePlayRevenueItem | null;
	refunds: EnqueuedGooglePlayRevenueItem[];
}

export interface GooglePlayOrderRevenueItem {
	amountMicros: number;
	currency: string;
	kind: "charge" | "refund";
	occurredAt: Date;
	providerTransactionId: string;
}

export interface ParsedGooglePlayOrderRevenue {
	charge: GooglePlayOrderRevenueItem | null;
	refunds: GooglePlayOrderRevenueItem[];
}

function moneyToMicros(money: GoogleMoney | null | undefined): {
	amountMicros: number;
	currency: string;
} | null {
	if (!money?.currencyCode) return null;
	const units = Number(money.units ?? 0);
	const nanos = Number(money.nanos ?? 0);
	const amountMicros = units * 1_000_000 + Math.round(nanos / 1000);
	if (!Number.isSafeInteger(amountMicros) || amountMicros < 0) return null;
	return { amountMicros, currency: money.currencyCode.toUpperCase() };
}

function validEventDate(value: string | null | undefined): Date | null {
	if (!value) return null;
	const date = new Date(value);
	return Number.isNaN(date.getTime()) ? null : date;
}

async function googlePlayAuth() {
	const credentials = JSON.parse(googlePlayCredentials.value());
	return new google.auth.GoogleAuth({
		credentials,
		scopes: [
			"https://www.googleapis.com/auth/androidpublisher",
			"https://www.googleapis.com/auth/devstorage.read_only",
		],
	});
}

export async function getGooglePlayOrder(
	orderId: string,
): Promise<GooglePlayOrder> {
	const auth = await googlePlayAuth();
	const client = await auth.getClient();
	const response = await client.request<GooglePlayOrder>({
		url:
			"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" +
			`${encodeURIComponent(ANDROID_PACKAGE_NAME)}/orders/${encodeURIComponent(orderId)}`,
	});
	return response.data;
}

export async function syncGooglePlayOrderById(
	orderId: string,
	userId: string | null = null,
): Promise<EnqueuedGooglePlayOrder> {
	const order = await getGooglePlayOrder(orderId);
	return enqueueVerifiedGooglePlayOrder(orderId, order, userId);
}

export function googlePlayOrderRevenueItems(
	orderId: string,
	order: GooglePlayOrder,
): ParsedGooglePlayOrderRevenue {
	const resolvedOrderId = order.orderId ?? orderId;
	const chargeMoney = moneyToMicros(order.total);
	const chargedAt = validEventDate(
		order.orderHistory?.processedEvent?.eventTime ?? order.createTime,
	);
	const charge =
		chargeMoney && chargedAt
			? {
					...chargeMoney,
					kind: "charge" as const,
					occurredAt: chargedAt,
					providerTransactionId: `${resolvedOrderId}:charge`,
				}
			: null;
	const refunds: GooglePlayOrderRevenueItem[] = [];

	const fullRefund = order.orderHistory?.refundEvent;
	const fullRefundMoney = moneyToMicros(fullRefund?.refundDetails?.total);
	const fullRefundAt = validEventDate(fullRefund?.eventTime);
	if (fullRefundMoney && fullRefundAt) {
		refunds.push({
			...fullRefundMoney,
			kind: "refund",
			occurredAt: fullRefundAt,
			providerTransactionId: `${resolvedOrderId}:refund:full`,
		});
	}

	for (const partial of order.orderHistory?.partialRefundEvents ?? []) {
		if (partial.state !== "PROCESSED_SUCCESSFULLY") continue;
		const refund = moneyToMicros(partial.refundDetails?.total);
		const refundedAt = validEventDate(partial.processTime);
		if (!refund || !refundedAt) continue;
		refunds.push({
			...refund,
			kind: "refund",
			occurredAt: refundedAt,
			providerTransactionId:
				`${resolvedOrderId}:refund:partial:` +
				`${Math.floor(refundedAt.getTime() / 1000)}:${refund.amountMicros}`,
		});
	}
	return { charge, refunds };
}

export async function enqueueVerifiedGooglePlayOrder(
	orderId: string,
	order: GooglePlayOrder,
	userId: string | null = null,
): Promise<EnqueuedGooglePlayOrder> {
	const resolvedOrderId = order.orderId ?? orderId;
	const parsed = googlePlayOrderRevenueItems(orderId, order);
	const enqueue = async (
		item: GooglePlayOrderRevenueItem,
	): Promise<EnqueuedGooglePlayRevenueItem> => {
		const eventId = await enqueueRevenueEvent({
			provider: "play_store",
			providerTransactionId: item.providerTransactionId,
			userId,
			amountMicros: item.amountMicros,
			currency: item.currency,
			kind: item.kind,
			environment: "production",
			occurredAt: item.occurredAt,
			metadata: { orderNumber: resolvedOrderId, source: "orders_api" },
		});
		return {
			amountMicros: item.amountMicros,
			currency: item.currency,
			eventId,
			kind: item.kind,
			occurredAt: item.occurredAt,
		};
	};
	return {
		charge: parsed.charge ? await enqueue(parsed.charge) : null,
		refunds: await Promise.all(parsed.refunds.map(enqueue)),
	};
}

async function downloadReport(
	bucket: string,
	month: string,
): Promise<Buffer | null> {
	const authClient = await googlePlayAuth();
	const token = await authClient.getAccessToken();
	const objectName = `sales/salesreport_${month}.zip`;
	const response = await fetch(
		`https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o/${encodeURIComponent(objectName)}?alt=media`,
		{ headers: { Authorization: `Bearer ${token}` } },
	);
	if (response.status === 404) return null;
	if (!response.ok) {
		throw new Error(`Google Play report download failed (${response.status})`);
	}
	return Buffer.from(await response.arrayBuffer());
}

export async function listGooglePlaySalesReports(
	bucket: string,
): Promise<string[]> {
	const authClient = await googlePlayAuth();
	const token = await authClient.getAccessToken();
	const names: string[] = [];
	let pageToken: string | undefined;
	do {
		const url = new URL(
			`https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o`,
		);
		url.searchParams.set("prefix", "sales/salesreport_");
		url.searchParams.set("fields", "items/name,nextPageToken");
		if (pageToken) url.searchParams.set("pageToken", pageToken);
		const response = await fetch(url, {
			headers: { Authorization: `Bearer ${token}` },
		});
		if (!response.ok) {
			throw new Error(`Google Play report listing failed (${response.status})`);
		}
		const data = (await response.json()) as {
			items?: Array<{ name?: string }>;
			nextPageToken?: string;
		};
		for (const item of data.items ?? []) {
			if (item.name?.endsWith(".zip")) names.push(item.name);
		}
		pageToken = data.nextPageToken;
	} while (pageToken);
	return names.sort();
}

async function downloadReportObject(
	bucket: string,
	objectName: string,
): Promise<Buffer> {
	const authClient = await googlePlayAuth();
	const token = await authClient.getAccessToken();
	const response = await fetch(
		`https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o/${encodeURIComponent(objectName)}?alt=media`,
		{ headers: { Authorization: `Bearer ${token}` } },
	);
	if (!response.ok) {
		throw new Error(`Google Play report download failed (${response.status})`);
	}
	return Buffer.from(await response.arrayBuffer());
}

export async function readGooglePlaySalesReport(
	bucket: string,
	objectName: string,
): Promise<GooglePlaySalesRow[]> {
	return parseGooglePlaySalesArchive(
		await downloadReportObject(bucket, objectName),
	);
}

export async function syncGooglePlayRevenueReports({
	allHistory = false,
	bucket,
	now = new Date(),
}: {
	allHistory?: boolean;
	bucket: string;
	now?: Date;
}): Promise<{ imported: number; reports: number }> {
	bucket = normalizeGooglePlayReportBucket(bucket);
	let imported = 0;
	let reports = 0;
	const reportObjects = allHistory
		? await listGooglePlaySalesReports(bucket)
		: reportingMonths(now).map((month) => `sales/salesreport_${month}.zip`);
	for (const objectName of reportObjects) {
		const archive = allHistory
			? await downloadReportObject(bucket, objectName)
			: await downloadReport(
					bucket,
					objectName.match(/salesreport_(\d{6})\.zip$/)?.[1] ?? "",
				);
		if (!archive) continue;
		reports += 1;
		for (const row of parseGooglePlaySalesArchive(archive)) {
			const revenue = parseGooglePlayRevenueRow(row);
			if (!revenue) continue;
			await enqueueRevenueEvent({
				provider: "play_store",
				userId: null,
				environment: "production",
				...revenue,
			});
			imported += 1;
		}
	}
	return { imported, reports };
}

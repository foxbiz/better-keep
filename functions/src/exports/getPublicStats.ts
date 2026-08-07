import { onRequest } from "firebase-functions/v2/https";
import { db } from "../config";
import {
	createPublicStatsPayload,
	isPublicStatsOriginAllowed,
} from "../publicStats";

/**
 * HTTP endpoint for public statistics.
 * Returns shields.io-compatible JSON format for badge rendering.
 *
 * Rate limiting protection:
 * 1. Aggressive Cache-Control headers (6 hours) - browsers/CDNs serve cached responses
 * 2. Origin restrictions - only allowed domains can fetch
 * 3. maxInstances limit - caps concurrent invocations to prevent cost spikes
 *
 * Usage in README:
 * ![Users](https://img.shields.io/endpoint?url=https://<region>-<project>.cloudfunctions.net/getPublicStats)
 */
export default onRequest(
	{
		maxInstances: 2, // Limit concurrent instances to prevent cost spikes
		timeoutSeconds: 10, // Quick timeout since this is a simple read
	},
	async (req, res) => {
		// Only allow GET requests
		if (req.method !== "GET") {
			res.status(405).json({ error: "Method not allowed" });
			return;
		}

		// Check origin for CORS (allow requests without origin for shields.io)
		const origin = req.headers.origin;
		if (origin) {
			if (isPublicStatsOriginAllowed(origin)) {
				res.set("Access-Control-Allow-Origin", origin);
			} else {
				// Block requests from unknown origins
				res.status(403).json({ error: "Origin not allowed" });
				return;
			}
		}

		// Set aggressive caching headers (6 hours = 21600 seconds)
		// This means browsers and CDNs will serve cached responses instead of hitting the function
		res.set("Cache-Control", "public, max-age=21600, s-maxage=21600");
		res.set("Vary", "Origin");

		try {
			const doc = await db.collection("stats").doc("public").get();
			const data = doc.data();

			if (!data) {
				// Return default if stats haven't been generated yet
				res.json(createPublicStatsPayload("0"));
				return;
			}

			// Return shields.io-compatible JSON
			// See: https://shields.io/endpoint
			res.json(createPublicStatsPayload(data.userCount || "0"));
		} catch (error) {
			console.error("Failed to get public stats:", error);
			res.status(500).json(createPublicStatsPayload("error", "red"));
		}
	},
);

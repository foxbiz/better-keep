#!/usr/bin/env node
// Read-only snapshot of the live app. No Firestore/Auth account data is accessed.
import path from "node:path";
import { snapshotHosting } from "./hosting_live.mjs";
await snapshotHosting(
	path.resolve(process.argv[2] || "build/stable-hosting-snapshot"),
	{ appOnly: true },
);

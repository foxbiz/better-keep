import * as crypto from "node:crypto";
import { compactVerify, decodeProtectedHeader, importX509 } from "jose";

type JwtPayload = Record<string, unknown>;

// Apple Root CA - G3 (downloaded from https://www.apple.com/certificateauthority/)
// Expires: 2039-04-30. ECDSA P-384 root used by App Store Server Notifications V2.
const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

function derToPem(base64Der: string): string {
	const lines: string[] = [];
	for (let i = 0; i < base64Der.length; i += 64) {
		lines.push(base64Der.substring(i, i + 64));
	}
	return `-----BEGIN CERTIFICATE-----\n${lines.join("\n")}\n-----END CERTIFICATE-----`;
}

/**
 * Validate that the x5c certificate chain is rooted in Apple Root CA G3.
 * Chain order per JWS spec: [leaf, intermediate, ..., root].
 * Each cert must be issued by the next cert in the chain, and the last
 * cert must be issued by (or be) the Apple Root CA G3.
 */
function validateCertificateChain(x5cPems: string[]): void {
	const rootCert = new crypto.X509Certificate(APPLE_ROOT_CA_G3_PEM);

	// Walk the chain from leaf → root, verifying each cert is signed by the next.
	for (let i = 0; i < x5cPems.length - 1; i++) {
		const child = new crypto.X509Certificate(x5cPems[i]);
		const parent = new crypto.X509Certificate(x5cPems[i + 1]);
		if (!child.checkIssued(parent)) {
			throw new Error(
				`Certificate chain broken at index ${i}: cert not issued by next cert in chain`,
			);
		}
	}

	// The last cert in x5c must be issued by the Apple Root CA G3.
	const lastCert = new crypto.X509Certificate(x5cPems[x5cPems.length - 1]);
	if (!lastCert.checkIssued(rootCert)) {
		throw new Error("Certificate chain not rooted in Apple Root CA G3");
	}

	// Verify the root CA fingerprint matches the expected Apple Root CA G3.
	// This prevents an attacker from crafting a chain with a different root.
	const expectedFingerprint = new crypto.X509Certificate(APPLE_ROOT_CA_G3_PEM)
		.fingerprint256;
	if (rootCert.fingerprint256 !== expectedFingerprint) {
		throw new Error("Root CA fingerprint mismatch");
	}
}

/**
 * Verify an Apple-signed JWS (compact serialization) and return the decoded payload.
 *
 * 1. Extracts the x5c certificate chain from the JWS protected header.
 * 2. Validates the chain is rooted in Apple Root CA G3.
 * 3. Verifies the JWS signature using the leaf certificate's public key.
 * 4. Returns the parsed JSON payload.
 */
export async function verifyAppleJws(jws: string): Promise<JwtPayload> {
	const header = decodeProtectedHeader(jws);

	if (header.alg !== "ES256") {
		throw new Error(`Unexpected JWS algorithm: ${header.alg}`);
	}

	const x5c = header.x5c;
	if (!Array.isArray(x5c) || x5c.length === 0) {
		throw new Error("Missing x5c certificate chain in JWS header");
	}

	// Convert x5c entries (base64 DER) to PEM
	const x5cPems = x5c.map(derToPem);

	// Validate chain is rooted in Apple Root CA G3
	validateCertificateChain(x5cPems);

	// Import leaf certificate's public key for signature verification
	const leafPem = x5cPems[0];
	const publicKey = await importX509(leafPem, "ES256");

	// Verify the JWS signature
	const { payload } = await compactVerify(jws, publicKey);

	// Decode payload to JSON
	const payloadText = new TextDecoder().decode(payload);
	return JSON.parse(payloadText) as JwtPayload;
}

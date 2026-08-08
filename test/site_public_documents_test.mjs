import assert from "node:assert/strict";
import {readFile, readdir} from "node:fs/promises";
import path from "node:path";
import test from "node:test";

const repositoryRoot = process.cwd();
const webRoot = path.join(repositoryRoot, "web");
const siteRoot = path.join(repositoryRoot, "site", "src");

const documents = [
	["privacy", "PrivacyContent.astro", 11],
	["terms", "TermsContent.astro", 18],
	["pricing", "PricingContent.astro", 4],
	["contact", "ContactContent.astro", 1],
	["cancellation-refund", "CancellationRefundContent.astro", 5],
	["delete-user", "DeleteUserContent.astro", 12],
];

async function collectHtml(directory, prefix = "") {
	const entries = await readdir(directory, {withFileTypes: true});
	const files = [];
	for (const entry of entries) {
		const relative = path.join(prefix, entry.name);
		if (entry.isDirectory()) {
			files.push(...(await collectHtml(path.join(directory, entry.name), relative)));
		} else if (entry.name.endsWith(".html")) {
			files.push(relative);
		}
	}
	return files;
}

test("web keeps only the four operational HTML entry points", async () => {
	assert.deepEqual((await collectHtml(webRoot)).sort(), [
		"auth.html",
		"desktop-checkout.html",
		"index.html",
		"reset-password.html",
	]);

	const shareRoute = await readFile(
		path.join(siteRoot, "pages", "s", "index", "index.astro"),
		"utf8",
	);
	assert.match(shareRoute, /ShareLayout/);
	assert.match(shareRoute, /ShareViewer/);
});

test("public documents are native Astro components", async () => {
	const metadata = await readFile(
		path.join(siteRoot, "data", "public-documents.ts"),
		"utf8",
	);
	const layout = await readFile(
		path.join(siteRoot, "components", "PublicDocumentPage.astro"),
		"utf8",
	);

	assert.doesNotMatch(metadata, /node:fs|sourceFile|sanitizeLegacyContent|readPublicDocumentContent/);
	assert.match(layout, /<slot\s*\/>/);
	assert.doesNotMatch(layout, /set:html|readPublicDocumentContent/);

	for (const [slug, componentName, sectionCount] of documents) {
		const route = await readFile(
			path.join(siteRoot, "pages", `${slug}.astro`),
			"utf8",
		);
		const content = await readFile(
			path.join(siteRoot, "components", "documents", componentName),
			"utf8",
		);

		assert.ok(route.includes(componentName), `${slug} does not import its native content`);
		assert.equal(
			(content.match(/<section\b/g) || []).length,
			sectionCount,
			`${slug} has an unexpected section count`,
		);
		assert.doesNotMatch(content, /<script\b|<style\b|\sstyle=|<svg\b/);
		assert.doesNotMatch(content, /href=["'][^"']*\.html(?:[?#"'])/);
	}
});

test("specialized document structures and links remain present", async () => {
	const readDocument = (name) =>
		readFile(path.join(siteRoot, "components", "documents", name), "utf8");
	const [pricing, contact, refund, deletion] = await Promise.all([
		readDocument("PricingContent.astro"),
		readDocument("ContactContent.astro"),
		readDocument("CancellationRefundContent.astro"),
		readDocument("DeleteUserContent.astro"),
	]);

	assert.equal((pricing.match(/class="why-card"/g) || []).length, 4);
	assert.equal((pricing.match(/class="free-feature"/g) || []).length, 8);
	assert.equal((pricing.match(/class="faq-item"/g) || []).length, 6);
	assert.match(pricing, /class="comparison-table"/);

	assert.equal((contact.match(/class="contact-card"/g) || []).length, 3);
	assert.match(contact, /mailto:contact@betterkeep\.app/);
	assert.match(contact, /tel:\+919380679572/);

	assert.equal(
		(refund.match(/class="document-platform-card"/g) || []).length,
		6,
	);
	assert.match(refund, /support\.google\.com\/googleplay/);
	assert.match(refund, /support\.apple\.com\/en-us\/HT204084/);
	assert.match(refund, /target="_blank" rel="noopener"/);

	assert.equal((deletion.match(/class="step"/g) || []).length, 12);
	assert.equal((deletion.match(/class="data-table"/g) || []).length, 3);
	assert.equal((deletion.match(/class="timeline-item/g) || []).length, 4);
});

test("document icons are local, decorative Lucide components", async () => {
	const icon = await readFile(
		path.join(siteRoot, "components", "documents", "DocumentIcon.astro"),
		"utf8",
	);

	assert.match(icon, /from '@lucide\/astro'/);
	assert.match(icon, /aria-hidden="true"/);
	assert.match(icon, /focusable="false"/);
});

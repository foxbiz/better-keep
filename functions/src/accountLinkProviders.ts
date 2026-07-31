export const ACCOUNT_LINK_PROVIDERS = [
	"google.com",
	"facebook.com",
	"github.com",
	"twitter.com",
	"apple.com",
] as const;

export type AccountLinkProvider = (typeof ACCOUNT_LINK_PROVIDERS)[number];

export function isAccountLinkProvider(
	provider: unknown,
): provider is AccountLinkProvider {
	return (
		typeof provider === "string" &&
		ACCOUNT_LINK_PROVIDERS.includes(provider as AccountLinkProvider)
	);
}

export function accountLinkProviderDisplayName(
	provider: AccountLinkProvider,
): string {
	const names: Record<AccountLinkProvider, string> = {
		"google.com": "Google",
		"facebook.com": "Facebook",
		"github.com": "GitHub",
		"twitter.com": "Twitter/X",
		"apple.com": "Apple",
	};

	return names[provider];
}

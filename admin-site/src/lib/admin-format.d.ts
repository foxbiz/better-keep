export function formatMoneyMicros(amountMicros: string | number, currency: string): string;
export function formatAdminDate(value: string | null | undefined, includeTime?: boolean): string;
export function userInitials(displayName: string | null, email: string | null): string;
export function subscriptionLabel(user: {
  subscriptionClass: string;
  renewalState: string;
}): string;
export function subscriptionTone(user: {
  disabled: boolean;
  subscriptionClass: string;
  renewalState: string;
}): string;

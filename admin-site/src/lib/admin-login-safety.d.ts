export interface AdminLoginGate {
  accept(event: Pick<Event, 'preventDefault'>): boolean;
  markReady(): void;
  markUnavailable(reason: string): void;
}

export function sanitizedAdminLocation(href: string): string | null;

export function shouldSignOutAfterAdminError(error: unknown): boolean;

export function clearAdminCredentialFields(options: {
  email: { value: string };
  password: { value: string };
  mfaCode: { value: string };
  enrollmentCode: { value: string };
  totpSecret: { textContent: string | null };
  totpQr: { removeAttribute(name: string): void };
}): void;

export function createAdminLoginGate(options: {
  submitButton: { disabled: boolean };
  message: { textContent: string | null };
}): AdminLoginGate;

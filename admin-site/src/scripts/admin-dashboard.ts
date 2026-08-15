import { getApps, initializeApp, type FirebaseOptions } from 'firebase/app';
import {
  getToken as getAppCheckToken,
  initializeAppCheck,
  ReCaptchaEnterpriseProvider
} from 'firebase/app-check';
import {
  browserSessionPersistence,
  connectAuthEmulator,
  getMultiFactorResolver,
  getAuth,
  multiFactor,
  onAuthStateChanged,
  setPersistence,
  signInWithEmailAndPassword,
  signOut,
  TotpMultiFactorGenerator,
  type Auth,
  type MultiFactorResolver,
  type TotpSecret,
  type User
} from 'firebase/auth';
import {
  connectFunctionsEmulator,
  getFunctions,
  httpsCallable,
  type HttpsCallable
} from 'firebase/functions';
import QRCode from 'qrcode';
import {
  clearAdminCredentialFields,
  createAdminLoginGate,
  handleAdminEntryFailure,
  sanitizedAdminLocation,
  shouldSignOutAfterAdminError
} from '../lib/admin-login-safety.mjs';
import { resolveAdminTotpChallenge } from '../lib/admin-mfa-flow.mjs';
import {
  billingActivityLabel,
  billingActivityTone,
  billingProviderLabel,
  normalizeAdminBillingActivity
} from '../lib/admin-billing-activity.mjs';
import { adminHealthSummary } from '../lib/admin-health.mjs';
import { normalizeAdminOverview } from '../lib/admin-overview.mjs';
import {
  formatAdminDate,
  formatMoneyMicros,
  subscriptionLabel,
  subscriptionTone,
  userInitials
} from '../lib/admin-format.mjs';

type Money = { currency: string; amountMicros: string };
type BillingActivity = {
  id: string;
  provider: string;
  eventType: string;
  occurredAt: string;
  origin: 'live' | 'historical';
  billingPeriod: string | null;
  environment: string;
  subscriptionState: string | null;
  entitlementState: string | null;
  amountMicros: string | null;
  currency: string | null;
  revenueKind: string | null;
  revenueStatus: string | null;
  customer: { uid: string; email: string | null; displayName: string | null } | null;
};
type AdminUser = {
  uid: string;
  email: string | null;
  displayName: string | null;
  photoURL: string | null;
  providers: string[];
  disabled: boolean;
  emailVerified: boolean;
  isAdmin: boolean;
  isReviewAccount: boolean;
  authCreatedAt: string | null;
  lastSignInAt: string | null;
  lastSeen: string | null;
  plan: string;
  subscriptionClass: 'free' | 'paid' | 'trial';
  renewalState: 'cancelled' | 'none' | 'renewing';
  subscriptionSource: string | null;
  subscriptionState: string | null;
  billingPeriod: string | null;
  subscriptionExpiresAt: string | null;
};
type Overview = {
  schemaVersion: 2;
  generatedAt: string;
  totalUsersUpdatedAt: string | null;
  revenueUpdatedAt: string | null;
  totalUsers: number;
  paidUsers: number;
  cancelledUsers: number;
  subscriptions: {
    updatedAt: string | null;
    byProvider: Record<string, {
      entitled: number;
      renewing: number;
      cancelledWithAccess: number;
      grace: number;
      suspended: number;
      unmatched: number;
    }>;
  };
  revenue: {
    currentMonth: string;
    timezone: string;
    lifetime: { gross: Money[]; refunds: Money[]; net: Money[] };
    monthly: { gross: Money[]; refunds: Money[]; net: Money[] };
    coverage: Record<string, { startedAt?: string | null; lastRecordedAt?: string | null }>;
  };
  revenuePipeline: {
    pending: number;
    retrying: number;
    deadLetter: number;
    excludedTransactions: number;
    unmatchedSubscriptions: number;
    providers: Record<string, { status?: string; updatedAt?: string | null }>;
  };
  health: {
    actionable: {
      pendingRevenue: number;
      retryingRevenue: number;
      deadLetterRevenue: number;
      subscriptionIssues: number;
    };
    quarantined: { revenueTransactions: number; subscriptionIssues: number };
    providers: Record<string, { status?: string; updatedAt?: string | null }>;
  };
};
type AdminServices = {
  auth: Auth;
  getOverview: HttpsCallable<void, unknown>;
  listUsers: HttpsCallable<
    { pageSize: number; segment: string; cursor?: string; search?: string },
    { users: AdminUser[]; nextCursor: string | null }
  >;
  listBillingActivity: HttpsCallable<
    { pageSize: number; cursor?: string; provider?: string; eventType?: string },
    unknown
  >;
  refreshUser: HttpsCallable<{ uid: string }, { user: AdminUser }>;
  setUserDisabled: HttpsCallable<
    { uid: string; disabled: boolean; requestId: string },
    { success: boolean; disabled: boolean }
  >;
  revokeUserSessions: HttpsCallable<{ uid: string; requestId: string }, { success: boolean }>;
};

const root = document.querySelector<HTMLElement>('[data-admin-root]');
if (!root) throw new Error('Admin dashboard root is missing');

function element<T extends Element>(selector: string): T {
  const value = root?.querySelector<T>(selector);
  if (!value) throw new Error(`Admin element is missing: ${selector}`);
  return value;
}

const loginScreen = element<HTMLElement>('[data-login-screen]');
const passwordScreen = element<HTMLElement>('[data-password-screen]');
const mfaScreen = element<HTMLElement>('[data-mfa-screen]');
const enrollmentScreen = element<HTMLElement>('[data-enrollment-screen]');
const dashboard = element<HTMLElement>('[data-dashboard]');
const loginForm = element<HTMLFormElement>('[data-login-form]');
const loginButton = element<HTMLButtonElement>('[data-login-button]');
const loginMessage = element<HTMLElement>('[data-login-message]');
const loginEmail = element<HTMLInputElement>('[data-login-email]');
const loginPassword = element<HTMLInputElement>('[data-login-password]');
const dashboardWarning = element<HTMLElement>('[data-dashboard-warning]');
const mfaForm = element<HTMLFormElement>('[data-mfa-form]');
const mfaCode = element<HTMLInputElement>('[data-mfa-code]');
const mfaButton = element<HTMLButtonElement>('[data-mfa-button]');
const mfaMessage = element<HTMLElement>('[data-mfa-message]');
const enrollmentForm = element<HTMLFormElement>('[data-enrollment-form]');
const enrollmentCode = element<HTMLInputElement>('[data-enrollment-code]');
const enrollmentButton = element<HTMLButtonElement>('[data-enrollment-button]');
const enrollmentMessage = element<HTMLElement>('[data-enrollment-message]');
const totpQr = element<HTMLImageElement>('[data-totp-qr]');
const totpSecretText = element<HTMLElement>('[data-totp-secret]');
const adminEmail = element<HTMLElement>('[data-admin-email]');
const activityList = element<HTMLOListElement>('[data-activity-list]');
const activityStatus = element<HTMLElement>('[data-activity-status]');
const activityProvider = element<HTMLSelectElement>('[data-activity-provider]');
const activityEvent = element<HTMLSelectElement>('[data-activity-event]');
const activityNextButton = element<HTMLButtonElement>('[data-activity-next]');
const activityPreviousButton = element<HTMLButtonElement>('[data-activity-previous]');
const activityPageLabel = element<HTMLElement>('[data-activity-page-label]');
const tableStatus = element<HTMLElement>('[data-table-status]');
const userRows = element<HTMLTableSectionElement>('[data-user-rows]');
const nextButton = element<HTMLButtonElement>('[data-next]');
const previousButton = element<HTMLButtonElement>('[data-previous]');
const pageLabel = element<HTMLElement>('[data-page-label]');
const searchForm = element<HTMLFormElement>('[data-search-form]');
const searchInput = element<HTMLInputElement>('[data-search]');
const userDialog = element<HTMLDialogElement>('[data-user-dialog]');
const dialogMessage = element<HTMLElement>('[data-dialog-message]');
const toggleDisabledButton = element<HTMLButtonElement>('[data-toggle-disabled]');
const revokeSessionsButton = element<HTMLButtonElement>('[data-revoke-sessions]');
const loginGate = createAdminLoginGate({ submitButton: loginButton, message: loginMessage });
const safeLocation = sanitizedAdminLocation(window.location.href);
if (safeLocation) window.history.replaceState(window.history.state, '', safeLocation);

let services: AdminServices | null = null;
let pendingMfaResolver: MultiFactorResolver | null = null;
let pendingEnrollmentSecret: TotpSecret | null = null;
let dialogReturnFocus: HTMLElement | null = null;

const activityState: {
  provider: string;
  eventType: string;
  cursor: string | null;
  nextCursor: string | null;
  cursorHistory: Array<string | null>;
  page: number;
  loading: boolean;
} = {
  provider: '',
  eventType: '',
  cursor: null,
  nextCursor: null,
  cursorHistory: [],
  page: 1,
  loading: false
};

const state: {
  segment: string;
  search: string;
  cursor: string | null;
  nextCursor: string | null;
  cursorHistory: Array<string | null>;
  page: number;
  selectedUser: AdminUser | null;
  loadingUsers: boolean;
} = {
  segment: 'all',
  search: '',
  cursor: null,
  nextCursor: null,
  cursorHistory: [],
  page: 1,
  selectedUser: null,
  loadingUsers: false
};

function isLocalHost() {
  return ['localhost', '127.0.0.1'].includes(window.location.hostname);
}

async function loadFirebaseConfig(): Promise<FirebaseOptions> {
  for (const path of ['/__/firebase/init.json', '/firebase-config.json']) {
    try {
      const response = await fetch(path, { cache: 'no-store', credentials: 'same-origin' });
      if (response.ok) return (await response.json()) as FirebaseOptions;
    } catch {
      // Try the fallback configuration source.
    }
  }
  throw new Error('Firebase configuration is unavailable.');
}

async function initializeServices(): Promise<AdminServices> {
  const config = await loadFirebaseConfig();
  const app = getApps().find((candidate) => candidate.name === 'better-keep-admin') ??
    initializeApp(config, 'better-keep-admin');
  const appCheckSiteKey = document
    .querySelector<HTMLMetaElement>('meta[name="admin-app-check-site-key"]')
    ?.content.trim();
  if (!isLocalHost() && !appCheckSiteKey) {
    throw new Error('Admin App Check is not configured.');
  }
  if (appCheckSiteKey) {
    if (isLocalHost()) {
      (globalThis as typeof globalThis & { FIREBASE_APPCHECK_DEBUG_TOKEN?: boolean })
        .FIREBASE_APPCHECK_DEBUG_TOKEN = true;
    }
    const appCheck = initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(appCheckSiteKey),
      isTokenAutoRefreshEnabled: true
    });
    try {
      const token = await getAppCheckToken(appCheck, true);
      if (!token.token) throw new Error('App Check returned an empty token.');
    } catch (error) {
      throw new Error('Admin App Check verification failed.', { cause: error });
    }
  }
  const auth = getAuth(app);
  const functions = getFunctions(app, 'us-central1');
  if (isLocalHost() && !auth.emulatorConfig) {
    connectAuthEmulator(auth, `http://${window.location.hostname}:9099`, {
      disableWarnings: true
    });
    connectFunctionsEmulator(functions, window.location.hostname, 5001);
  }
  await setPersistence(auth, browserSessionPersistence);
  return {
    auth,
    getOverview: httpsCallable<void, unknown>(functions, 'adminGetOverview'),
    listUsers: httpsCallable<
      { pageSize: number; segment: string; cursor?: string; search?: string },
      { users: AdminUser[]; nextCursor: string | null }
    >(functions, 'adminListUsers'),
    listBillingActivity: httpsCallable<
      { pageSize: number; cursor?: string; provider?: string; eventType?: string },
      unknown
    >(functions, 'adminListBillingActivity'),
    refreshUser: httpsCallable<{ uid: string }, { user: AdminUser }>(functions, 'adminGetUser'),
    setUserDisabled: httpsCallable<
      { uid: string; disabled: boolean; requestId: string },
      { success: boolean; disabled: boolean }
    >(functions, 'adminSetUserDisabled', { limitedUseAppCheckTokens: true }),
    revokeUserSessions: httpsCallable<
      { uid: string; requestId: string },
      { success: boolean }
    >(
      functions,
      'adminRevokeUserSessions',
      { limitedUseAppCheckTokens: true }
    )
  };
}

function requireServices(): AdminServices {
  if (!services) throw new Error('Admin services are unavailable.');
  return services;
}

function friendlyError(error: unknown): string {
  const candidate = error as { code?: string; message?: string };
  const code = candidate.code?.replace('functions/', '');
  if (code === 'permission-denied') return 'This account does not have administrator access.';
  if (code === 'unauthenticated') return 'Your session expired. Please sign in again.';
  if (code === 'invalid-credential' || code === 'auth/invalid-credential') {
    return 'The email or password is incorrect.';
  }
  if (code === 'too-many-requests' || code === 'auth/too-many-requests') {
    return 'Too many attempts. Wait a moment and try again.';
  }
  if (code === 'failed-precondition' && /recent administrator authentication/i.test(candidate.message ?? '')) {
    return 'For safety, sign in again before changing an account.';
  }
  return candidate.message?.replace(/^Firebase:\s*/i, '') || 'Something went wrong. Please try again.';
}

function setText(selector: string, value: string) {
  element<HTMLElement>(selector).textContent = value;
}

function showLogin(message = '') {
  clearAdminCredentialFields({
    email: loginEmail,
    password: loginPassword,
    mfaCode,
    enrollmentCode,
    totpSecret: totpSecretText,
    totpQr
  });
  loginScreen.hidden = false;
  passwordScreen.hidden = false;
  mfaScreen.hidden = true;
  enrollmentScreen.hidden = true;
  dashboard.hidden = true;
  loginMessage.textContent = message;
  pendingMfaResolver = null;
  pendingEnrollmentSecret = null;
}

function showDashboard(user: User) {
  loginScreen.hidden = true;
  dashboard.hidden = false;
  adminEmail.textContent = user.email ?? user.uid;
  const hour = new Date().getHours();
  setText('[data-day-period]', hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : 'evening');
}

function clearDashboardError() {
  dashboardWarning.hidden = true;
  dashboardWarning.textContent = '';
}

function showDashboardError(error: unknown) {
  dashboardWarning.textContent = friendlyError(error);
  dashboardWarning.hidden = false;
}

async function handleAuthenticatedFailure(error: unknown, user: User) {
  await handleAdminEntryFailure({
    error,
    signOut: () => signOut(requireServices().auth),
    showLogin: (failure: unknown) => showLogin(friendlyError(failure)),
    showDashboardError: (failure: unknown) => {
      showDashboard(user);
      showDashboardError(failure);
    }
  });
}

function showMfaChallenge() {
  loginScreen.hidden = false;
  passwordScreen.hidden = true;
  enrollmentScreen.hidden = true;
  mfaScreen.hidden = false;
  dashboard.hidden = true;
  mfaCode.value = '';
  mfaMessage.textContent = '';
  mfaCode.focus();
}

async function showTotpEnrollment(user: User) {
  const session = await multiFactor(user).getSession();
  const secret = await TotpMultiFactorGenerator.generateSecret(session);
  const uri = secret.generateQrCodeUrl(user.email ?? user.uid, 'Better Keep Admin');
  pendingEnrollmentSecret = secret;
  totpQr.src = await QRCode.toDataURL(uri, { errorCorrectionLevel: 'M', margin: 1, width: 440 });
  totpSecretText.textContent = secret.secretKey;
  loginScreen.hidden = false;
  passwordScreen.hidden = true;
  mfaScreen.hidden = true;
  enrollmentScreen.hidden = false;
  dashboard.hidden = true;
  enrollmentCode.value = '';
  enrollmentMessage.textContent = '';
  enrollmentCode.focus();
}

function renderMoneyList(target: HTMLElement, values: Money[]) {
  target.replaceChildren();
  if (values.length === 0) {
    const empty = document.createElement('span');
    empty.className = 'empty-value';
    empty.textContent = 'No recorded charges';
    target.append(empty);
    return;
  }
  for (const value of values) {
    const row = document.createElement('div');
    row.className = 'money-line';
    const amount = document.createElement('strong');
    amount.textContent = formatMoneyMicros(value.amountMicros, value.currency);
    const currency = document.createElement('span');
    currency.textContent = value.currency;
    row.append(amount, currency);
    target.append(row);
  }
}

function coverageDate(value: Overview['revenue']['coverage'][string] | undefined): string {
  if (!value?.startedAt) return 'Awaiting data';
  return `Since ${formatAdminDate(value.startedAt)}`;
}

function renderCoverage(coverage: Overview['revenue']['coverage']) {
  const target = element<HTMLElement>('[data-coverage-list]');
  target.replaceChildren();
  for (const [key, label] of [
    ['razorpay', 'Razorpay'],
    ['app_store', 'App Store'],
    ['play_store', 'Google Play']
  ]) {
    const row = document.createElement('div');
    row.className = 'coverage-row';
    const name = document.createElement('strong');
    name.textContent = label;
    const date = document.createElement('span');
    date.textContent = coverageDate(coverage[key]);
    row.append(name, date);
    target.append(row);
  }
}

function renderSubscriptionCounts(overview: Overview) {
  for (const [provider, counts] of Object.entries(overview.subscriptions.byProvider)) {
    const card = root?.querySelector<HTMLElement>(`[data-provider="${provider}"]`);
    if (!card) continue;
    for (const key of ['entitled', 'renewing', 'cancelledWithAccess', 'grace', 'suspended', 'unmatched'] as const) {
      const target = card.querySelector<HTMLElement>(`[data-count="${key}"]`);
      if (target) target.textContent = counts[key].toLocaleString();
    }
  }
  setText(
    '[data-subscription-freshness]',
    overview.subscriptions.updatedAt
      ? `Reconciled ${formatAdminDate(overview.subscriptions.updatedAt, true)} · runs every 6 hours`
      : 'Provider reconciliation pending'
  );
}

function renderHealth(overview: Overview) {
  const summary = adminHealthSummary(overview);
  const actionable = overview.health.actionable;
  const quarantined = overview.health.quarantined;
  const actionableCard = element<HTMLElement>('[data-actionable-health]');
  const quarantinedCard = element<HTMLElement>('[data-quarantined-health]');
  setText('[data-actionable-count]', summary.actionableCount.toLocaleString());
  actionableCard.dataset.tone = summary.actionableCount === 0 ? 'success' : 'danger';
  setText(
    '[data-pipeline-warning]',
    summary.actionableCount === 0
      ? 'No actionable billing failures.'
      : `${actionable.pendingRevenue} pending; ${actionable.retryingRevenue} retrying; ` +
        `${actionable.deadLetterRevenue} dead-letter; ${actionable.subscriptionIssues} subscription issue(s)` +
        (summary.degradedProviders.length
          ? `; check ${summary.degradedProviders.map((provider) => billingProviderLabel(provider)).join(', ')}.`
          : '.')
  );
  setText('[data-quarantined-count]', summary.quarantinedCount.toLocaleString());
  quarantinedCard.dataset.tone = summary.quarantinedCount === 0 ? 'success' : 'warning';
  setText(
    '[data-quarantine-note]',
    summary.quarantinedCount === 0
      ? 'No retained historical anomalies.'
      : `${quarantined.revenueTransactions} excluded transaction(s); ` +
        `${quarantined.subscriptionIssues} historical subscription issue(s). Audit history is retained.`
  );
  const freshnessList = element<HTMLElement>('[data-freshness-list]');
  freshnessList.replaceChildren(...summary.freshness.map((entry) => {
    const row = document.createElement('div');
    row.className = 'freshness-row';
    row.dataset.stale = String(entry.stale);
    const label = document.createElement('span');
    label.textContent = entry.label;
    const value = document.createElement('strong');
    value.textContent = entry.stale
      ? entry.value ? `Stale · ${formatAdminDate(entry.value, true)}` : 'Pending'
      : formatAdminDate(entry.value, true);
    row.append(label, value);
    return row;
  }));
  element<HTMLElement>('[data-freshness-health]').dataset.tone =
    summary.freshness.some((entry) => entry.stale) ? 'warning' : 'success';
}

async function loadOverview() {
  setText('[data-as-of]', 'Refreshing…');
  const result = await requireServices().getOverview();
  const overview = normalizeAdminOverview(result.data) as Overview;
  setText('[data-total-users]', overview.totalUsers.toLocaleString());
  setText('[data-paid-users]', overview.paidUsers.toLocaleString());
  setText('[data-cancelled-users]', overview.cancelledUsers.toLocaleString());
  setText('[data-as-of]', formatAdminDate(overview.generatedAt, true));
  setText(
    '[data-total-users-freshness]',
    overview.totalUsersUpdatedAt
      ? `Reconciled ${formatAdminDate(overview.totalUsersUpdatedAt, true)} · runs every 6 hours`
      : 'Index count · reconciliation pending'
  );
  setText('[data-revenue-month]', `${overview.revenue.currentMonth} · UTC`);
  renderMoneyList(element('[data-monthly-gross]'), overview.revenue.monthly.gross);
  renderMoneyList(element('[data-monthly-refunds]'), overview.revenue.monthly.refunds);
  renderMoneyList(element('[data-monthly-net]'), overview.revenue.monthly.net);
  renderMoneyList(element('[data-lifetime-gross]'), overview.revenue.lifetime.gross);
  renderMoneyList(element('[data-lifetime-refunds]'), overview.revenue.lifetime.refunds);
  renderMoneyList(element('[data-lifetime-net]'), overview.revenue.lifetime.net);
  renderSubscriptionCounts(overview);
  renderCoverage(overview.revenue.coverage);
  renderHealth(overview);
}

function renderBillingActivityItem(activity: BillingActivity): HTMLLIElement {
  const item = document.createElement('li');
  item.className = 'activity-item';

  const event = document.createElement('div');
  event.className = 'activity-event';
  const dot = document.createElement('i');
  dot.className = 'activity-dot';
  dot.dataset.tone = billingActivityTone(activity.eventType);
  dot.setAttribute('aria-hidden', 'true');
  const eventText = document.createElement('div');
  const eventName = document.createElement('strong');
  eventName.textContent = billingActivityLabel(activity.eventType);
  const provider = document.createElement('small');
  provider.textContent = `${billingProviderLabel(activity.provider)} · ${formatAdminDate(activity.occurredAt, true)}`;
  eventText.append(eventName, provider);
  event.append(dot, eventText);

  const customer = document.createElement('div');
  customer.className = 'activity-customer';
  const customerName = document.createElement('strong');
  customerName.textContent = activity.customer?.displayName || activity.customer?.email || 'Unlinked customer';
  const customerDetail = document.createElement('small');
  customerDetail.textContent = activity.customer?.displayName && activity.customer.email
    ? activity.customer.email
    : activity.billingPeriod || 'No customer details';
  customer.append(customerName, customerDetail);

  const stateValue = activity.revenueStatus || activity.subscriptionState ||
    activity.entitlementState || 'verified';
  const activityStateValue = document.createElement('span');
  activityStateValue.className = 'activity-state';
  activityStateValue.textContent = stateValue.replaceAll('_', ' ');

  const money = document.createElement('div');
  money.className = 'activity-money';
  const amount = document.createElement('strong');
  amount.textContent = activity.amountMicros && activity.currency
    ? formatMoneyMicros(activity.amountMicros, activity.currency)
    : '—';
  const kind = document.createElement('small');
  kind.textContent = activity.revenueKind || 'state event';
  money.append(amount, kind);

  const origin = document.createElement('span');
  origin.className = 'activity-origin';
  origin.textContent = activity.origin;
  item.append(event, customer, activityStateValue, money, origin);
  return item;
}

async function loadBillingActivity() {
  if (activityState.loading) return;
  activityState.loading = true;
  activityStatus.textContent = 'Loading billing activity…';
  activityNextButton.disabled = true;
  activityPreviousButton.disabled = true;
  try {
    const response = await requireServices().listBillingActivity({
      pageSize: 20,
      ...(activityState.cursor ? { cursor: activityState.cursor } : {}),
      ...(activityState.provider ? { provider: activityState.provider } : {}),
      ...(activityState.eventType ? { eventType: activityState.eventType } : {})
    });
    const normalized = normalizeAdminBillingActivity(response.data) as {
      activities: BillingActivity[];
      nextCursor: string | null;
    };
    activityList.replaceChildren(...normalized.activities.map(renderBillingActivityItem));
    activityState.nextCursor = normalized.nextCursor;
    activityStatus.textContent = normalized.activities.length === 0
      ? 'No billing activity matches these filters.'
      : '';
    activityNextButton.disabled = !activityState.nextCursor;
    activityPreviousButton.disabled = activityState.cursorHistory.length === 0;
    activityPageLabel.textContent = `Page ${activityState.page}`;
  } catch (error) {
    activityStatus.textContent = friendlyError(error);
  } finally {
    activityState.loading = false;
  }
}

function createCell(): HTMLTableCellElement {
  return document.createElement('td');
}

function renderUserRow(user: AdminUser): HTMLTableRowElement {
  const row = document.createElement('tr');
  row.tabIndex = 0;
  row.setAttribute('aria-label', `View ${user.displayName || user.email || user.uid}`);

  const identity = createCell();
  const userCell = document.createElement('div');
  userCell.className = 'user-cell';
  const avatar = document.createElement('span');
  avatar.className = 'avatar';
  avatar.textContent = userInitials(user.displayName, user.email);
  const identityText = document.createElement('div');
  const name = document.createElement('strong');
  name.textContent = user.displayName || 'Unnamed user';
  const email = document.createElement('small');
  email.textContent = user.email || user.uid;
  identityText.append(name, email);
  userCell.append(avatar, identityText);
  identity.append(userCell);

  const access = createCell();
  const status = document.createElement('span');
  status.className = 'status-pill';
  status.dataset.tone = subscriptionTone(user);
  status.textContent = user.disabled ? 'Disabled' : subscriptionLabel(user);
  access.append(status);

  const source = createCell();
  source.textContent = user.subscriptionSource?.replaceAll('_', ' ') || '—';
  const joined = createCell();
  joined.textContent = formatAdminDate(user.authCreatedAt);
  const lastSeen = createCell();
  lastSeen.textContent = formatAdminDate(user.lastSeen || user.lastSignInAt);
  const actions = createCell();
  const action = document.createElement('button');
  action.className = 'row-action';
  action.type = 'button';
  action.setAttribute('aria-label', 'Open user details');
  action.textContent = '•••';
  actions.append(action);
  row.append(identity, access, source, joined, lastSeen, actions);

  const open = () => openUserDialog(user);
  row.addEventListener('click', open);
  row.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      open();
    }
  });
  return row;
}

async function loadUsers() {
  if (state.loadingUsers) return;
  state.loadingUsers = true;
  tableStatus.textContent = 'Loading users…';
  nextButton.disabled = true;
  previousButton.disabled = true;
  try {
    const response = await requireServices().listUsers({
      pageSize: 25,
      segment: state.segment,
      ...(state.cursor ? { cursor: state.cursor } : {}),
      ...(state.search ? { search: state.search } : {})
    });
    userRows.replaceChildren(...response.data.users.map(renderUserRow));
    state.nextCursor = response.data.nextCursor;
    tableStatus.textContent = response.data.users.length === 0 ? 'No users match this view.' : '';
    nextButton.disabled = !state.nextCursor || Boolean(state.search);
    previousButton.disabled = state.cursorHistory.length === 0 || Boolean(state.search);
    pageLabel.textContent = state.search ? `${response.data.users.length} results` : `Page ${state.page}`;
  } catch (error) {
    tableStatus.textContent = friendlyError(error);
  } finally {
    state.loadingUsers = false;
  }
}

function detailItem(label: string, value: string): HTMLDivElement {
  const item = document.createElement('div');
  item.className = 'detail-item';
  const term = document.createElement('dt');
  term.textContent = label;
  const description = document.createElement('dd');
  description.textContent = value;
  description.title = value;
  item.append(term, description);
  return item;
}

function renderDialog(user: AdminUser) {
  state.selectedUser = user;
  setText('[data-dialog-avatar]', userInitials(user.displayName, user.email));
  setText('[data-dialog-name]', user.displayName || 'Unnamed user');
  setText('[data-dialog-email]', user.email || 'No email address');
  const details = element<HTMLElement>('[data-dialog-details]');
  details.replaceChildren(
    detailItem('User ID', user.uid),
    detailItem('Access', user.disabled ? 'Disabled' : subscriptionLabel(user)),
    detailItem('Billing', user.billingPeriod || '—'),
    detailItem('Source', user.subscriptionSource?.replaceAll('_', ' ') || '—'),
    detailItem('Expires', formatAdminDate(user.subscriptionExpiresAt)),
    detailItem('Joined', formatAdminDate(user.authCreatedAt)),
    detailItem('Last sign-in', formatAdminDate(user.lastSignInAt, true)),
    detailItem('Providers', user.providers.join(', ') || 'None')
  );
  const protectedUser = user.isAdmin || user.isReviewAccount;
  toggleDisabledButton.disabled = protectedUser;
  revokeSessionsButton.disabled = protectedUser;
  toggleDisabledButton.textContent = user.disabled ? 'Enable account' : 'Disable account';
  toggleDisabledButton.className = user.disabled ? 'secondary-button' : 'danger-button';
  dialogMessage.textContent = protectedUser ? 'This protected account cannot be changed here.' : '';
}

function openUserDialog(user: AdminUser) {
  dialogReturnFocus = document.activeElement instanceof HTMLElement
    ? document.activeElement
    : null;
  renderDialog(user);
  userDialog.showModal();
}

async function refreshSelectedUser() {
  if (!state.selectedUser) return;
  const response = await requireServices().refreshUser({ uid: state.selectedUser.uid });
  renderDialog(response.data.user);
}

async function authorizeUser(user: User): Promise<boolean> {
  const token = await user.getIdTokenResult(true);
  return (
    user.emailVerified &&
    token.claims.appAdmin === true &&
    token.signInProvider === 'password' &&
    token.signInSecondFactor === TotpMultiFactorGenerator.FACTOR_ID
  );
}

async function enterDashboard(user: User) {
  const token = await user.getIdTokenResult(true);
  const baseAuthorization = user.emailVerified &&
    token.claims.appAdmin === true &&
    token.signInProvider === 'password';
  if (!baseAuthorization) {
    await signOut(requireServices().auth);
    showLogin('Administrator access has not been provisioned for this account.');
    return;
  }
  const hasTotp = multiFactor(user).enrolledFactors.some(
    (factor) => factor.factorId === TotpMultiFactorGenerator.FACTOR_ID
  );
  if (!hasTotp) {
    await showTotpEnrollment(user);
    return;
  }
  if (!(await authorizeUser(user))) {
    await signOut(requireServices().auth);
    showLogin('Two-step verification is required. Sign in again to continue.');
    return;
  }
  showDashboard(user);
  clearDashboardError();
  await Promise.all([loadOverview(), loadBillingActivity(), loadUsers()]);
}

loginForm.addEventListener('submit', async (event) => {
  if (!loginGate.accept(event)) return;
  const email = loginEmail.value.trim().toLowerCase();
  const password = loginPassword.value;
  loginButton.disabled = true;
  loginMessage.textContent = 'Signing in…';
  try {
    await signInWithEmailAndPassword(requireServices().auth, email, password);
  } catch (error) {
    const candidate = error as { code?: string };
    if (candidate.code === 'auth/multi-factor-auth-required') {
      const resolver = getMultiFactorResolver(requireServices().auth, error as never);
      const hasTotp = resolver.hints.some(
        (hint) => hint.factorId === TotpMultiFactorGenerator.FACTOR_ID
      );
      if (!hasTotp) {
        loginMessage.textContent = 'This administrator account has no supported TOTP factor.';
      } else {
        pendingMfaResolver = resolver;
        showMfaChallenge();
      }
    } else {
      loginMessage.textContent = friendlyError(error);
    }
  } finally {
    loginButton.disabled = false;
  }
});

mfaForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const resolver = pendingMfaResolver;
  const hint = resolver?.hints.find(
    (candidate) => candidate.factorId === TotpMultiFactorGenerator.FACTOR_ID
  );
  if (!resolver || !hint) {
    showLogin('The verification challenge expired. Sign in again.');
    return;
  }
  mfaButton.disabled = true;
  mfaMessage.textContent = 'Verifying…';
  const resolution = await resolveAdminTotpChallenge({
    assertionForSignIn: TotpMultiFactorGenerator.assertionForSignIn,
    code: mfaCode.value,
    hintUid: hint.uid,
    resolver
  });
  if (resolution.ok) {
    pendingMfaResolver = null;
  } else {
    mfaMessage.textContent = friendlyError(resolution.error);
  }
  mfaButton.disabled = false;
});

enrollmentForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const user = requireServices().auth.currentUser;
  if (!user || !pendingEnrollmentSecret) {
    showLogin('The enrollment session expired. Sign in again.');
    return;
  }
  enrollmentButton.disabled = true;
  enrollmentMessage.textContent = 'Enrolling authenticator…';
  try {
    const assertion = TotpMultiFactorGenerator.assertionForEnrollment(
      pendingEnrollmentSecret,
      enrollmentCode.value
    );
    await multiFactor(user).enroll(assertion, 'Better Keep Admin');
    pendingEnrollmentSecret = null;
    await signOut(requireServices().auth);
    showLogin('TOTP enrollment is complete. Sign in again to continue.');
  } catch (error) {
    enrollmentMessage.textContent = friendlyError(error);
  } finally {
    enrollmentButton.disabled = false;
  }
});

element<HTMLButtonElement>('[data-cancel-mfa]').addEventListener('click', () => {
  showLogin();
});
element<HTMLButtonElement>('[data-cancel-enrollment]').addEventListener('click', () => {
  void signOut(requireServices().auth);
});

element<HTMLButtonElement>('[data-sign-out]').addEventListener('click', () => {
  if (services) void signOut(services.auth);
});
element<HTMLButtonElement>('[data-refresh]').addEventListener('click', async () => {
  clearDashboardError();
  try {
    await Promise.all([loadOverview(), loadBillingActivity(), loadUsers()]);
    clearDashboardError();
  } catch (error) {
    setText('[data-as-of]', friendlyError(error));
    const user = requireServices().auth.currentUser;
    if (user) await handleAuthenticatedFailure(error, user);
  }
});

element<HTMLFormElement>('[data-activity-filters]').addEventListener('submit', (event) => {
  event.preventDefault();
  activityState.provider = activityProvider.value;
  activityState.eventType = activityEvent.value;
  activityState.cursor = null;
  activityState.nextCursor = null;
  activityState.cursorHistory = [];
  activityState.page = 1;
  void loadBillingActivity();
});

activityNextButton.addEventListener('click', () => {
  if (!activityState.nextCursor) return;
  activityState.cursorHistory.push(activityState.cursor);
  activityState.cursor = activityState.nextCursor;
  activityState.page += 1;
  void loadBillingActivity();
});

activityPreviousButton.addEventListener('click', () => {
  activityState.cursor = activityState.cursorHistory.pop() ?? null;
  activityState.page = Math.max(1, activityState.page - 1);
  void loadBillingActivity();
});

element<HTMLElement>('[data-filters]').addEventListener('click', (event) => {
  const button = event.target instanceof Element
    ? event.target.closest<HTMLButtonElement>('[data-segment]')
    : null;
  if (!button) return;
  state.segment = button.dataset.segment || 'all';
  state.search = '';
  searchInput.value = '';
  state.cursor = null;
  state.nextCursor = null;
  state.cursorHistory = [];
  state.page = 1;
  root.querySelectorAll('[data-segment]').forEach((candidate) => {
    candidate.classList.toggle('is-active', candidate === button);
  });
  void loadUsers();
});

searchForm.addEventListener('submit', (event) => {
  event.preventDefault();
  state.search = searchInput.value.trim();
  state.cursor = null;
  state.cursorHistory = [];
  state.page = 1;
  void loadUsers();
});
searchInput.addEventListener('search', () => {
  if (searchInput.value === '') {
    state.search = '';
    void loadUsers();
  }
});

nextButton.addEventListener('click', () => {
  if (!state.nextCursor) return;
  state.cursorHistory.push(state.cursor);
  state.cursor = state.nextCursor;
  state.page += 1;
  void loadUsers();
});
previousButton.addEventListener('click', () => {
  const previous = state.cursorHistory.pop();
  state.cursor = previous ?? null;
  state.page = Math.max(1, state.page - 1);
  void loadUsers();
});

element<HTMLButtonElement>('[data-dialog-close]').addEventListener('click', () => userDialog.close());
userDialog.addEventListener('click', (event) => {
  if (event.target === userDialog) userDialog.close();
});
userDialog.addEventListener('close', () => {
  dialogReturnFocus?.focus();
  dialogReturnFocus = null;
});

toggleDisabledButton.addEventListener('click', async () => {
  const user = state.selectedUser;
  if (!user) return;
  const nextDisabled = !user.disabled;
  const verb = nextDisabled ? 'disable' : 'enable';
  if (!window.confirm(`Are you sure you want to ${verb} ${user.email || user.uid}?`)) return;
  toggleDisabledButton.disabled = true;
  dialogMessage.textContent = `${nextDisabled ? 'Disabling' : 'Enabling'} account…`;
  const requestId = crypto.randomUUID();
  try {
    await requireServices().setUserDisabled({ uid: user.uid, disabled: nextDisabled, requestId });
    await refreshSelectedUser();
    await Promise.all([loadOverview(), loadBillingActivity(), loadUsers()]);
    dialogMessage.textContent = `Account ${nextDisabled ? 'disabled' : 'enabled'}.`;
  } catch (error) {
    await refreshSelectedUser().catch(() => undefined);
    dialogMessage.textContent = friendlyError(error);
    if (shouldSignOutAfterAdminError(error)) {
      await signOut(requireServices().auth);
    }
  } finally {
    toggleDisabledButton.disabled = Boolean(state.selectedUser?.isAdmin || state.selectedUser?.isReviewAccount);
  }
});

revokeSessionsButton.addEventListener('click', async () => {
  const user = state.selectedUser;
  if (!user) return;
  if (!window.confirm(`Sign ${user.email || user.uid} out of every device?`)) return;
  revokeSessionsButton.disabled = true;
  dialogMessage.textContent = 'Revoking active sessions…';
  const requestId = crypto.randomUUID();
  try {
    await requireServices().revokeUserSessions({ uid: user.uid, requestId });
    dialogMessage.textContent = 'All refresh sessions were revoked.';
  } catch (error) {
    await refreshSelectedUser().catch(() => undefined);
    dialogMessage.textContent = friendlyError(error);
    if (shouldSignOutAfterAdminError(error)) {
      await signOut(requireServices().auth);
    }
  } finally {
    revokeSessionsButton.disabled = Boolean(state.selectedUser?.isAdmin || state.selectedUser?.isReviewAccount);
  }
});

async function initializeAdmin() {
  try {
    services = await initializeServices();
    loginGate.markReady();
    onAuthStateChanged(services.auth, (user) => {
      if (!user) {
        showLogin();
        return;
      }
      void enterDashboard(user).catch((error) => handleAuthenticatedFailure(error, user));
    });
  } catch {
    services = null;
    const message = isLocalHost()
      ? 'Firebase is unavailable. Open this page through the Firebase Hosting emulator.'
      : 'Admin sign-in is temporarily unavailable. Please try again later.';
    showLogin(message);
    loginGate.markUnavailable(message);
  }
}

void initializeAdmin();

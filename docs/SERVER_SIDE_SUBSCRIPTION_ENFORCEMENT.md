# Server-Side Subscription Enforcement

## Overview

This document describes the implementation of server-side subscription enforcement using Firebase Custom Claims. This security enhancement ensures that subscription-gated features (like cloud sync) cannot be bypassed by modifying the client app.

## Problem Statement

Previously, subscription checks were only performed on the client side:

- Firestore and Storage security rules only verified authentication, not subscription status
- A malicious user could modify the app to bypass subscription checks and sync notes without paying

## Solution: Firebase Custom Claims

We now use **Firebase Auth Custom Claims** to enforce subscription status at the server level. When a user's subscription is verified or changed, Cloud Functions set custom claims on their Firebase Auth token. These claims are then checked in Firestore and Storage security rules.

### How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│   App Purchase  │────►│ Cloud Functions  │────►│ Firebase Auth       │
│   or Webhook    │     │ (verify purchase)│     │ (set custom claims) │
└─────────────────┘     └──────────────────┘     └─────────────────────┘
                                                           │
                                                           ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│   App syncs     │────►│ Firestore/Storage│────►│ Check claims in     │
│   notes         │     │ Security Rules   │     │ request.auth.token  │
└─────────────────┘     └──────────────────┘     └─────────────────────┘
```

1. **Purchase Verification**: When a purchase is verified (Google Play, Razorpay), Cloud Functions set custom claims on the user's auth token
2. **Webhook Updates**: When subscription status changes (renewal, cancellation, expiration), webhooks update the claims
3. **Security Rules**: Firestore and Storage rules check the claims before allowing writes
4. **Token Refresh**: The client refreshes its auth token to pick up updated claims

## Implementation Details

### Custom Claims Structure

```typescript
{
  plan: 'pro' | 'free',      // Current subscription plan
  planExpiresAt: number      // Expiration timestamp in milliseconds (null for free)
}
```

### Files Modified

#### 1. Cloud Functions (`functions/src/index.ts`)

**New Helper Function:**

```typescript
async function setSubscriptionClaims(
  userId: string,
  plan: 'pro' | 'free',
  expiresAt: Date | null,
): Promise<void>;
```

**Updated Functions:**

- `verifyGooglePlayPurchase()` - Sets Pro claims after successful verification
- `playStoreWebhook` - Updates claims on subscription lifecycle events
- `verifyRazorpaySubscription()` - Sets Pro claims after payment verification
- `razorpayWebhook` - Updates claims on Razorpay subscription events

#### 2. Firestore Security Rules (`firestore.rules`)

```javascript
// Helper function to check Pro subscription
function isPro() {
  return request.auth.token.plan == 'pro'
    && request.auth.token.planExpiresAt != null
    && request.auth.token.planExpiresAt > request.time.toMillis();
}

// Notes collection - requires Pro for writes
match /notes/{noteId} {
  allow read: if request.auth != null && request.auth.uid == userId;
  allow create, update: if request.auth != null
    && request.auth.uid == userId
    && isPro();
  allow delete: if request.auth != null
    && request.auth.uid == userId
    && (isPro() || resource != null);
}
```

#### 3. Storage Security Rules (`storage.rules`)

```javascript
function isPro() {
  return request.auth.token.plan == 'pro'
    && request.auth.token.planExpiresAt != null
    && request.auth.token.planExpiresAt > request.time.toMillis();
}

match /users/{userId}/{allPaths=**} {
  allow read: if request.auth != null && request.auth.uid == userId;
  allow write: if request.auth != null
    && request.auth.uid == userId
    && isPro();
}
```

#### 4. Client App (`lib/services/monetization/plan_service.dart`)

Added token refresh when subscription changes:

```dart
void _setSubscription(SubscriptionStatus status) {
  final oldPlan = _subscriptionStatus.value.effectivePlan;
  final newPlan = status.effectivePlan;

  // ... update subscription ...

  // Refresh token to get updated claims
  if (oldPlan != newPlan) {
    _refreshAuthTokenForUpdatedClaims();
  }
}

Future<void> _refreshAuthTokenForUpdatedClaims() async {
  final user = AuthService.currentUser;
  if (user == null) return;
  await user.getIdToken(true); // Force refresh
}
```

## Deployment Steps

1. **Deploy Cloud Functions first:**

   ```bash
   cd functions
   npm run build
   firebase deploy --only functions
   ```

2. **Deploy Security Rules:**

   ```bash
   firebase deploy --only firestore:rules,storage
   ```

3. **Test the implementation:**
   - Create a test account
   - Verify that syncing fails without subscription
   - Purchase a subscription
   - Verify that syncing works with subscription
   - Cancel subscription
   - Verify that syncing fails after expiration

## Migration for Existing Users

Existing Pro subscribers need their custom claims set. Options:

### Option A: Trigger on Next Verification (Automatic)

Claims will be set automatically when:

- User's subscription is validated via `checkExistingSubscription()`
- A webhook event is received for their subscription
- They restore their purchase

### Option B: Batch Migration Script (Recommended for immediate enforcement)

The migration script is located at `functions/src/migrations/migrateSubscriptionClaims.ts`.

**To run it:**

```bash
# 1. Navigate to the functions directory
cd functions

# 2. Make sure you're authenticated with Firebase
firebase login

# 3. Set the Google Application Credentials (use your service account key)
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/your-service-account-key.json"

# 4. Run the migration script
npx ts-node src/migrations/migrateSubscriptionClaims.ts
```

**Alternative: Compile and run:**

```bash
cd functions
npm run build
node lib/migrations/migrateSubscriptionClaims.js
```

The script will:

- Find all users with active Pro subscriptions
- Set custom claims (`plan: 'pro'`, `planExpiresAt: <timestamp>`)
- Skip expired or free subscriptions
- Print a summary of migrated users

## Security Considerations

### What's Protected

- **Notes Collection**: Create/Update requires Pro subscription
- **Labels Collection**: Create/Update requires Pro subscription
- **Storage Files**: All writes require Pro subscription
- **Reads**: Always allowed for authenticated owners (for data export/migration)
- **Deletes**: Allowed for Pro users OR if resource exists (cleanup)

### What's NOT Protected (by design)

- User document and settings (non-sync related)
- Subscription status document (only Cloud Functions can write)
- Reading existing data (allows users to download their data even after subscription ends)

### Rate Limiting

- Token refresh is only triggered when plan actually changes
- Backend validation has a 5-minute cooldown

## Troubleshooting

### User can't sync after purchasing

1. Check if Cloud Function executed successfully
2. Verify custom claims were set: `firebase auth:export` or use Admin SDK
3. Check if client refreshed its token
4. Verify security rules are deployed

### User can still sync after subscription ended

1. Check if webhook was received
2. Verify claims were cleared
3. Client may have cached token - will resolve on next refresh

### Testing Claims

Use Firebase Admin SDK:

```typescript
const user = await admin.auth().getUser(userId);
console.log(user.customClaims);
```

## Rollback Plan

If issues arise, you can temporarily revert security rules to allow all authenticated writes:

```javascript
// TEMPORARY ROLLBACK - removes subscription enforcement
match /notes/{noteId} {
  allow read, write: if request.auth != null && request.auth.uid == userId;
}
```

Then investigate and fix the underlying issue before re-enabling enforcement.

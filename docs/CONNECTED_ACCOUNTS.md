# Connected Accounts

This document describes how the Connected Accounts feature works in Better Keep, allowing users to link multiple sign-in providers to a single account.

## Overview

Connected Accounts allows users to link multiple authentication providers (Google, Facebook, GitHub, Twitter/X) to their Better Keep account. Once linked, users can sign in using any of their connected accounts to access the same data.

## Supported Providers

| Provider ID | Display Name | Scopes Requested |
|-------------|--------------|------------------|
| `google.com` | Google | `email` |
| `facebook.com` | Facebook | `email`, `public_profile` |
| `github.com` | GitHub | `read:user`, `user:email` |
| `twitter.com` | X (Twitter) | (default) |
| `password` | Email | N/A (email/password auth) |

## Architecture

### Files Involved

- **`lib/services/auth_service.dart`** - Contains all account linking logic
- **`lib/pages/user_page.dart`** - UI for Connected Accounts section

---

## AuthService Methods

### Querying Linked Providers

#### `getLinkedProviderIds()`
Returns a list of provider IDs currently linked to the user's account.

```dart
static List<String> getLinkedProviderIds() {
  final user = currentUser;
  if (user == null) return [];
  return user.providerData.map((info) => info.providerId).toList();
}
```

**Returns:** `List<String>` - e.g., `['google.com', 'github.com']`

#### `isProviderLinked(String providerId)`
Checks if a specific provider is linked.

```dart
static bool isProviderLinked(String providerId) {
  return getLinkedProviderIds().contains(providerId);
}
```

---

### Linking Providers

All linking methods follow the same pattern:
1. Check if user is signed in
2. Create the appropriate `AuthProvider`
3. Add required scopes
4. Call Firebase's `linkWithPopup()` (web) or `linkWithProvider()` / `linkWithCredential()` (mobile/desktop)

#### `linkWithGoogle()`
Links a Google account. Platform-specific handling:

- **Web:** Uses `user.linkWithPopup(GoogleAuthProvider())`
- **Windows/Linux:** Uses `DesktopAuthService.signIn()` to get tokens, then `user.linkWithCredential()`
- **Android/iOS/macOS:** Uses native `google_sign_in` package, then `user.linkWithCredential()`

#### `linkWithFacebook()`
Links a Facebook account.

```dart
FacebookAuthProvider facebookProvider = FacebookAuthProvider();
facebookProvider.addScope('email');
facebookProvider.addScope('public_profile');

if (kIsWeb) {
  await user.linkWithPopup(facebookProvider);
} else {
  await user.linkWithProvider(facebookProvider);
}
```

#### `linkWithGitHub()`
Links a GitHub account.

```dart
GithubAuthProvider githubProvider = GithubAuthProvider();
githubProvider.addScope('read:user');
githubProvider.addScope('user:email');

if (kIsWeb) {
  await user.linkWithPopup(githubProvider);
} else {
  await user.linkWithProvider(githubProvider);
}
```

#### `linkWithTwitter()`
Links a Twitter/X account.

```dart
TwitterAuthProvider twitterProvider = TwitterAuthProvider();

if (kIsWeb) {
  await user.linkWithPopup(twitterProvider);
} else {
  await user.linkWithProvider(twitterProvider);
}
```

---

### Unlinking Providers

#### `unlinkProvider(String providerId)`
Removes a linked provider from the user's account.

```dart
static Future<void> unlinkProvider(String providerId) async {
  final user = currentUser;
  if (user == null) throw Exception('No user signed in');

  // Security check: Don't allow unlinking the last provider
  if (user.providerData.length <= 1) {
    throw Exception(
      'Cannot unlink the only sign-in method. Add another provider first.',
    );
  }

  await user.unlink(providerId);
}
```

**Security:** The method prevents unlinking the last provider to ensure users cannot lock themselves out of their account.

---

## User Interface

### Location
The Connected Accounts section is displayed in `UserPage` (`lib/pages/user_page.dart`), between the Subscription section and E2EE section.

### UI Components

#### Provider List
Each provider is displayed as a row with:
- **Icon:** Provider logo (colored if linked, grayed out if not)
- **Name:** Provider display name
- **Status:** "Connected" label if linked
- **Action Button:**
  - **"Link"** button for unlinked providers
  - **"Unlink"** button for linked providers (only if multiple providers are linked)
  - **"Primary"** label (disabled) if it's the only linked provider

#### Security Notice
A blue info box is displayed at the top:
> "Linking requires authentication with each platform to verify ownership."

### Provider Configuration

Providers are defined with metadata in `_buildConnectedPlatformsSection()`:

```dart
final providers = [
  _ProviderInfo(
    id: 'google.com',
    name: 'Google',
    icon: Icons.g_mobiledata,
    color: Colors.red.shade600,
    onLink: () => _linkProvider('google'),
  ),
  _ProviderInfo(
    id: 'facebook.com',
    name: 'Facebook',
    icon: FontAwesomeIcons.facebook,
    color: const Color(0xFF1877F2),
    onLink: () => _linkProvider('facebook'),
  ),
  // ... more providers
];
```

### `_ProviderInfo` Class

Helper class to store provider metadata:

```dart
class _ProviderInfo {
  final String id;        // Firebase provider ID (e.g., 'google.com')
  final String name;      // Display name
  final IconData icon;    // Icon to display
  final Color color;      // Brand color
  final VoidCallback? onLink;  // Callback to link (null for email)

  const _ProviderInfo({...});
}
```

---

## Linking Flow

### Step 1: User Clicks "Link" Button
The `_linkProvider(String providerName)` method is called.

### Step 2: Confirmation Dialog
A dialog is shown explaining:
- User will be redirected to sign in with the provider
- This proves ownership of the account
- Warning: "Only link accounts you own"

### Step 3: Loading Indicator
A modal loading dialog is shown with "Linking account..." message.

### Step 4: Firebase Authentication
The appropriate `AuthService.linkWith*()` method is called:
- User is redirected to the provider's login page
- User authenticates with their credentials
- Firebase links the credential to the current user

### Step 5: Success/Error Handling

**On Success:**
- Loading dialog dismissed
- UI refreshed via `setState()`
- Green snackbar: "Successfully linked {provider} account"

**On Error:**
- Loading dialog dismissed
- Error-specific message shown in red snackbar

---

## Unlinking Flow

### Step 1: User Clicks "Unlink" Button
The `_unlinkProvider(_ProviderInfo provider)` method is called.

### Step 2: Confirmation Dialog
A warning dialog is shown:
- Title: "Unlink {provider}?"
- Message: "You will no longer be able to sign in with this account. Make sure you have another way to access your account."

### Step 3: Firebase Unlink
`AuthService.unlinkProvider(provider.id)` is called.

### Step 4: Success/Error Handling
- UI refreshed via `setState()`
- Green snackbar: "Unlinked {provider}"

---

## Error Handling

### Linking Errors

| Firebase Error | User Message |
|----------------|--------------|
| `credential-already-in-use` | "This {provider} account is already linked to another user." |
| `provider-already-linked` | "{provider} is already linked to your account." |
| `email-already-in-use` | "An account with this email already exists. Sign in with that account first, then link from there." |
| `cancelled` / `canceled` | "Linking was cancelled." |

### Unlinking Errors

| Error | User Message |
|-------|--------------|
| `Cannot unlink` | "Cannot unlink the only sign-in method." |

---

## Security Measures

### 1. Authentication Required
Every linking operation requires the user to authenticate with the target provider. This proves ownership of the account being linked.

### 2. Firebase Server-Side Validation
All linking/unlinking operations are validated by Firebase Auth servers. Client-side tampering cannot bypass these checks.

### 3. Single Provider Protection
Users cannot unlink their last sign-in method, preventing account lockout.

```dart
if (user.providerData.length <= 1) {
  throw Exception('Cannot unlink the only sign-in method...');
}
```

### 4. Credential Uniqueness
Firebase prevents linking an account that's already linked to a different Firebase user (`credential-already-in-use` error).

### 5. UI Safeguards
- "Unlink" button is hidden when only one provider is linked
- Confirmation dialogs before any linking/unlinking action
- Security notice explaining the verification process

---

## Firebase Console Configuration

For each provider to work, it must be enabled in Firebase Console:

1. Go to **Firebase Console** → **Authentication** → **Sign-in method**
2. Enable each provider you want to support
3. Configure OAuth credentials for each provider:
   - **Google:** Automatically configured
   - **Facebook:** Requires Facebook App ID and Secret
   - **GitHub:** Requires GitHub OAuth App credentials
   - **Twitter:** Requires Twitter API Key and Secret

---

## Notes

### Email/Password Provider
The Email provider (`password`) has `onLink: null` because linking email/password requires a different flow (setting a password) which is not currently implemented.

### Platform Differences
- **Web:** Uses popup-based authentication (`linkWithPopup`)
- **Mobile/Desktop:** Uses redirect-based authentication (`linkWithProvider` or `linkWithCredential`)

### Logging
All linking operations are logged via `AppLogger`:
- Success: `'Successfully linked {provider} account'`
- Error: `'Error linking {provider} account'` with stack trace

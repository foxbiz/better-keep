/// Better Keep Notes Monetization System
///
/// This module provides:
/// - User plan definitions (Free, Pro)
/// - Entitlements model with feature access rules
/// - Subscription status tracking
/// - Plan resolution service
/// - Entitlement guards for feature gating
///
/// Usage:
/// ```dart
/// import 'package:better_keep/services/monetization/monetization.dart';
///
/// // Check if feature is allowed
/// final result = EntitlementGuard.canUseRealtimeCloudSync();
/// if (!result.allowed) {
///   showPaywall(context, feature: GatedFeature.realtimeCloudSync);
/// }
///
/// // Get current plan
/// final plan = PlanService.instance.currentPlan;
///
/// // Listen to plan changes
/// PlanService.instance.statusNotifier.addListener(() {
///   // React to subscription changes
/// });
/// ```
library;

export 'entitlement_guard.dart';
export 'entitlements.dart';
export 'plan_service.dart';
export 'subscription_service.dart';
export 'subscription_status.dart';
export 'user_plan.dart';

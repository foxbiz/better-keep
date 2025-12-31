// Razorpay Checkout Bridge for Flutter Web
// This file handles the Razorpay checkout flow from Dart

(function () {
  'use strict';

  // Store callbacks for Dart communication
  let _onPaymentSuccess = null;
  let _onPaymentError = null;
  let _onPaymentCancelled = null;

  /**
   * Open Razorpay Checkout for Subscription
   * @param {Object} options - Checkout options
   * @param {string} options.keyId - Razorpay Key ID
   * @param {string} options.subscriptionId - Razorpay Subscription ID
   * @param {string} options.name - Business name
   * @param {string} options.description - Plan description
   * @param {string} options.prefillEmail - User's email
   * @param {string} options.prefillContact - User's phone (optional)
   * @param {string} options.theme - Theme color (hex)
   */
  window.openRazorpaySubscription = function (options) {
    console.log('razorpay_checkout.js: openRazorpaySubscription called');
    console.log('razorpay_checkout.js: options received:', JSON.stringify(options));
    console.log('razorpay_checkout.js: theme color:', options.theme);
    return new Promise((resolve, reject) => {
      if (typeof Razorpay === 'undefined') {
        reject({ error: 'Razorpay SDK not loaded' });
        return;
      }

      const themeColor = options.theme || '#FFA726';
      // Use a dark backdrop to match dark app themes
      const backdropColor = options.backdropColor || 'rgba(0, 0, 0, 0.7)';
      console.log('razorpay_checkout.js: Using theme color:', themeColor);

      const rzpOptions = {
        key: options.keyId,
        subscription_id: options.subscriptionId,
        name: options.name || 'Better Keep',
        description: options.description || 'Pro Subscription',
        image: 'https://betterkeep.app/icons/logo.png',
        prefill: {
          email: options.prefillEmail || '',
          contact: options.prefillContact || '',
        },
        theme: {
          color: themeColor,
          backdrop_color: backdropColor,
        },
        modal: {
          ondismiss: function () {
            reject({ cancelled: true, message: 'Payment cancelled by user' });
          },
          escape: true,
          animation: true,
        },
        handler: function (response) {
          // Payment successful
          resolve({
            success: true,
            razorpay_payment_id: response.razorpay_payment_id,
            razorpay_subscription_id: response.razorpay_subscription_id,
            razorpay_signature: response.razorpay_signature,
          });
        },
      };

      try {
        const rzp = new Razorpay(rzpOptions);

        rzp.on('payment.failed', function (response) {
          reject({
            error: true,
            code: response.error.code,
            description: response.error.description,
            source: response.error.source,
            step: response.error.step,
            reason: response.error.reason,
            metadata: response.error.metadata,
          });
        });

        rzp.open();
      } catch (e) {
        reject({ error: true, message: e.message || 'Failed to open Razorpay' });
      }
    });
  };

  /**
   * Check if Razorpay SDK is loaded
   */
  window.isRazorpayLoaded = function () {
    return typeof Razorpay !== 'undefined';
  };

  console.log('Razorpay checkout bridge initialized');
})();

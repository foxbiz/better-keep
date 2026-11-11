// Razorpay Checkout Bridge for Flutter Web
// This file handles the Razorpay checkout flow from Dart

(function () {
  'use strict';

  let loading;
  window.loadRazorpayCheckout = function () {
    if (typeof window.Razorpay === 'function') return Promise.resolve(true);
    if (loading) return loading;
    const script = document.createElement('script');
    script.src = 'https://checkout.razorpay.com/v1/checkout.js';
    loading = new Promise((resolve) => {
      function finish() {
        clearTimeout(timer);
        script.onload = script.onerror = null;
        const ready = typeof window.Razorpay === 'function';
        if (!ready) script.remove();
        resolve(ready);
      }
      const timer = setTimeout(finish, 15000);
      script.onload = script.onerror = finish;
      document.head.appendChild(script);
    }).finally(() => { loading = null; });
    return loading;
  };

  function openCheckout(options, payment) {
    return new Promise((resolve, reject) => {
      const themeColor = options.theme || '#FFA726';
      // Use a dark backdrop to match dark app themes
      const backdropColor = options.backdropColor || 'rgba(0, 0, 0, 0.7)';

      const rzpOptions = {
        key: options.keyId,
        ...payment,
        name: options.name || 'Better Keep',
        description: options.description,
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
            razorpay_order_id: response.razorpay_order_id,
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
  }

  window.openRazorpaySubscription = (options) =>
    openCheckout(options, { subscription_id: options.subscriptionId });
  window.openRazorpayOrder = (options) =>
    openCheckout(options, {
      order_id: options.orderId,
      amount: options.amount,
      currency: options.currency,
    });
})();

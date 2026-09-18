/**
 * ui/kiosk-theme-button.js - Photobooth-App Kiosk Extension
 *
 * 1. Injects a native-styled "Choose Theme" action button directly into the real
 *    Photobooth-App idle front-page (.action-buttons.q-gutter-md) without modifying
 *    the compiled Vue bundle or core packages.
 * 2. Deterministic public booth navigation: intercepts post-capture and login return
 *    buttons (which natively call router.back() / router.go(-1)) and routes them
 *    directly home to '#/', preventing history pop bounces into /admin or /auth/login.
 * 3. Public session sanitization: purges stale admin credentials from sessionStorage
 *    when idle on the public booth screen ('#/'), preventing accidental auto-entry
 *    into the Admin Center.
 */
(function () {
  const THEME_SELECTOR_URL = window.THEME_SELECTOR_URL || 'http://localhost:8080/';

  /**
   * Find the authentic idle front-page action container.
   *
   * Signature of real Photobooth-App FrontpageTriggerButtons:
   * - Has class "action-buttons"
   * - Has Quasar row spacing class "q-gutter-md" and/or "row"
   * - Is NOT inside #itemapproval-dialog or any .q-dialog modal
   * - Contains native action buttons (.action-button or .action-button-image/collage/gallery)
   */
  function findFrontpageActionContainer() {
    const containers = document.querySelectorAll('.action-buttons');
    for (const container of containers) {
      // 1. Exclude approval dialogs, modal popups, and column dialog actions
      if (
        container.closest('#itemapproval-dialog') ||
        container.closest('.q-dialog') ||
        container.classList.contains('col')
      ) {
        continue;
      }

      // 2. Real front-page container signature: "row q-gutter-md action-buttons"
      const hasFrontpageLayout =
        container.classList.contains('q-gutter-md') ||
        container.classList.contains('row');

      // 3. Must contain at least one native action button (Image, Collage, or Gallery)
      const hasNativeButtons =
        container.querySelector('.action-button, [class*="action-button-"]') ||
        container.children.length > 0;

      if (hasFrontpageLayout && hasNativeButtons) {
        return container;
      }
    }
    return null;
  }

  /**
   * Construct the "Choose Theme" button matching Photobooth-App's native Quasar button structure.
   */
  function createThemeButton() {
    const wrapper = document.createElement('div');
    wrapper.className = 'extension-theme-btn-wrapper';

    const btn = document.createElement('a');
    btn.id = 'btnChooseTheme';
    btn.href = THEME_SELECTOR_URL;
    btn.className =
      'q-btn q-btn-item non-selectable no-outline q-btn--standard q-btn--rounded q-btn--actionable action-button col-auto glass-effect bg-primary text-white action-button-theme';
    btn.title = 'Choose Theme';
    btn.setAttribute('aria-label', 'Choose Theme');
    btn.setAttribute('role', 'button');
    btn.tabIndex = 0;
    btn.style.textDecoration = 'none';
    btn.style.display = 'inline-flex';
    btn.style.flexDirection = 'column';
    btn.style.alignItems = 'center';
    btn.style.justifyContent = 'center';

    btn.innerHTML = `
      <span class="q-focus-helper"></span>
      <span class="q-btn__content text-center col items-center q-anchor--skip justify-center column">
        <i class="q-icon notranslate material-symbols-outlined" aria-hidden="true" role="presentation">palette</i>
        <div class="gt-sm" style="white-space: nowrap;">Choose Theme</div>
      </span>
    `;

    wrapper.appendChild(btn);
    return wrapper;
  }

  /**
   * Idempotently inject the button into the front-page action container.
   */
  function injectButton() {
    const container = findFrontpageActionContainer();
    if (!container) return;

    // Idempotency: skip if already present in this active container
    if (container.querySelector('#btnChooseTheme')) return;

    // Clean up any stale orphaned instance from previous container instances
    const existing = document.getElementById('btnChooseTheme');
    if (existing) {
      if (container.contains(existing)) return;
      existing.closest('.extension-theme-btn-wrapper')?.remove() || existing.remove();
    }

    container.appendChild(createThemeButton());
  }

  /**
   * Inject style rule to neutralize the invisible admin hotspot.
   * Ensures the browser completely ignores the invisible element for hit-testing,
   * allowing guest clicks to pass directly through to native controls underneath.
   */
  function injectNeutralizingStyles() {
    const STYLE_ID = 'kiosk-neutralize-admin-hotspot';
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = `
      #frontpage-button-to-admin.action-button-admin-invisible,
      .action-button-admin.action-button-admin-invisible {
        pointer-events: none !important;
        display: none !important;
        visibility: hidden !important;
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  }

  /**
   * Explicitly disable pointer-events and display on the invisible admin button and its sticky container.
   */
  function neutralizeInvisibleAdminButton() {
    const adminBtn = document.getElementById('frontpage-button-to-admin');
    if (adminBtn) {
      if (adminBtn.classList.contains('action-button-admin-invisible') || adminBtn.style.opacity === '0') {
        adminBtn.style.setProperty('pointer-events', 'none', 'important');
        adminBtn.style.setProperty('display', 'none', 'important');
        adminBtn.style.setProperty('visibility', 'hidden', 'important');
        const stickyParent = adminBtn.closest('.q-page-sticky');
        if (stickyParent) {
          stickyParent.style.setProperty('pointer-events', 'none', 'important');
        }
      }
    }
  }

  /**
   * Sanitize session credentials when on the public idle frontpage.
   * Prevents stale admin tokens from lingering and auto-authorizing routes to /#/admin.
   */
  function sanitizePublicSession() {
    const hash = window.location.hash || '';
    if (hash === '' || hash === '#/' || hash === '#') {
      try {
        if (window.sessionStorage && window.sessionStorage.getItem('credentials')) {
          window.sessionStorage.removeItem('credentials');
        }
      } catch (err) {
        // Ignore cross-origin / private browsing storage errors
      }
      if (window.history && window.history.replaceState) {
        try {
          window.history.replaceState(null, '', '#/');
        } catch (err) {}
      }
    }
  }

  /**
   * Global capturing click interceptor to ensure deterministic navigation back to '#/'
   * and block any clicks targeting the invisible admin hotspot.
   * Intercepts:
   * 1. Invisible admin button clicks
   * 2. #layout-button-back outside #itemapproval-dialog (used on itempresenter post-capture and gallery)
   * 3. The back button on #login-page
   */
  document.addEventListener(
    'click',
    function (e) {
      if (!e.target || typeof e.target.closest !== 'function') return;

      // Neutralize any click targeting frontpage-button-to-admin when invisible
      const adminBtn = e.target.closest('#frontpage-button-to-admin, .action-button-admin-invisible');
      if (adminBtn && adminBtn.classList.contains('action-button-admin-invisible')) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        return;
      }

      // Check for Return Button
      const backBtn = e.target.closest('#layout-button-back');
      if (backBtn) {
        // Do NOT intercept if inside itemapproval-dialog (collage approval cancellation POSTs to backend)
        if (backBtn.closest('#itemapproval-dialog')) {
          return;
        }

        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        window.location.hash = '#/';
        return;
      }

      // Check for Login Page back button
      const loginBackBtn = e.target.closest('#login-page .q-btn');
      if (loginBackBtn && loginBackBtn.querySelector('.q-icon')?.textContent?.includes('arrow_back')) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        window.location.hash = '#/';
      }
    },
    true // Use capture phase to intercept before native Vue / Quasar listeners
  );

  function handleUpdates() {
    injectButton();
    neutralizeInvisibleAdminButton();
  }

  /**
   * Idempotently bootstrap the Live AR Overlay script if not already present.
   */
  function bootstrapAROverlay() {
    const SCRIPT_ID = 'kiosk-ar-overlay-script';
    if (document.getElementById(SCRIPT_ID)) return;
    const script = document.createElement('script');
    script.id = SCRIPT_ID;
    script.src = `${THEME_SELECTOR_URL.replace(/\/+$/, '')}/kiosk-ar-overlay.js`;
    script.async = true;
    (document.head || document.documentElement).appendChild(script);
  }

  // Inject styles immediately
  injectNeutralizingStyles();
  bootstrapAROverlay();

  // Listeners for public session hygiene
  window.addEventListener('hashchange', sanitizePublicSession);
  window.addEventListener('load', sanitizePublicSession);
  sanitizePublicSession();

  // Initial injection and neutralization attempt on page load
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', handleUpdates);
  } else {
    handleUpdates();
  }

  // Observe Vue virtual DOM updates to preserve button and keep admin hotspot neutralized
  const observer = new MutationObserver(() => handleUpdates());
  observer.observe(document.body, { childList: true, subtree: true });
})();

/**
 * ui/kiosk-theme-button.js - Photobooth-App Kiosk "Choose Theme" Extension Button Injector
 *
 * Injects a native-styled "Choose Theme" action button directly into the real
 * Photobooth-App idle front-page (.action-buttons.q-gutter-md) without modifying
 * the compiled Vue bundle or core packages.
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

  // Initial injection attempt on page load
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectButton);
  } else {
    injectButton();
  }

  // Observe Vue virtual DOM updates to preserve button through state re-renders
  const observer = new MutationObserver(() => injectButton());
  observer.observe(document.body, { childList: true, subtree: true });
})();

/**
 * ui/kiosk-theme-button.js - Photobooth-App Kiosk "Choose Theme" Extension Button Injector
 *
 * Adds the "Choose Theme" entry point directly into the Photobooth-App kiosk interface
 * next to the existing Image and Collage buttons, without modifying core application packages.
 */
(function () {
  const THEME_SELECTOR_URL = window.THEME_SELECTOR_URL || 'http://localhost:8080/';

  function createThemeButton() {
    const btn = document.createElement('a');
    btn.id = 'btnChooseTheme';
    btn.href = THEME_SELECTOR_URL;
    btn.className = 'booth-action-btn btn-theme';
    btn.title = 'Choose Theme';
    btn.setAttribute('aria-label', 'Choose Theme');
    btn.innerHTML = `
      <svg class="btn-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="3" y="3" width="18" height="18" rx="3"/>
        <circle cx="8.5" cy="8.5" r="1.5" fill="currentColor"/>
        <polyline points="21 15 16 10 5 21"/>
      </svg>
      <span class="btn-label">Choose Theme</span>
    `;
    return btn;
  }

  function injectButton() {
    if (document.getElementById('btnChooseTheme')) return;

    // Photobooth-App action button container candidates
    const container =
      document.querySelector('.kiosk-actions-column') ||
      document.querySelector('.trigger-buttons') ||
      document.querySelector('.actions-container') ||
      document.querySelector('[data-action="collage"]')?.parentElement ||
      document.querySelector('[data-action="image"]')?.parentElement;

    if (container) {
      container.appendChild(createThemeButton());
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', injectButton);
  } else {
    injectButton();
  }

  // Observe Vue DOM updates
  const observer = new MutationObserver(() => injectButton());
  observer.observe(document.body, { childList: true, subtree: true });
})();

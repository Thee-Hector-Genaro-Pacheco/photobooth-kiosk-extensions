// Photo Booth Touchscreen Theme Selector Client
document.addEventListener("DOMContentLoaded", () => {
  const cards = document.querySelectorAll(".theme-card");
  const statusMessage = document.getElementById("statusMessage");
  const btnBackToBooth = document.getElementById("btnBackToBooth");

  let currentSelectedTheme = null;
  let isUpdating = false;

  const THEME_NAMES = {
    "modern-gold": "Modern Gold",
    "tropical": "Tropical",
    "black-gold": "Black & Gold",
    "floral": "Elegant Floral",
    "celebration": "Celebration",
    "halloween": "Halloween",
    "thanksgiving": "Thanksgiving",
    "christmas": "Christmas",
    "new-year": "New Year",
    "none": "No Border",
  };

  function setActiveThemeUI(themeName) {
    currentSelectedTheme = themeName;

    cards.forEach((card) => {
      const cardTheme = card.dataset.theme;
      if (cardTheme === themeName) {
        card.classList.add("active-theme");
      } else {
        card.classList.remove("active-theme");
      }
    });

    const displayName = THEME_NAMES[themeName] || themeName;
    statusMessage.textContent = `Current Active: ${displayName}`;
  }

  async function loadCurrentTheme() {
    try {
      const response = await fetch("/api/current-theme");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const activeTheme = data.theme || "modern-gold";
      setActiveThemeUI(activeTheme);

      // Dynamically update Back to Photo Booth destination if provided
      if (data.target_url && btnBackToBooth) {
        btnBackToBooth.href = `${data.target_url.replace(/\/+$/, "")}/`;
      }
    } catch (err) {
      console.warn("Could not fetch current theme from server, defaulting to Modern Gold:", err);
      setActiveThemeUI("modern-gold");
      statusMessage.textContent = "Offline Preview Mode: Ready";
    }
  }

  async function handleThemeSelection(themeName) {
    if (isUpdating || themeName === currentSelectedTheme) return;

    isUpdating = true;
    const displayName = THEME_NAMES[themeName] || themeName;
    statusMessage.textContent = `Applying ${displayName}...`;

    try {
      const response = await fetch("/api/select-theme", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ theme: themeName }),
      });

      if (!response.ok) {
        throw new Error(`Server returned status ${response.status}`);
      }

      const result = await response.json();

      if (result.status !== "success") {
        throw new Error(result.error || "Theme application failed");
      }

      setActiveThemeUI(themeName);

      // In preview mode: update UI only, never redirect
      if (result.preview_mode) {
        statusMessage.textContent = `Selected: ${displayName} (Preview Mode)`;
        return;
      }

      // Live mode confirmed by backend: brief visual confirmation, then auto-return
      if (result.redirect_url) {
        statusMessage.textContent = `Applied ${displayName}! Returning to booth...`;
        setTimeout(() => {
          window.location.href = result.redirect_url;
        }, 650);
      } else {
        statusMessage.textContent = `Applied: ${displayName}`;
      }
    } catch (err) {
      console.error("Theme selection failed:", err);
      // DO NOT REDIRECT on failure - keep user on selector with visible status
      statusMessage.textContent = `Failed to apply ${displayName}. Please try again.`;
    } finally {
      isUpdating = false;
    }
  }

  // Bind touch and click events to theme cards
  cards.forEach((card) => {
    const themeName = card.dataset.theme;

    card.addEventListener("click", (e) => {
      e.preventDefault();
      handleThemeSelection(themeName);
    });
  });

  // Initial load
  loadCurrentTheme();
});

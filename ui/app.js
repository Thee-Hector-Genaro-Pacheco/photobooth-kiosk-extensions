// Photo Booth Touchscreen Theme Selector Client
document.addEventListener("DOMContentLoaded", () => {
  const cards = document.querySelectorAll(".theme-card");
  const statusMessage = document.getElementById("statusMessage");

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
    statusMessage.textContent = `Selecting ${displayName}...`;

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
      setActiveThemeUI(themeName);
      statusMessage.textContent = `Selected: ${displayName} (Preview Mode)`;
    } catch (err) {
      console.error("Theme selection failed:", err);
      // Still update UI in client-side preview mode if server is in preview mode
      setActiveThemeUI(themeName);
      statusMessage.textContent = `Selected: ${displayName} (Local Preview)`;
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

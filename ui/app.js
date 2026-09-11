// Photo Booth Touchscreen Theme, AR Effect & Filter Selector Client
document.addEventListener("DOMContentLoaded", () => {
  const themeCards = document.querySelectorAll(".theme-card");
  const filterCards = document.querySelectorAll(".filter-card");
  const statusMessage = document.getElementById("statusMessage");
  const modePill = document.getElementById("modePill");
  const btnBackToBooth = document.getElementById("btnBackToBooth");
  const tabThemes = document.getElementById("tabThemes");
  const tabAREffects = document.getElementById("tabAREffects");
  const tabFilters = document.getElementById("tabFilters");
  const themeGrid = document.getElementById("themeGrid");
  const arGrid = document.getElementById("arGrid");
  const filterGrid = document.getElementById("filterGrid");
  const themeActivePill = document.getElementById("themeActivePill");
  const arActivePill = document.getElementById("arActivePill");
  const filterActivePill = document.getElementById("filterActivePill");
  const pageTitle = document.getElementById("pageTitle");
  const pageSubtitle = document.getElementById("pageSubtitle");
  const BOOTH_HOME_URL = "http://localhost:8000/#/";

  let currentSelectedTheme = null;
  let currentSelectedFilter = "original";
  let currentSelectedAREffect = "none";
  let isAREnabled = false;
  let arEffectsMap = {};
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

  const FILTER_NAMES = {
    "original": "Original",
    "black-and-white": "Black & White",
    "vintage": "Vintage",
    "warm": "Warm",
    "vibrant": "Vibrant",
    "film": "Film",
  };

  const FILTER_CSS = {
    "original": "none",
    "black-and-white": "grayscale(100%) contrast(115%)",
    "vintage": "sepia(45%) contrast(105%) brightness(105%)",
    "warm": "sepia(20%) saturate(125%) brightness(105%)",
    "vibrant": "contrast(120%) saturate(135%)",
    "film": "grayscale(85%) contrast(105%) brightness(95%)",
  };

  function updateStatusMessage() {
    const themeDisplay = THEME_NAMES[currentSelectedTheme] || currentSelectedTheme || "Modern Gold";
    const arDisplay = (!isAREnabled || currentSelectedAREffect === "none")
      ? "None"
      : ((arEffectsMap[currentSelectedAREffect] && arEffectsMap[currentSelectedAREffect].name) || currentSelectedAREffect);
    const filterDisplay = FILTER_NAMES[currentSelectedFilter] || currentSelectedFilter || "Original";

    if (themeActivePill) themeActivePill.textContent = themeDisplay;
    if (arActivePill) arActivePill.textContent = arDisplay;
    if (filterActivePill) filterActivePill.textContent = filterDisplay;

    statusMessage.textContent = `Active Theme: ${themeDisplay} | AR: ${arDisplay} | Filter: ${filterDisplay}`;
  }

  function setActiveThemeUI(themeName) {
    currentSelectedTheme = themeName;
    themeCards.forEach((card) => {
      const cardTheme = card.dataset.theme;
      if (cardTheme === themeName) {
        card.classList.add("active-theme");
      } else {
        card.classList.remove("active-theme");
      }
    });
    updateStatusMessage();
  }

  function setActiveFilterUI(filterName) {
    currentSelectedFilter = filterName;
    filterCards.forEach((card) => {
      const cardFilter = card.dataset.filter;
      if (cardFilter === filterName) {
        card.classList.add("active-filter");
      } else {
        card.classList.remove("active-filter");
      }
    });

    // Apply simulated CSS filter to sample portraits inside theme cards as a visual preview hint
    const cssStyle = FILTER_CSS[filterName] || "none";
    if (themeGrid) {
      const themeSamplePhotos = themeGrid.querySelectorAll(".sample-photo");
      themeSamplePhotos.forEach((img) => {
        img.style.filter = cssStyle;
      });
    }

    updateStatusMessage();
  }

  function setActiveARUI(effectName, enabled) {
    isAREnabled = (effectName !== "none" && Boolean(enabled));
    currentSelectedAREffect = isAREnabled ? effectName : "none";

    if (arGrid) {
      const arCards = arGrid.querySelectorAll(".ar-card");
      arCards.forEach((card) => {
        const cardEffect = card.dataset.arEffect;
        if (cardEffect === currentSelectedAREffect) {
          card.classList.add("active-ar");
        } else {
          card.classList.remove("active-ar");
        }
      });
    }

    updateStatusMessage();
  }

  function switchTab(mode) {
    // Reset all tabs
    [tabThemes, tabAREffects, tabFilters].forEach((t) => {
      if (t) {
        t.classList.remove("active-tab");
        t.setAttribute("aria-selected", "false");
      }
    });

    // Hide all grids
    if (themeGrid) themeGrid.style.display = "none";
    if (arGrid) arGrid.style.display = "none";
    if (filterGrid) filterGrid.style.display = "none";

    if (mode === "ar") {
      if (tabAREffects) {
        tabAREffects.classList.add("active-tab");
        tabAREffects.setAttribute("aria-selected", "true");
      }
      if (arGrid) arGrid.style.display = "grid";
      if (pageTitle) pageTitle.textContent = "Choose AR Face Effect";
      if (pageSubtitle) pageSubtitle.textContent = "Tap an AR effect for live camera preview and photos";
    } else if (mode === "filters") {
      if (tabFilters) {
        tabFilters.classList.add("active-tab");
        tabFilters.setAttribute("aria-selected", "true");
      }
      if (filterGrid) filterGrid.style.display = "grid";
      if (pageTitle) pageTitle.textContent = "Choose Photo Filter";
      if (pageSubtitle) pageSubtitle.textContent = "Tap a filter for your photos (applied before frame compositing)";
    } else {
      if (tabThemes) {
        tabThemes.classList.add("active-tab");
        tabThemes.setAttribute("aria-selected", "true");
      }
      if (themeGrid) themeGrid.style.display = "grid";
      if (pageTitle) pageTitle.textContent = "Choose Your Theme";
      if (pageSubtitle) pageSubtitle.textContent = "Tap a frame style for your photos";
    }
  }

  function renderAREffects(effectsConfig) {
    arEffectsMap = effectsConfig || {};
    if (!arGrid) return;

    // Bind "none" card if present
    const cardNone = document.getElementById("card-ar-none");
    if (cardNone && !cardNone.dataset.bound) {
      cardNone.dataset.bound = "true";
      cardNone.addEventListener("click", (e) => {
        e.preventDefault();
        handleAREffectSelection("none");
      });
    }

    // Dynamically render discovered AR effects from data model
    for (const [effectId, config] of Object.entries(arEffectsMap)) {
      if (effectId === "none") continue;

      let card = document.getElementById(`card-ar-${effectId}`);
      if (!card) {
        card = document.createElement("button");
        card.type = "button";
        card.className = "theme-option ar-card";
        card.id = `card-ar-${effectId}`;
        card.dataset.arEffect = effectId;

        const badge = document.createElement("div");
        badge.className = "card-badge";
        badge.id = `badge-ar-${effectId}`;
        badge.textContent = "Current Effect";

        const stack = document.createElement("div");
        stack.className = "card-frame-stack";

        const basePhoto = document.createElement("img");
        basePhoto.src = "assets/sample-photo.jpg";
        basePhoto.alt = config.name || effectId;
        basePhoto.className = "sample-photo";
        stack.appendChild(basePhoto);

        // Render first AR element as preview overlay
        if (Array.isArray(config.elements) && config.elements[0] && config.elements[0].asset) {
          const arOverlay = document.createElement("img");
          arOverlay.src = config.elements[0].asset;
          arOverlay.alt = config.name || effectId;
          arOverlay.className = "ar-overlay-preview";
          stack.appendChild(arOverlay);
        }

        const meta = document.createElement("div");
        meta.className = "ar-card-meta";

        const title = document.createElement("span");
        title.className = "ar-card-title";
        title.textContent = config.name || effectId;

        const sub = document.createElement("span");
        sub.className = "ar-card-sub";
        sub.textContent = config.description || "Live Face Overlay";

        meta.appendChild(title);
        meta.appendChild(sub);

        card.appendChild(badge);
        card.appendChild(stack);
        card.appendChild(meta);

        card.addEventListener("click", (e) => {
          e.preventDefault();
          handleAREffectSelection(effectId);
        });

        arGrid.appendChild(card);
      }
    }

    setActiveARUI(currentSelectedAREffect, isAREnabled);
  }

  async function loadCurrentState() {
    try {
      const response = await fetch("/api/current-theme");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const activeTheme = data.theme || "modern-gold";
      const activeFilter = data.filter || "original";

      setActiveThemeUI(activeTheme);
      setActiveFilterUI(activeFilter);

      // Load AR state from backend
      if (typeof data.ar_enabled === "boolean") {
        isAREnabled = data.ar_enabled;
        currentSelectedAREffect = data.active_ar_effect || "glasses";
      }

      if (modePill) {
        modePill.textContent = data.preview_mode ? "Preview Mode" : "Live Mode";
        if (!data.preview_mode) {
          modePill.style.background = "#2e7d32";
          modePill.style.color = "#ffffff";
        }
      }

      if (btnBackToBooth) {
        btnBackToBooth.href = data.target_url || BOOTH_HOME_URL;
      }
    } catch (err) {
      console.warn("Could not fetch current state from server, using defaults:", err);
      setActiveThemeUI("modern-gold");
      setActiveFilterUI("original");
      statusMessage.textContent = "Offline Preview Mode: Ready";
      if (btnBackToBooth) {
        btnBackToBooth.href = BOOTH_HOME_URL;
      }
    }

    // Discover AR configuration from server
    try {
      const arConfigResp = await fetch("/api/ar/config");
      if (arConfigResp.ok) {
        const arData = await arConfigResp.json();
        if (typeof arData.enabled === "boolean") isAREnabled = arData.enabled;
        if (arData.active_effect) currentSelectedAREffect = arData.active_effect;
        if (arData.effects) renderAREffects(arData.effects);
        setActiveARUI(currentSelectedAREffect, isAREnabled);
      }
    } catch (err) {
      console.warn("Could not fetch AR configuration:", err);
      setActiveARUI("none", false);
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
        keepalive: true,
        body: JSON.stringify({ theme: themeName, filter: currentSelectedFilter }),
      });

      if (!response.ok) {
        throw new Error(`Server returned status ${response.status}`);
      }

      const result = await response.json();

      if (result.status !== "success") {
        throw new Error(result.error || "Theme application failed");
      }

      setActiveThemeUI(themeName);

      if (result.preview_mode) {
        statusMessage.textContent = `Selected: ${displayName} (Preview Mode)`;
        return;
      }

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
      statusMessage.textContent = `Failed to apply ${displayName}. Please try again.`;
    } finally {
      isUpdating = false;
    }
  }

  async function handleFilterSelection(filterName) {
    if (isUpdating || filterName === currentSelectedFilter) return;

    isUpdating = true;
    const displayName = FILTER_NAMES[filterName] || filterName;
    statusMessage.textContent = `Applying ${displayName} filter...`;

    try {
      const response = await fetch("/api/select-filter", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        keepalive: true,
        body: JSON.stringify({ filter: filterName, theme: currentSelectedTheme }),
      });

      if (!response.ok) {
        throw new Error(`Server returned status ${response.status}`);
      }

      const result = await response.json();

      if (result.status !== "success") {
        throw new Error(result.error || "Filter application failed");
      }

      setActiveFilterUI(filterName);

      if (result.preview_mode) {
        statusMessage.textContent = `Selected Filter: ${displayName} (Preview Mode)`;
      } else {
        statusMessage.textContent = `Applied Filter: ${displayName}!`;
      }
    } catch (err) {
      console.error("Filter selection failed:", err);
      statusMessage.textContent = `Failed to apply ${displayName} filter. Please try again.`;
    } finally {
      isUpdating = false;
    }
  }

  async function handleAREffectSelection(effectId) {
    if (isUpdating) return;

    // Check if already active
    if (effectId === "none" && !isAREnabled) return;
    if (effectId !== "none" && isAREnabled && effectId === currentSelectedAREffect) return;

    isUpdating = true;

    if (effectId === "none") {
      statusMessage.textContent = "Disabling AR effect...";
      try {
        const response = await fetch("/api/ar/toggle", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          keepalive: true,
          body: JSON.stringify({ enabled: false }),
        });

        if (!response.ok) {
          throw new Error(`Server returned status ${response.status}`);
        }

        const result = await response.json();
        if (result.status !== "success") {
          throw new Error(result.error || "Failed to disable AR");
        }

        setActiveARUI("none", false);
        statusMessage.textContent = "Live AR effect disabled (None).";
      } catch (err) {
        console.error("Failed to disable AR:", err);
        statusMessage.textContent = "Failed to disable AR effect. Please try again.";
      } finally {
        isUpdating = false;
      }
    } else {
      const displayName = (arEffectsMap[effectId] && arEffectsMap[effectId].name) || effectId;
      statusMessage.textContent = `Applying ${displayName}...`;
      try {
        const response = await fetch("/api/ar/select-effect", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          keepalive: true,
          body: JSON.stringify({ effect: effectId }),
        });

        if (!response.ok) {
          throw new Error(`Server returned status ${response.status}`);
        }

        const result = await response.json();
        if (result.status !== "success") {
          throw new Error(result.error || "Failed to select AR effect");
        }

        setActiveARUI(effectId, true);
        statusMessage.textContent = `Selected AR Effect: ${displayName}!`;
      } catch (err) {
        console.error("Failed to select AR effect:", err);
        statusMessage.textContent = `Failed to apply ${displayName}. Please try again.`;
      } finally {
        isUpdating = false;
      }
    }
  }

  // Bind tab buttons
  if (tabThemes) {
    tabThemes.addEventListener("click", (e) => {
      e.preventDefault();
      switchTab("themes");
    });
  }

  if (tabAREffects) {
    tabAREffects.addEventListener("click", (e) => {
      e.preventDefault();
      switchTab("ar");
    });
  }

  if (tabFilters) {
    tabFilters.addEventListener("click", (e) => {
      e.preventDefault();
      switchTab("filters");
    });
  }

  // Bind touch and click events to theme cards
  themeCards.forEach((card) => {
    const themeName = card.dataset.theme;
    card.addEventListener("click", (e) => {
      e.preventDefault();
      handleThemeSelection(themeName);
    });
  });

  // Bind touch and click events to filter cards
  filterCards.forEach((card) => {
    const filterName = card.dataset.filter;
    card.addEventListener("click", (e) => {
      e.preventDefault();
      handleFilterSelection(filterName);
    });
  });

  // Safeguard Back to Photo Booth navigation
  if (btnBackToBooth) {
    btnBackToBooth.addEventListener("click", (e) => {
      e.preventDefault();
      const targetUrl = btnBackToBooth.getAttribute("href") || BOOTH_HOME_URL;
      const safeTarget = (!targetUrl || targetUrl === "#") ? BOOTH_HOME_URL : targetUrl;

      if (isUpdating) {
        statusMessage.textContent = "Saving selection, returning to booth...";
        const checkInterval = setInterval(() => {
          if (!isUpdating) {
            clearInterval(checkInterval);
            window.location.href = safeTarget;
          }
        }, 100);
        setTimeout(() => {
          clearInterval(checkInterval);
          window.location.href = safeTarget;
        }, 3000);
      } else {
        window.location.href = safeTarget;
      }
    });
  }

  // Initial load
  loadCurrentState();
});

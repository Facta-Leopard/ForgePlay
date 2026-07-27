(() => {
  "use strict";

  const databaseURL = "site-data/developer-apps.json";
  const platforms = new Set(["mac", "ipad", "iphone"]);
  const grid = document.querySelector("[data-developer-app-grid]");
  const count = document.querySelector("[data-developer-app-count]");
  const errorState = document.querySelector("[data-developer-app-error]");
  const platformButtons = document.querySelectorAll("[data-developer-platform]");
  let database = null;
  let selectedPlatform = "mac";

  const site = () => window.ForgePlaySite;
  const locale = () => site()?.getLocale() || document.documentElement.lang || "en";
  const message = (key, fallback = "") => site()?.message(key) || fallback;

  const localizedText = (value, selectedLocale) => {
    if (!value) return "";
    if (typeof value === "string") return value;
    return value[selectedLocale] || value.en || value.ko || Object.values(value)[0] || "";
  };

  const formattedMessage = (key, fallback, values = {}) => {
    return Object.entries(values).reduce(
      (result, [name, value]) => result.replaceAll(`{${name}}`, String(value)),
      message(key, fallback)
    );
  };

  const appendTextElement = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };

  const renderPlatformState = () => {
    platformButtons.forEach((button) => {
      const isSelected = button.dataset.developerPlatform === selectedPlatform;
      button.setAttribute("aria-selected", String(isSelected));
      button.tabIndex = isSelected ? 0 : -1;
    });
  };

  const renderCard = (app, selectedLocale) => {
    const article = document.createElement("article");
    article.className = "developer-app-card";

    const heading = document.createElement("div");
    heading.className = "developer-app-heading";

    const artwork = document.createElement("img");
    artwork.className = "developer-app-artwork";
    artwork.src = app.artwork;
    artwork.width = 512;
    artwork.height = 512;
    artwork.loading = "lazy";
    artwork.decoding = "async";
    artwork.alt = formattedMessage(
      "developerApps.artworkAlt",
      "{name} app icon",
      { name: app.name }
    );

    const identity = document.createElement("div");
    identity.className = "developer-app-identity";
    appendTextElement(identity, "h3", "", app.name);

    const badges = document.createElement("div");
    badges.className = "developer-app-badges";
    appendTextElement(
      badges,
      "span",
      "developer-app-badge",
      message(`developerApps.platform${app.platform[0].toUpperCase()}${app.platform.slice(1)}`, app.platform)
    );
    if (app.kind === "game") {
      appendTextElement(
        badges,
        "span",
        "developer-app-badge game",
        message("developerApps.kindGame", "Game")
      );
    }
    if (app.appleSiliconMacCompatible) {
      appendTextElement(
        badges,
        "span",
        "developer-app-badge compatible",
        message("developerApps.macCompatible", "Apple Silicon Mac compatible")
      );
    }
    identity.append(badges);
    heading.append(artwork, identity);
    article.append(heading);

    appendTextElement(
      article,
      "p",
      "developer-app-summary",
      localizedText(app.summaries, selectedLocale)
    );

    const link = appendTextElement(
      article,
      "a",
      "developer-app-link",
      message("developerApps.appStoreLink", "View on the App Store ↗")
    );
    link.href = app.href;
    link.target = "_blank";
    link.rel = "noreferrer";

    return article;
  };

  const render = () => {
    if (!database || !grid) return;
    const selectedLocale = locale();
    const apps = database.apps.filter((app) => app.platform === selectedPlatform);
    const fragment = document.createDocumentFragment();
    apps.forEach((app) => fragment.append(renderCard(app, selectedLocale)));
    grid.replaceChildren(fragment);
    grid.setAttribute("aria-busy", "false");
    renderPlatformState();
    if (count) {
      count.textContent = formattedMessage(
        "developerApps.count",
        "{count} apps",
        { count: apps.length }
      );
    }
  };

  const selectPlatform = (platform) => {
    if (!platforms.has(platform)) return;
    selectedPlatform = platform;
    render();
  };

  platformButtons.forEach((button) => {
    button.addEventListener("click", () => {
      selectPlatform(button.dataset.developerPlatform);
    });
    button.addEventListener("keydown", (event) => {
      if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
      event.preventDefault();
      const orderedPlatforms = [...platformButtons].map(
        (candidate) => candidate.dataset.developerPlatform
      );
      const direction = event.key === "ArrowRight" ? 1 : -1;
      const currentIndex = orderedPlatforms.indexOf(selectedPlatform);
      const nextIndex = (
        currentIndex + direction + orderedPlatforms.length
      ) % orderedPlatforms.length;
      selectPlatform(orderedPlatforms[nextIndex]);
      platformButtons[nextIndex].focus();
    });
  });

  const load = async () => {
    try {
      const response = await fetch(databaseURL, {
        headers: { Accept: "application/json" }
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      database = await response.json();
      render();
    } catch {
      if (grid) {
        grid.replaceChildren();
        grid.setAttribute("aria-busy", "false");
      }
      if (errorState) {
        errorState.hidden = false;
        errorState.textContent = message(
          "developerApps.dataError",
          "The app catalog could not be loaded."
        );
      }
    }
  };

  document.addEventListener("forgeplay:localechange", render);
  load();
})();

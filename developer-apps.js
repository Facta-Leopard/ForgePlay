(() => {
  "use strict";

  const cacheBustedDataURL = (path) => {
    const url = new URL(path, document.baseURI);
    url.searchParams.set("refresh", Date.now().toString());
    return url.href;
  };

  const databaseURL = cacheBustedDataURL("site-data/developer-apps.json");
  const platforms = new Set(["mac", "ipad", "iphone"]);
  const views = new Set(["catalog", "development"]);
  const grid = document.querySelector("[data-developer-app-grid]");
  const count = document.querySelector("[data-developer-app-count]");
  const errorState = document.querySelector("[data-developer-app-error]");
  const platformButtons = document.querySelectorAll("[data-developer-platform]");
  const viewButtons = document.querySelectorAll("[data-developer-view]");
  let database = null;
  let selectedPlatform = "mac";
  let selectedView = "catalog";

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

  const localizedHref = (href, selectedLocale) => {
    if (!href || /^[a-z][a-z0-9+.-]*:/i.test(href)) return href;
    const [pathAndQuery, fragment = ""] = href.split("#", 2);
    const [path] = pathAndQuery.split("?", 1);
    return `${path}?lang=${encodeURIComponent(selectedLocale)}${fragment ? `#${fragment}` : ""}`;
  };

  const appendTextElement = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };

  const renderTabState = (buttons, datasetKey, selectedValue) => {
    buttons.forEach((button) => {
      const isSelected = button.dataset[datasetKey] === selectedValue;
      button.setAttribute("aria-selected", String(isSelected));
      button.tabIndex = isSelected ? 0 : -1;
    });
  };

  const renderArtwork = (entry) => {
    const artwork = document.createElement("img");
    artwork.className = "developer-app-artwork";
    artwork.src = entry.artwork;
    artwork.width = 512;
    artwork.height = 512;
    artwork.loading = "lazy";
    artwork.decoding = "async";
    artwork.alt = formattedMessage(
      "developerApps.artworkAlt",
      "{name} app icon",
      { name: entry.name }
    );
    return artwork;
  };

  const appendBadge = (parent, className, label) => {
    appendTextElement(parent, "span", `developer-app-badge ${className}`.trim(), label);
  };

  const renderAppCard = (app, selectedLocale) => {
    const article = document.createElement("article");
    article.className = "developer-app-card";

    const heading = document.createElement("div");
    heading.className = "developer-app-heading";

    const identity = document.createElement("div");
    identity.className = "developer-app-identity";
    appendTextElement(identity, "h3", "", app.name);

    const badges = document.createElement("div");
    badges.className = "developer-app-badges";
    appendBadge(
      badges,
      "",
      message(`developerApps.platform${app.platform[0].toUpperCase()}${app.platform.slice(1)}`, app.platform)
    );
    if (app.kind === "game") {
      appendBadge(
        badges,
        "game",
        message("developerApps.kindGame", "Game")
      );
    }
    if (app.appleSiliconMacCompatible) {
      appendBadge(
        badges,
        "compatible",
        message("developerApps.macCompatible", "Apple Silicon Mac compatible")
      );
    }
    identity.append(badges);
    heading.append(renderArtwork(app), identity);
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
      app.appStoreID
        ? message("developerApps.appStoreLink", "View on the App Store ↗")
        : message("developerApps.homepageLink", "Open homepage ↗")
    );
    link.href = localizedHref(app.href, selectedLocale);
    if (/^https?:/i.test(app.href)) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    }

    return article;
  };

  const renderProjectCard = (project, selectedLocale) => {
    const article = document.createElement("article");
    article.className = "developer-app-card developer-project-card";

    const heading = document.createElement("div");
    heading.className = "developer-app-heading";

    const identity = document.createElement("div");
    identity.className = "developer-app-identity";
    appendTextElement(identity, "h3", "", project.name);

    const badges = document.createElement("div");
    badges.className = "developer-app-badges";
    appendBadge(
      badges,
      "development",
      message("developerApps.inDevelopment", "In Development")
    );
    appendBadge(
      badges,
      project.kind === "game"
        ? "game"
        : project.kind === "utility" ? "utility" : "",
      project.kind === "game"
        ? message("developerApps.kindGame", "Game")
        : project.kind === "utility"
          ? message("developerApps.kindUtility", "Utility")
          : message("developerApps.kindApp", "App")
    );
    identity.append(badges);
    heading.append(renderArtwork(project), identity);
    article.append(heading);

    const summary = localizedText(project.summaries, selectedLocale);
    if (summary) {
      appendTextElement(article, "p", "developer-app-summary", summary);
    }

    return article;
  };

  const renderCard = (entry, selectedLocale) => (
    selectedView === "development"
      ? renderProjectCard(entry, selectedLocale)
      : renderAppCard(entry, selectedLocale)
  );

  const render = () => {
    if (!database || !grid) return;
    const selectedLocale = locale();
    const collection = selectedView === "development"
      ? (database.inDevelopment || [])
      : (database.apps || []);
    const entries = collection.filter((entry) => entry.platform === selectedPlatform);
    const fragment = document.createDocumentFragment();
    entries.forEach((entry) => fragment.append(renderCard(entry, selectedLocale)));
    if (entries.length === 0) {
      appendTextElement(
        fragment,
        "p",
        "developer-app-empty",
        message("developerApps.emptyDevelopment", "No projects are currently in development for this device.")
      );
    }
    grid.replaceChildren(fragment);
    grid.setAttribute("aria-busy", "false");
    renderTabState(platformButtons, "developerPlatform", selectedPlatform);
    renderTabState(viewButtons, "developerView", selectedView);
    if (count) {
      const isSingular = entries.length === 1;
      const countKey = selectedView === "development"
        ? isSingular ? "developerApps.projectCountOne" : "developerApps.projectCount"
        : isSingular ? "developerApps.countOne" : "developerApps.count";
      const countFallback = selectedView === "development"
        ? isSingular ? "{count} project" : "{count} projects"
        : isSingular ? "{count} app" : "{count} apps";
      count.textContent = formattedMessage(
        countKey,
        countFallback,
        { count: entries.length }
      );
    }
  };

  const selectPlatform = (platform) => {
    if (!platforms.has(platform)) return;
    selectedPlatform = platform;
    render();
  };

  const selectView = (view) => {
    if (!views.has(view)) return;
    selectedView = view;
    render();
  };

  const bindTabs = (buttons, datasetKey, select) => {
    buttons.forEach((button) => {
      button.addEventListener("click", () => select(button.dataset[datasetKey]));
      button.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
        event.preventDefault();
        const orderedValues = [...buttons].map(
          (candidate) => candidate.dataset[datasetKey]
        );
        const direction = event.key === "ArrowRight" ? 1 : -1;
        const currentIndex = orderedValues.indexOf(button.dataset[datasetKey]);
        const nextIndex = (
          currentIndex + direction + orderedValues.length
        ) % orderedValues.length;
        select(orderedValues[nextIndex]);
        buttons[nextIndex].focus();
      });
    });
  };

  bindTabs(platformButtons, "developerPlatform", selectPlatform);
  bindTabs(viewButtons, "developerView", selectView);

  const load = async () => {
    try {
      const response = await fetch(databaseURL, {
        cache: "no-store",
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

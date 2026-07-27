(() => {
  "use strict";

  const databaseURL = "site-data/announcements.json";
  const typeMessageKeys = {
    compatibility: "updates.typeCompatibility",
    project: "updates.typeProject",
    release: "updates.typeRelease"
  };

  const latestCards = document.querySelectorAll("[data-latest-announcement]");
  const list = document.querySelector("[data-announcement-list]");
  const emptyState = document.querySelector("[data-announcement-empty]");
  const errorState = document.querySelector("[data-announcement-error]");
  let database = null;

  const site = () => window.ForgePlaySite;
  const locale = () => site()?.getLocale() || document.documentElement.lang || "en";
  const message = (key, fallback = "") => site()?.message(key) || fallback;

  const localizedText = (value, selectedLocale) => {
    if (!value) return "";
    if (typeof value === "string") return value;
    return value[selectedLocale] || value.en || value.ko || Object.values(value)[0] || "";
  };

  const formatDate = (value, selectedLocale) => {
    const date = new Date(`${value}T00:00:00Z`);
    if (Number.isNaN(date.valueOf())) return value;
    return new Intl.DateTimeFormat(selectedLocale, {
      year: "numeric",
      month: "short",
      day: "numeric",
      timeZone: "UTC"
    }).format(date);
  };

  const localizedHref = (href, selectedLocale) => {
    if (!href || href.startsWith("#") || /^[a-z][a-z0-9+.-]*:/i.test(href)) {
      return href;
    }
    const [pathAndQuery, fragment = ""] = href.split("#", 2);
    const [path] = pathAndQuery.split("?", 1);
    return `${path}?lang=${encodeURIComponent(selectedLocale)}${fragment ? `#${fragment}` : ""}`;
  };

  const sortedAnnouncements = () => {
    return [...(database?.announcements || [])].sort((left, right) => {
      const featuredDifference = Number(right.featured) - Number(left.featured);
      if (featuredDifference !== 0) return featuredDifference;
      return right.publishedAt.localeCompare(left.publishedAt);
    });
  };

  const renderLatest = (announcement, selectedLocale) => {
    latestCards.forEach((card) => {
      const type = card.querySelector("[data-announcement-type]");
      const date = card.querySelector("[data-announcement-date]");
      const title = card.querySelector("[data-announcement-title]");
      const summary = card.querySelector("[data-announcement-summary]");
      const link = card.querySelector("[data-announcement-link]");
      if (type) {
        type.textContent = message(
          typeMessageKeys[announcement.type],
          announcement.type
        );
      }
      if (date) date.textContent = formatDate(announcement.publishedAt, selectedLocale);
      if (title) title.textContent = localizedText(announcement.titles, selectedLocale);
      if (summary) summary.textContent = localizedText(announcement.summaries, selectedLocale);
      if (link) link.href = localizedHref(announcement.href, selectedLocale);
    });
  };

  const appendTextElement = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };

  const renderList = (announcements, selectedLocale) => {
    if (!list) return;
    const fragment = document.createDocumentFragment();
    announcements.forEach((announcement, index) => {
      const article = document.createElement("article");
      article.className = "update-card";
      article.dataset.type = announcement.type;

      const meta = document.createElement("div");
      meta.className = "update-card-meta";
      appendTextElement(meta, "span", "update-card-index", String(index + 1).padStart(2, "0"));
      appendTextElement(
        meta,
        "span",
        "update-card-type",
        message(typeMessageKeys[announcement.type], announcement.type)
      );
      appendTextElement(
        meta,
        "time",
        "update-card-date",
        formatDate(announcement.publishedAt, selectedLocale)
      ).dateTime = announcement.publishedAt;

      const copy = document.createElement("div");
      copy.className = "update-card-copy";
      appendTextElement(copy, "h2", "", localizedText(announcement.titles, selectedLocale));
      appendTextElement(copy, "p", "", localizedText(announcement.summaries, selectedLocale));

      const link = appendTextElement(
        copy,
        "a",
        "text-link update-card-link",
        message("updates.openLink", "Open update ↗")
      );
      link.href = localizedHref(announcement.href, selectedLocale);

      article.append(meta, copy);
      fragment.append(article);
    });

    list.replaceChildren(fragment);
    list.setAttribute("aria-busy", "false");
    if (emptyState) emptyState.hidden = announcements.length !== 0;
  };

  const render = () => {
    if (!database) return;
    const selectedLocale = locale();
    const announcements = sortedAnnouncements();
    if (announcements[0]) renderLatest(announcements[0], selectedLocale);
    renderList(announcements, selectedLocale);
  };

  const load = async () => {
    try {
      const response = await fetch(databaseURL, {
        headers: { Accept: "application/json" }
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      database = await response.json();
      render();
    } catch {
      if (list) {
        list.replaceChildren();
        list.setAttribute("aria-busy", "false");
      }
      if (errorState) {
        errorState.hidden = false;
        errorState.textContent = message(
          "updates.dataError",
          "Updates could not be loaded."
        );
      }
    }
  };

  document.addEventListener("forgeplay:localechange", render);
  load();
})();

(() => {
  "use strict";

  const cacheBustedDataURL = (path) => {
    const url = new URL(path, document.baseURI);
    url.searchParams.set("refresh", Date.now().toString());
    return url.href;
  };

  const databaseURL = cacheBustedDataURL("site-data/announcements.json");
  const typeMessageKeys = {
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

  const localizedParagraphs = (value, selectedLocale) => {
    if (!value || typeof value !== "object") return [];
    const paragraphs = (
      value[selectedLocale]
      || value.en
      || value.ko
      || Object.values(value)[0]
    );
    return Array.isArray(paragraphs)
      ? paragraphs.filter((paragraph) => (
        typeof paragraph === "string" && paragraph.trim()
      ))
      : [];
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

  const announcementAnchorId = (identifier) => `update-${identifier}`;
  const announcementDetailHref = (identifier) => (
    `updates.html#${announcementAnchorId(identifier)}`
  );

  const localizedHref = (href, selectedLocale) => {
    if (!href || href.startsWith("#") || /^[a-z][a-z0-9+.-]*:/i.test(href)) {
      return href;
    }
    const [pathAndQuery, fragment = ""] = href.split("#", 2);
    const [path] = pathAndQuery.split("?", 1);
    return `${path}?lang=${encodeURIComponent(selectedLocale)}${fragment ? `#${fragment}` : ""}`;
  };

  const applyLinkDestination = (link, href, selectedLocale) => {
    if (!link) return;
    const destination = localizedHref(href, selectedLocale);
    link.href = destination;
    if (/^https?:/i.test(destination)) {
      link.target = "_blank";
      link.rel = "noopener noreferrer";
    } else {
      link.removeAttribute("target");
      link.removeAttribute("rel");
    }
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
      applyLinkDestination(link, announcement.href, selectedLocale);
    });
  };

  const appendTextElement = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };

  const bulletLinePattern = /^(\s*)-\s+(.+)$/;

  const appendBulletList = (parent, lines) => {
    const rootList = document.createElement("ul");
    rootList.className = "update-card-list";
    const stack = [{ indentation: 0, list: rootList, lastItem: null }];

    lines.forEach((line) => {
      const match = bulletLinePattern.exec(line);
      if (!match) return;
      const indentation = match[1].replaceAll("\t", "  ").length;

      while (stack.length > 1 && indentation < stack.at(-1).indentation) {
        stack.pop();
      }

      let context = stack.at(-1);
      if (indentation > context.indentation && context.lastItem) {
        const nestedList = document.createElement("ul");
        context.lastItem.append(nestedList);
        context = { indentation, list: nestedList, lastItem: null };
        stack.push(context);
      }

      const item = appendTextElement(context.list, "li", "", match[2]);
      context.lastItem = item;
    });

    parent.append(rootList);
  };

  const appendStructuredParagraph = (parent, paragraph) => {
    const trimmed = paragraph.trim();
    if (trimmed.startsWith("## ")) {
      appendTextElement(parent, "h3", "update-card-section-title", trimmed.slice(3));
      return;
    }
    if (trimmed === "---") {
      const divider = document.createElement("hr");
      divider.className = "update-card-divider";
      parent.append(divider);
      return;
    }

    const lines = trimmed.split(/\r?\n/);
    if (lines.length && lines.every((line) => bulletLinePattern.test(line))) {
      appendBulletList(parent, lines);
      return;
    }

    appendTextElement(
      parent,
      "p",
      trimmed.startsWith("※") ? "update-card-note" : "",
      trimmed
    );
  };

  const renderList = (announcements, selectedLocale) => {
    if (!list) return;
    const fragment = document.createDocumentFragment();
    announcements.forEach((announcement, index) => {
      const article = document.createElement("article");
      article.className = "update-card";
      article.id = announcementAnchorId(announcement.id);
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
      const paragraphs = localizedParagraphs(announcement.paragraphs, selectedLocale);
      if (paragraphs.length) {
        const body = document.createElement("div");
        body.className = "update-card-body";
        paragraphs.forEach((paragraph) => appendStructuredParagraph(body, paragraph));
        copy.append(body);
      } else {
        appendTextElement(copy, "p", "", localizedText(announcement.summaries, selectedLocale));
      }

      if (announcement.href !== announcementDetailHref(announcement.id)) {
        const link = appendTextElement(
          copy,
          "a",
          "text-link update-card-link",
          message("updates.openLink", "Open update ↗")
        );
        applyLinkDestination(link, announcement.href, selectedLocale);
      }

      article.append(meta, copy);
      fragment.append(article);
    });

    list.replaceChildren(fragment);
    list.setAttribute("aria-busy", "false");
    if (emptyState) emptyState.hidden = announcements.length !== 0;

    const requestedCard = document.getElementById(window.location.hash.slice(1));
    if (requestedCard?.classList.contains("update-card")) {
      window.requestAnimationFrame(() => requestedCard.scrollIntoView({ block: "center" }));
    }
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
        cache: "no-store",
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

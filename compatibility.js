(() => {
  "use strict";

  const databaseURL = "site-data/compatibility-games.json";
  const statusMessageKeys = {
    playable: "compat.statusPlayable",
    testing: "compat.statusTesting",
    blocked: "compat.statusBlocked",
    unknown: "compat.statusUnknown"
  };
  const blockerMessageKeys = {
    "anti-cheat": "compat.blockerAntiCheat",
    launcher: "compat.blockerLauncher",
    graphics: "compat.blockerGraphics",
    runtime: "compat.blockerRuntime",
    unknown: "compat.blockerUnknown"
  };

  const list = document.querySelector("[data-compatibility-list]");
  const search = document.querySelector("[data-compatibility-search]");
  const statusFilter = document.querySelector("[data-compatibility-status]");
  const emptyState = document.querySelector("[data-compatibility-empty]");
  const errorState = document.querySelector("[data-compatibility-error]");
  let database = null;

  const site = () => window.ForgePlaySite;
  const locale = () => site()?.getLocale() || document.documentElement.lang || "en";
  const message = (key, fallback = "") => site()?.message(key) || fallback;

  const localizedText = (value, selectedLocale) => {
    if (!value) return "";
    if (typeof value === "string") return value;
    return value[selectedLocale] || value.en || value.ko || Object.values(value)[0] || "";
  };

  const formatProfile = (profile) => {
    if (!profile) return "—";
    return `${profile.chip} · ${profile.unifiedMemoryGB}GB`;
  };

  const formatDate = (value, selectedLocale) => {
    if (!value) return "";
    const date = new Date(`${value}T00:00:00Z`);
    if (Number.isNaN(date.valueOf())) return value;
    return new Intl.DateTimeFormat(selectedLocale, {
      year: "numeric",
      month: "short",
      day: "numeric",
      timeZone: "UTC"
    }).format(date);
  };

  const appendTextElement = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };

  const makeCell = (className, label) => {
    const cell = document.createElement("div");
    cell.className = className;
    cell.dataset.label = label;
    return cell;
  };

  const updateSummary = () => {
    if (!database) return;
    const playableGameIds = new Set(
      database.reports
        .filter((report) => report.status === "playable")
        .map((report) => report.gameId)
    );
    document.querySelectorAll("[data-compatibility-count]").forEach((element) => {
      element.textContent = String(playableGameIds.size);
    });

    const firstProfile = database.testProfiles[0];
    document.querySelectorAll("[data-compatibility-device]").forEach((element) => {
      element.textContent = formatProfile(firstProfile);
    });
    document.querySelectorAll("[data-compatibility-updated]").forEach((element) => {
      element.textContent = formatDate(database.updatedAt, locale());
    });
  };

  const render = () => {
    if (!database) return;
    updateSummary();
    if (!list) return;

    const selectedLocale = locale();
    const query = (search?.value || "").trim().toLocaleLowerCase(selectedLocale);
    const selectedStatus = statusFilter?.value || "all";
    const games = new Map(database.games.map((game) => [game.id, game]));
    const profiles = new Map(database.testProfiles.map((profile) => [profile.id, profile]));
    const rows = database.reports
      .map((report) => ({
        report,
        game: games.get(report.gameId),
        profile: profiles.get(report.testProfileId)
      }))
      .filter(({ game, report }) => {
        if (!game) return false;
        if (selectedStatus !== "all" && report.status !== selectedStatus) return false;
        if (!query) return true;
        return Object.values(game.titles).some((title) => (
          title.toLocaleLowerCase(selectedLocale).includes(query)
        ));
      });

    const fragment = document.createDocumentFragment();
    rows.forEach(({ report, game, profile }, index) => {
      const row = document.createElement("article");
      row.className = "compatibility-row";
      row.dataset.status = report.status;

      const gameCell = makeCell(
        "compatibility-game-cell",
        message("compat.columnGame", "Game")
      );
      appendTextElement(gameCell, "span", "compatibility-index", String(index + 1).padStart(2, "0"));
      const titleWrap = document.createElement("div");
      const displayTitle = localizedText(game.titles, selectedLocale);
      appendTextElement(titleWrap, "h2", "", displayTitle);
      if (displayTitle !== game.titles.en) {
        appendTextElement(titleWrap, "span", "compatibility-official-title", game.titles.en);
      }
      gameCell.append(titleWrap);

      const statusCell = makeCell(
        "compatibility-status-cell",
        message("compat.columnStatus", "Status")
      );
      const status = appendTextElement(
        statusCell,
        "span",
        "compatibility-status",
        message(statusMessageKeys[report.status], report.status)
      );
      status.dataset.status = report.status;

      const deviceCell = makeCell(
        "compatibility-device-cell",
        message("compat.columnDevice", "Tested device")
      );
      appendTextElement(deviceCell, "strong", "", formatProfile(profile));
      appendTextElement(deviceCell, "span", "", profile?.platform || "—");

      const verificationCell = makeCell(
        "compatibility-verification-cell",
        message("compat.columnVerification", "Verification")
      );
      const sourceKey = report.source === "community-report"
        ? "compat.verificationCommunity"
        : "compat.verificationProject";
      appendTextElement(
        verificationCell,
        "strong",
        "",
        message(sourceKey, report.source)
      );
      appendTextElement(
        verificationCell,
        "span",
        "",
        report.testedAt
          ? formatDate(report.testedAt, selectedLocale)
          : message("compat.verificationInitial", "Initial test")
      );

      const notesCell = makeCell(
        "compatibility-notes-cell",
        message("compat.columnNotes", "Notes")
      );
      const note = report.blocker
        ? message(blockerMessageKeys[report.blocker], report.blocker)
        : localizedText(report.notes, selectedLocale)
          || message(
            report.status === "playable" ? "compat.notePlayable" : "compat.notePending",
            "No additional note."
          );
      notesCell.textContent = note;

      row.append(gameCell, statusCell, deviceCell, verificationCell, notesCell);
      fragment.append(row);
    });

    list.replaceChildren(fragment);
    list.setAttribute("aria-busy", "false");
    if (emptyState) emptyState.hidden = rows.length !== 0;
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
          "compat.dataError",
          "The compatibility database could not be loaded."
        );
      }
    }
  };

  search?.addEventListener("input", render);
  statusFilter?.addEventListener("change", render);
  document.addEventListener("forgeplay:localechange", render);
  load();
})();

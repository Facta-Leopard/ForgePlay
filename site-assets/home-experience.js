(() => {
  "use strict";
  const body = document.querySelector(".fp-home");
  if (!body) return;
  const site = () => window.ForgePlaySite;
  const message = (key) => site()?.message(key) || key;
  const locale = () => site()?.getLocale() || "en";
  const localized = (texts) => texts?.[locale()] || texts?.en || texts?.ko || "";
  const format = (key, count) => message(key).replace("{count}", String(count));

  document.querySelectorAll("[data-open-evidence]").forEach((link) => {
    link.addEventListener("click", () => {
      const evidence = document.querySelector("#difference");
      if (evidence) evidence.open = true;
    });
  });

  const tabs = [...document.querySelectorAll("[data-feature-tab]")];
  const panels = [...document.querySelectorAll("[data-feature-panel]")];
  const activate = (index, focus = false) => {
    tabs.forEach((tab, position) => {
      const active = position === index;
      tab.setAttribute("aria-selected", String(active));
      tab.tabIndex = active ? 0 : -1;
      panels[position].hidden = !active;
    });
    if (focus) tabs[index].focus();
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener("click", () => activate(index));
    tab.addEventListener("keydown", (event) => {
      let next;
      if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
      if (event.key === "ArrowLeft") next = (index + tabs.length - 1) % tabs.length;
      if (event.key === "Home") next = 0;
      if (event.key === "End") next = tabs.length - 1;
      if (next === undefined) return;
      event.preventDefault();
      activate(next, true);
    });
  });

  const grid = document.querySelector("[data-home-games]");
  const search = document.querySelector("[data-home-search]");
  const filters = [...document.querySelectorAll("[data-home-filter]")];
  const more = document.querySelector("[data-home-more]");
  const resultCount = document.querySelector("[data-home-result-count]");
  let catalog = null;
  let loadError = false;
  let selectedStatus = "all";
  let expanded = false;
  let openGameId = null;
  const statusOrder = ["playable", "testing", "blocked", "unknown"];
  const statusKey = {
    playable: "refresh.playable", blocked: "refresh.blocked",
    testing: "compat.statusTesting", unknown: "compat.statusUnknown"
  };
  const sourceKey = {
    "project-test": "compat.verificationProject",
    "github-issue": "compat.verificationGitHubIssue",
    "community-report": "compat.verificationCommunityReport"
  };

  const appendText = (parent, tag, className, text) => {
    const element = document.createElement(tag);
    if (className) element.className = className;
    element.textContent = text;
    parent.append(element);
    return element;
  };
  const gameRecords = (game) => catalog.reports.filter((report) => report.gameId === game.id);
  const gameStatus = (records) => statusOrder.find((status) => records.some((record) => record.status === status)) || "unknown";

  const renderRecord = (parent, report) => {
    const record = document.createElement("div");
    record.className = "fp-game-record";
    const heading = document.createElement("div");
    heading.className = "fp-game-record-heading";
    const profile = catalog.testProfiles.find((item) => item.id === report.testProfileId);
    const device = profile
      ? [profile.platform, profile.chip, profile.unifiedMemoryGB ? profile.unifiedMemoryGB + "GB" : "", profile.macOSVersion].filter(Boolean).join(" · ")
      : message("refresh.unknownDevice");
    appendText(heading, "strong", "", device);
    const version = report.forgePlayVersion === "development" ? message("compat.versionDevelopment") : report.forgePlayVersion || message("refresh.unknownVersion");
    appendText(heading, "span", "", "ForgePlay " + version + " · " + message(statusKey[report.status] || statusKey.unknown));
    record.append(heading);
    appendText(record, "p", "", localized(report.notes) || message("refresh.noReportNotes"));
    const attribution = [
      message(sourceKey[report.source] || "compat.verificationInitial"),
      report.reporter ? "@" + report.reporter : "",
      report.testedAt || ""
    ].filter(Boolean).join(" · ");
    appendText(record, "div", "fp-game-meta", attribution);
    parent.append(record);
  };

  const renderGames = () => {
    if (!catalog) {
      grid.replaceChildren();
      appendText(grid, "p", "fp-game-empty", message(loadError ? "refresh.loadError" : "refresh.loading"));
      grid.setAttribute("aria-busy", String(!loadError));
      return;
    }
    const query = search.value.trim().normalize("NFKC").toLocaleLowerCase();
    const games = catalog.games.map((game) => {
      const records = gameRecords(game);
      return {game, records, status:gameStatus(records)};
    }).filter(({game, status}) => (
      (selectedStatus === "all" || status === selectedStatus) &&
      (!query || Object.values(game.titles).some((title) => title.normalize("NFKC").toLocaleLowerCase().includes(query)))
    ));
    const visible = expanded || query ? games : games.slice(0, 6);
    const fragment = document.createDocumentFragment();
    visible.forEach(({game, records, status}, index) => {
      const details = document.createElement("details");
      details.className = "fp-game";
      details.dataset.status = status;
      details.dataset.gameId = game.id;
      details.open = openGameId === game.id;
      const summary = document.createElement("summary");
      appendText(summary, "span", "fp-game-number", String(index + 1).padStart(2, "0"));
      const copy = document.createElement("div");
      const title = locale() === "ko" ? game.titles.ko : game.titles.en;
      appendText(copy, "h3", "", title);
      if (locale() === "ko" && title !== game.titles.en) appendText(copy, "span", "fp-game-official", game.titles.en);
      const meta = document.createElement("div");
      meta.className = "fp-game-meta";
      appendText(meta, "span", "fp-game-status", "● " + message(statusKey[status]));
      appendText(meta, "span", "", format("refresh.records", records.length));
      copy.append(meta);
      summary.append(copy);
      appendText(summary, "span", "fp-game-arrow", "↗").setAttribute("aria-hidden", "true");
      details.append(summary);
      const reports = document.createElement("div");
      reports.className = "fp-game-records";
      reports.setAttribute("aria-label", message("refresh.reportDetails"));
      records.forEach((report) => renderRecord(reports, report));
      details.append(reports);
      details.addEventListener("toggle", () => {
        if (details.open) {
          openGameId = game.id;
          grid.querySelectorAll("details[open]").forEach((other) => {
            if (other !== details) other.open = false;
          });
        } else if (openGameId === game.id) openGameId = null;
      });
      fragment.append(details);
    });
    if (!visible.length) appendText(fragment, "p", "fp-game-empty", message("refresh.noResults"));
    grid.replaceChildren(fragment);
    grid.setAttribute("aria-busy", "false");
    resultCount.textContent = format("refresh.games", games.length);
    more.hidden = games.length <= 6 || Boolean(query);
    more.textContent = message(expanded ? "refresh.less" : "refresh.more");
    filters.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.homeFilter === selectedStatus)));
  };

  search.addEventListener("input", () => { openGameId = null; renderGames(); });
  filters.forEach((button) => button.addEventListener("click", () => {
    selectedStatus = button.dataset.homeFilter;
    expanded = false;
    openGameId = null;
    renderGames();
  }));
  more.addEventListener("click", () => {
    expanded = !expanded;
    openGameId = null;
    renderGames();
    if (!expanded) search.focus({preventScroll:false});
  });
  document.addEventListener("forgeplay:localechange", renderGames);
  renderGames();

  const load = async () => {
    try {
      const url = new URL("site-data/compatibility-games.json", document.baseURI);
      url.searchParams.set("refresh", Date.now().toString());
      const response = await fetch(url, {cache:"no-store", headers:{Accept:"application/json"}});
      if (!response.ok) throw new Error("HTTP " + response.status);
      const data = await response.json();
      if (data.schemaVersion !== 2 || !Array.isArray(data.games) || !Array.isArray(data.reports) || !Array.isArray(data.testProfiles)) throw new Error("Invalid compatibility catalog");
      catalog = data;
    } catch {
      loadError = true;
    }
    renderGames();
  };
  load();
})();

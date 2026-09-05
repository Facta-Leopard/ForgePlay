(() => {
  "use strict";

  const statusMessageKeys = {
    playable: "compat.statusPlayable",
    testing: "compat.statusTesting",
    blocked: "compat.statusBlocked",
    unknown: "compat.statusUnknown"
  };
  const statusPriority = ["playable", "testing", "blocked", "unknown"];
  const sourceMessageKeys = {
    "project-test": "compat.verificationProject",
    "github-issue": "compat.verificationGitHubIssue",
    "community-report": "compat.verificationCommunityReport"
  };
  const forgePlayVersionMessageKeys = {
    development: "compat.versionDevelopment"
  };
  const blockerMessageKeys = {
    "anti-cheat": "compat.blockerAntiCheat",
    launcher: "compat.blockerLauncher",
    graphics: "compat.blockerGraphics",
    runtime: "compat.blockerRuntime",
    "security-module": "compat.blockerSecurityModule",
    unknown: "compat.blockerUnknown"
  };

  const list = document.querySelector("[data-compatibility-list]");
  const search = document.querySelector("[data-compatibility-search]");
  const statusFilter = document.querySelector("[data-compatibility-status]");
  const emptyState = document.querySelector("[data-compatibility-empty]");
  const errorState = document.querySelector("[data-compatibility-error]");
  let database = null;

  const site = () => window.ForgePlaySite;
  const catalog = () => window.ForgePlayWebCatalog;
  const currentVersion = () => database?.currentRelease?.marketingVersion || null;
  const locale = () => site()?.getLocale() || document.documentElement.lang || "en";
  const message = (key, fallback = "") => site()?.message(key) || fallback;

  const localizedText = (value, selectedLocale) => {
    if (!value) return "";
    if (typeof value === "string") return value;
    return value[selectedLocale] || value.en || value.ko || Object.values(value)[0] || "";
  };

  const formatNumber = (value, selectedLocale = locale()) => (
    new Intl.NumberFormat(selectedLocale).format(value)
  );

  const formatCountMessage = (key, count, fallback) => (
    message(key, fallback).replace("{count}", formatNumber(count))
  );

  const formatProfile = (profile) => {
    if (!profile) return message("compat.deviceNotReported", "Not provided");
    const memory = Number.isInteger(profile.unifiedMemoryGB)
      ? " · " + profile.unifiedMemoryGB + "GB"
      : "";
    return profile.chip + memory;
  };

  const formatProfilePlatform = (profile) => (
    profile && typeof profile.platform === "string"
      ? profile.platform.trim()
      : ""
  );

  const formatMacOSVersion = (profile) => (
    profile
    && typeof profile.macOSVersion === "string"
    && profile.macOSVersion.trim()
      ? profile.macOSVersion.trim()
      : message("compat.versionNotReported", "Version not provided")
  );

  const formatDate = (value, selectedLocale) => {
    if (!value) return "";
    const date = new Date(value + "T00:00:00Z");
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

  const reportNote = (report, selectedLocale) => {
    const localizedNote = localizedText(report.notes, selectedLocale);
    return localizedNote
      || (report.blocker
        ? message(blockerMessageKeys[report.blocker], report.blocker)
        : message(
          report.status === "playable" ? "compat.notePlayable" : "compat.notePending",
          "No additional note."
        ));
  };

  const sortRecords = (records) => {
    const recordsByReport = new Map(records.map((record) => [record.report, record]));
    return catalog().sortReports(records.map(({ report }) => report))
      .map((report) => recordsByReport.get(report));
  };

  const reportVersion = (report) => {
    const version = typeof report.forgePlayVersion === "string"
      ? report.forgePlayVersion.trim()
      : "";
    if (!version) {
      return message("compat.versionNotReported", "Version not provided");
    }
    const versionMessageKey = forgePlayVersionMessageKeys[version];
    return versionMessageKey
      ? message(versionMessageKey, "Development build")
      : version;
  };

  const gameVersion = (report) => (
    typeof report.gameVersion === "string" && report.gameVersion.trim()
      ? report.gameVersion.trim()
      : message("compat.gameVersionNotReported", "Game version not provided")
  );

  const appendVersionBadges = (cell, records, resolveVersion) => {
    const seenVersions = new Set();
    records.forEach((record) => {
      const version = resolveVersion(record);
      if (seenVersions.has(version)) return;
      seenVersions.add(version);
      appendTextElement(cell, "span", "compatibility-version", version);
    });
    if (!seenVersions.size) {
      appendTextElement(cell, "span", "compatibility-version-empty", "—");
    }
  };

  const verificationDetails = (report, selectedLocale) => {
    const details = [
      report.reporter ? "@" + report.reporter : null,
      report.testedAt
        ? formatDate(report.testedAt, selectedLocale)
        : report.reporter
          ? null
          : message("compat.verificationInitial", "Initial verification")
    ].filter(Boolean);
    return details.join(" · ");
  };

  const makeRecordCell = (className, label) => (
    makeCell("compatibility-record-cell " + className, label)
  );

  const makeReportRecord = ({ report, profile }, selectedLocale) => {
    const record = document.createElement("div");
    record.className = "compatibility-record";
    record.dataset.status = report.status;

    const statusCell = makeRecordCell(
      "compatibility-record-status-cell",
      message("compat.columnStatus", "Status")
    );
    const status = appendTextElement(
      statusCell,
      "span",
      "compatibility-status",
      message(statusMessageKeys[report.status], report.status)
    );
    status.dataset.status = report.status;

    const forgePlayVersionCell = makeRecordCell(
      "compatibility-record-version-cell",
      message("compat.columnForgePlayVersion", "ForgePlay version")
    );
    appendTextElement(forgePlayVersionCell, "strong", "", reportVersion(report));

    const gameVersionCell = makeRecordCell(
      "compatibility-record-version-cell",
      message("compat.columnGameVersion", "Game version")
    );
    appendTextElement(gameVersionCell, "strong", "", gameVersion(report));

    const deviceCell = makeRecordCell(
      "compatibility-device-cell",
      message("compat.columnDevice", "Tested device")
    );
    appendTextElement(deviceCell, "strong", "", formatProfile(profile));
    const profilePlatform = formatProfilePlatform(profile);
    if (profilePlatform) {
      appendTextElement(deviceCell, "span", "", profilePlatform);
    }

    const macOSVersionCell = makeRecordCell(
      "compatibility-record-version-cell compatibility-record-macos-cell",
      message("compat.columnMacOSVersion", "macOS version")
    );
    appendTextElement(
      macOSVersionCell,
      "strong",
      "",
      formatMacOSVersion(profile)
    );

    const verificationCell = makeRecordCell(
      "compatibility-verification-cell",
      message("compat.columnVerification", "Verification")
    );
    appendTextElement(
      verificationCell,
      "strong",
      "",
      message(sourceMessageKeys[report.source], report.source)
    );
    const details = verificationDetails(report, selectedLocale);
    if (details) appendTextElement(verificationCell, "span", "", details);
    if (database.websiteReportIds.includes(report.id)) {
      appendTextElement(
        verificationCell,
        "span",
        "compatibility-web-report-label",
        message("compat.webReportsLabel", "Website community report")
      );
    }

    const notesCell = makeRecordCell(
      "compatibility-record-notes-cell",
      message("compat.columnNotes", "Notes")
    );
    notesCell.textContent = reportNote(report, selectedLocale);

    record.append(
      statusCell,
      forgePlayVersionCell,
      gameVersionCell,
      deviceCell,
      macOSVersionCell,
      verificationCell,
      notesCell
    );
    return record;
  };

  const updateSummary = () => {
    if (!database) return;
    const reportsByGame = new Map();
    database.reports.forEach((report) => {
      if (!reportsByGame.has(report.gameId)) reportsByGame.set(report.gameId, []);
      reportsByGame.get(report.gameId).push(report);
    });
    const playableCount = [...reportsByGame.values()].filter((reports) => (
      catalog().summarize(reports, currentVersion()).status === "playable"
    )).length;
    document.querySelectorAll("[data-compatibility-count]").forEach((element) => {
      element.textContent = String(playableCount);
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
    const profiles = new Map(
      database.testProfiles.map((profile) => [profile.id, profile])
    );
    const recordsByGame = new Map();

    database.reports.forEach((report, databaseIndex) => {
      if (!recordsByGame.has(report.gameId)) recordsByGame.set(report.gameId, []);
      recordsByGame.get(report.gameId).push({
        report,
        profile: profiles.get(report.testProfileId),
        databaseIndex
      });
    });

    const groups = database.games
      .map((game, gameIndex) => {
        const records = recordsByGame.get(game.id) || [];
        const summary = catalog().summarize(
          records.map(({ report }) => report),
          currentVersion()
        );
        return {
          game,
          gameIndex,
          records,
          summary,
          status: summary.status
        };
      })
      .filter(({ game, records, status }) => {
        if (!records.length) return false;
        if (selectedStatus !== "all" && status !== selectedStatus) return false;
        if (!query) return true;
        return Object.values(game.titles).some((title) => (
          title.toLocaleLowerCase(selectedLocale).includes(query)
        ));
      })
      .sort((left, right) => {
        const statusDifference = (
          statusPriority.indexOf(left.status)
          - statusPriority.indexOf(right.status)
        );
        return statusDifference || left.gameIndex - right.gameIndex;
      });

    const fragment = document.createDocumentFragment();
    groups.forEach(({ game, records, status, summary }, index) => {
      const sortedRecords = sortRecords(records);
      const blockedRecords = sortedRecords.filter(({ report }) => (
        report.status === "blocked"
      ));
      const headlineReports = new Set(summary.headlineReports);
      const headlineRecords = sortedRecords.filter(({ report }) => (
        headlineReports.has(report)
      ));
      const description = catalog().describe(summary, message);

      const entry = document.createElement("article");
      entry.className = "compatibility-entry";
      entry.dataset.status = status;
      entry.dataset.tone = summary.tone;
      entry.dataset.gameId = game.id;

      const row = document.createElement("div");
      row.className = "compatibility-row";

      const gameCell = makeCell(
        "compatibility-game-cell",
        message("compat.columnGame", "Game")
      );
      appendTextElement(
        gameCell,
        "span",
        "compatibility-index",
        String(index + 1).padStart(2, "0")
      );
      const titleWrap = document.createElement("div");
      const displayTitle = localizedText(game.titles, selectedLocale);
      appendTextElement(titleWrap, "h2", "", displayTitle);
      if (displayTitle !== game.titles.en) {
        appendTextElement(
          titleWrap,
          "span",
          "compatibility-official-title",
          game.titles.en
        );
      }
      appendTextElement(
        titleWrap,
        "span",
        "compatibility-version-summary",
        description.versionText
      );
      gameCell.append(titleWrap);

      const statusCell = makeCell(
        "compatibility-status-cell",
        message("compat.columnStatus", "Status")
      );
      const statusBadge = appendTextElement(
        statusCell,
        "span",
        "compatibility-status",
        description.statusText
      );
      statusBadge.dataset.status = status;

      const panelId = "compatibility-records-" + game.id;
      let blockedButton = null;
      if (blockedRecords.length) {
        blockedButton = document.createElement("button");
        blockedButton.type = "button";
        blockedButton.className = "compatibility-blocked-button";
        blockedButton.setAttribute("aria-controls", panelId);
        blockedButton.setAttribute("aria-expanded", "false");
        const blockedRecordsLabel = formatCountMessage(
          "compat.blockedRecords",
          blockedRecords.length,
          "Blocked records · {count}"
        );
        blockedButton.setAttribute("aria-label", blockedRecordsLabel);
        blockedButton.textContent = blockedRecordsLabel + " ▼";
        statusCell.append(blockedButton);
      }

      const versionCell = makeCell(
        "compatibility-version-cell",
        message(
          "compat.columnTestedForgePlayVersions",
          "Tested ForgePlay versions"
        )
      );
      appendVersionBadges(
        versionCell,
        sortedRecords,
        ({ report }) => reportVersion(report)
      );

      const macOSVersionCell = makeCell(
        "compatibility-macos-version-cell",
        message("compat.columnMacOSVersion", "macOS version")
      );
      appendVersionBadges(
        macOSVersionCell,
        headlineRecords,
        ({ profile }) => formatMacOSVersion(profile)
      );

      const recordsCell = makeCell(
        "compatibility-record-count-cell",
        message("compat.columnRecords", "Records")
      );
      appendTextElement(
        recordsCell,
        "strong",
        "",
        formatCountMessage("compat.recordsCount", records.length, "{count} records")
      );
      appendTextElement(
        recordsCell,
        "span",
        "",
        message("compat.allRecords", "All records")
      );

      const summaryRecord = headlineRecords[0] || sortedRecords[0];
      const notesCell = makeCell(
        "compatibility-notes-cell",
        message("compat.columnNotes", "Notes")
      );
      if (description.warningText) {
        appendTextElement(
          notesCell,
          "p",
          "compatibility-version-warning",
          description.warningText
        );
      }
      appendTextElement(
        notesCell,
        "p",
        "compatibility-report-note",
        reportNote(summaryRecord.report, selectedLocale)
      );

      const expandCell = makeCell("compatibility-expand-cell", "");
      const expandButton = document.createElement("button");
      expandButton.type = "button";
      expandButton.className = "compatibility-expand-button";
      expandButton.setAttribute("aria-controls", panelId);
      expandButton.setAttribute("aria-expanded", "false");
      expandButton.setAttribute(
        "aria-label",
        formatCountMessage(
          "compat.showAllRecords",
          records.length,
          "Show all {count} records"
        )
      );
      expandButton.textContent = "⌄";
      expandCell.append(expandButton);

      row.append(
        gameCell,
        statusCell,
        versionCell,
        macOSVersionCell,
        recordsCell,
        notesCell,
        expandCell
      );

      const panel = document.createElement("div");
      panel.id = panelId;
      panel.className = "compatibility-record-panel";
      panel.hidden = true;
      const panelTitle = appendTextElement(
        panel,
        "p",
        "compatibility-record-panel-title",
        ""
      );
      const panelHead = document.createElement("div");
      panelHead.className = "compatibility-record-panel-head";
      panelHead.setAttribute("aria-hidden", "true");
      [
        message("compat.columnStatus", "Status"),
        message("compat.columnForgePlayVersion", "ForgePlay version"),
        message("compat.columnGameVersion", "Game version"),
        message("compat.columnDevice", "Tested device"),
        message("compat.columnMacOSVersion", "macOS version"),
        message("compat.columnVerification", "Verification"),
        message("compat.columnNotes", "Notes")
      ].forEach((label) => appendTextElement(panelHead, "span", "", label));
      const panelBody = document.createElement("div");
      panelBody.className = "compatibility-record-panel-body";
      panel.append(panelHead, panelBody);

      let activeMode = null;
      const closeLabel = message("compat.hideRecords", "Hide records");
      const renderPanel = (mode) => {
        const visibleRecords = mode === "blocked" ? blockedRecords : sortedRecords;
        panel.dataset.mode = mode;
        panelTitle.textContent = mode === "blocked"
          ? formatCountMessage(
            "compat.blockedRecords",
            visibleRecords.length,
            "Blocked records · {count}"
          )
          : formatCountMessage(
            "compat.allRecordsPanel",
            visibleRecords.length,
            "All records · {count}"
          );
        panelBody.replaceChildren(
          ...visibleRecords.map((record) => (
            makeReportRecord(record, selectedLocale)
          ))
        );
      };

      const updatePanelState = (mode) => {
        activeMode = activeMode === mode ? null : mode;
        panel.hidden = activeMode === null;
        if (activeMode) renderPanel(activeMode);

        if (blockedButton) {
          const blockedOpen = activeMode === "blocked";
          blockedButton.setAttribute("aria-expanded", String(blockedOpen));
          blockedButton.textContent = (
            formatCountMessage(
              "compat.blockedRecords",
              blockedRecords.length,
              "Blocked records · {count}"
            ) + (blockedOpen ? " ▲" : " ▼")
          );
          blockedButton.setAttribute(
            "aria-label",
            blockedOpen
              ? closeLabel
              : formatCountMessage(
                "compat.blockedRecords",
                blockedRecords.length,
                "Blocked records · {count}"
              )
          );
        }

        const allOpen = activeMode === "all";
        expandButton.setAttribute("aria-expanded", String(allOpen));
        expandButton.textContent = allOpen ? "⌃" : "⌄";
        expandButton.setAttribute(
          "aria-label",
          allOpen
            ? closeLabel
            : formatCountMessage(
              "compat.showAllRecords",
              records.length,
              "Show all {count} records"
            )
        );
      };

      blockedButton?.addEventListener("click", () => updatePanelState("blocked"));
      expandButton.addEventListener("click", () => updatePanelState("all"));

      entry.append(row, panel);
      fragment.append(entry);
    });

    list.replaceChildren(fragment);
    list.setAttribute("aria-busy", "false");
    if (emptyState) emptyState.hidden = groups.length !== 0;
  };

  const load = async () => {
    try {
      database = await catalog().load();
      document.querySelectorAll("[data-website-reports-scope]").forEach((element) => {
        element.hidden = database.websiteReportIds.length === 0;
      });
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

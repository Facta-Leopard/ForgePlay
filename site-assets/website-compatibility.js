(() => {
  "use strict";

  // Website-only additions never replace the catalog consumed by the app.
  const statusOrder = ["playable", "testing", "blocked", "unknown"];
  const platforms = Object.freeze(["steam", "battlenet", "epic", "stove", "exe", "vr", "unknown"]);
  const platformOf = report => platforms.includes(report.launchPlatform) ? report.launchPlatform : "unknown";
  const platformLabel = (platform, message) => ({
    steam:"Steam", battlenet:"Battle.net", epic:"Epic Games", stove:"STOVE",
    exe:message("compat.platformEXE"), vr:"VR", unknown:message("compat.platformUnknown")
  }[platform] || message("compat.platformUnknown"));
  // Both website lists use the assessed game status, not raw report/file order.
  // Equal-status games retain their existing relative order.
  const compareGameGroups = (left, right) => (
    statusOrder.indexOf(left.status) - statusOrder.indexOf(right.status)
  );
  const versionParts = (value) => {
    if (typeof value !== "string" || !/^\d+(?:\.\d+){1,2}$/.test(value)) return null;
    const parts = value.split(".").map(Number);
    while (parts.length < 3) parts.push(0);
    return parts;
  };
  const compareVersions = (left, right) => {
    const a = versionParts(left);
    const b = versionParts(right);
    if (!a || !b) return null;
    for (let i = 0; i < 3; i += 1) {
      if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
    }
    return 0;
  };
  const sortReports = (reports) => {
    // Reports are appended in publication order; later follow-ups lead when
    // their version, reported test date and status otherwise tie.
    const sourceOrder = new Map(reports.map((report, index) => [report, index]));
    return [...reports].sort((a, b) => {
    const version = compareVersions(a.forgePlayVersion, b.forgePlayVersion);
    if (version) return -version;
    if (version === null) {
      const numericDifference = Number(Boolean(versionParts(b.forgePlayVersion)))
        - Number(Boolean(versionParts(a.forgePlayVersion)));
      if (numericDifference) return numericDifference;
    }
    return (b.testedAt || "").localeCompare(a.testedAt || "")
      || statusOrder.indexOf(a.status) - statusOrder.indexOf(b.status)
      || sourceOrder.get(b) - sourceOrder.get(a);
    });
  };

  const summarize = (reports, currentVersion) => {
    const current = versionParts(currentVersion) ? currentVersion : null;
    const currentReports = current
      ? reports.filter((report) => compareVersions(report.forgePlayVersion, current) === 0)
      : [];
    const scope = currentReports.length ? currentReports : reports;
    const status = statusOrder.find((value) => scope.some((report) => report.status === value)) || "unknown";
    const headlineReports = sortReports(scope.filter((report) => report.status === status));
    const versions = [...new Set(headlineReports.map((report) => report.forgePlayVersion).filter(Boolean))];
    const tone = status === "playable" ? "green"
      : status === "blocked" && currentReports.length ? "red" : "yellow";
    let warningKey = null;
    if (status === "blocked" && tone === "yellow") {
      warningKey = !current ? "compat.currentVersionUnknown"
        : versions.length ? "compat.retestNeeded" : "compat.unversionedBlocked";
    }
    return {status, tone, versions, headlineReports, warningKey, currentVersion:current};
  };

  const describe = (summary, message) => {
    const versions = summary.versions.map((version) => version === "development"
      ? message("compat.versionDevelopment") : version).join(" · ")
      || message("compat.versionNotReported");
    const format = (key) => message(key)
      .replaceAll("{versions}", versions)
      .replaceAll("{current}", summary.currentVersion || message("compat.versionNotReported"));
    const statusKey = summary.status === "blocked"
      ? summary.tone === "red" ? "compat.currentBlocked" : "compat.legacyBlocked"
      : {playable:"compat.statusPlayable", testing:"compat.statusTesting", unknown:"compat.statusUnknown"}[summary.status];
    return {
      statusText: message(statusKey),
      versionText: format("compat.testedVersions"),
      warningText: summary.warningKey ? format(summary.warningKey) : ""
    };
  };

  const merge = (base, additions) => {
    const supportedPair = (base?.schemaVersion === 2 && additions?.schemaVersion === 1)
      || (base?.schemaVersion === 3 && additions?.schemaVersion === 3);
    if (!supportedPair
      || !Array.isArray(base.games) || !Array.isArray(base.reports) || !Array.isArray(base.testProfiles)
      || !Array.isArray(additions.reports) || !Array.isArray(additions.testProfiles)
      || !/^\d{4}-\d{2}-\d{2}$/.test(additions.updatedAt || "")) {
      throw new Error("Invalid website compatibility data");
    }
    if (base.schemaVersion === 3) {
      for (const report of [...base.reports, ...additions.reports]) {
        if (!platforms.includes(report?.launchPlatform)) throw new Error("Invalid schema-3 launch platform");
      }
    }
    const games = new Set(base.games.map((game) => game.id));
    const profiles = new Set(base.testProfiles.map((profile) => profile.id));
    const reports = new Set(base.reports.map((report) => report.id));
    const notePatches = Array.isArray(additions.notePatches) ? additions.notePatches : [];
    const patchIds = new Set();
    for (const patch of notePatches) {
      if (!patch?.reportId || patchIds.has(patch.reportId) || !reports.has(patch.reportId)
        || !patch.notes || Object.keys(patch.notes).length !== 8) {
        throw new Error("Invalid website developer note patch");
      }
      patchIds.add(patch.reportId);
    }
    for (const profile of additions.testProfiles) {
      if (!profile.id || profiles.has(profile.id)) throw new Error("Duplicate website device");
      profiles.add(profile.id);
    }
    for (const report of additions.reports) {
      if (!report.id || reports.has(report.id) || !games.has(report.gameId)
        || (report.testProfileId !== null && !profiles.has(report.testProfileId))
        || !statusOrder.includes(report.status)) throw new Error("Invalid website report reference");
      reports.add(report.id);
    }
    const patchedReports = base.reports.map((report) => {
      const patch = notePatches.find((candidate) => candidate.reportId === report.id);
      if (!patch) return report;
      const notes = Object.fromEntries(Object.keys(patch.notes).map((locale) => [
        locale,
        [report.notes?.[locale], patch.notes[locale]].filter(Boolean).join("\\n\\n")
      ]));
      return {...report, notes, websiteDeveloperNote: true};
    });
    return {
      ...base,
      updatedAt: [base.updatedAt, additions.updatedAt].sort().at(-1),
      testProfiles: [...base.testProfiles, ...additions.testProfiles],
      reports: [...patchedReports, ...additions.reports],
      websiteReportIds: additions.reports.map((report) => report.id)
    };
  };


  // Partition first, assess the release/status second. A Steam result must never
  // override a Battle.net result for the same title (or vice versa).
  const platformGroups = (database, selectedPlatform = "all") => {
    if (selectedPlatform !== "all" && !platforms.includes(selectedPlatform)) throw new Error("Invalid platform filter");
    const grouped = new Map();
    for (const report of database.reports) {
      const launchPlatform = platformOf(report);
      const key = `${report.gameId}:${launchPlatform}`;
      if (!grouped.has(key)) grouped.set(key, []);
      grouped.get(key).push(report);
    }
    return database.games.flatMap((game, gameIndex) => platforms.flatMap(launchPlatform => {
      const key = `${game.id}:${launchPlatform}`;
      const reports = grouped.get(key) || [];
      if (!reports.length || (selectedPlatform !== "all" && launchPlatform !== selectedPlatform)) return [];
      const summary = summarize(reports, database.currentRelease?.marketingVersion);
      return [{key, game, gameIndex, launchPlatform, reports, summary, status:summary.status}];
    })).sort(compareGameGroups);
  };

  const fetchJSON = async (path) => {
    const url = new URL(path, document.baseURI);
    url.searchParams.set("refresh", Date.now().toString());
    const response = await fetch(url, {cache:"no-store", headers:{Accept:"application/json"}});
    if (!response.ok) throw new Error("HTTP " + response.status);
    return response.json();
  };
  let pending;
  const load = () => {
    if (!pending) {
      pending = Promise.all([
        fetchJSON("site-data/compatibility-games.json"),
        fetchJSON("site-data/website-compatibility-reports.json"),
        window.ForgePlayCurrentRelease.ready
      ]).then(([base, additions, currentRelease]) => ({...merge(base, additions), currentRelease}));
    }
    return pending;
  };
  window.ForgePlayWebCatalog = {load, merge, summarize, sortReports, describe, compareVersions, compareGameGroups,
    platforms, platformOf, platformLabel, platformGroups};
})();

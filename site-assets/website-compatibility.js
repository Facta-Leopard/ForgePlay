(() => {
  "use strict";

  // Website-only additions never replace the catalog consumed by the app.
  const statusOrder = ["playable", "testing", "blocked", "unknown"];
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
  const sortReports = (reports) => [...reports].sort((a, b) => {
    const version = compareVersions(a.forgePlayVersion, b.forgePlayVersion);
    if (version) return -version;
    if (version === null) {
      const numericDifference = Number(Boolean(versionParts(b.forgePlayVersion)))
        - Number(Boolean(versionParts(a.forgePlayVersion)));
      if (numericDifference) return numericDifference;
    }
    return (b.testedAt || "").localeCompare(a.testedAt || "")
      || statusOrder.indexOf(a.status) - statusOrder.indexOf(b.status);
  });

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
    if (base?.schemaVersion !== 2 || additions?.schemaVersion !== 1
      || !Array.isArray(base.games) || !Array.isArray(base.reports) || !Array.isArray(base.testProfiles)
      || !Array.isArray(additions.reports) || !Array.isArray(additions.testProfiles)
      || !/^\d{4}-\d{2}-\d{2}$/.test(additions.updatedAt || "")) {
      throw new Error("Invalid website compatibility data");
    }
    const games = new Set(base.games.map((game) => game.id));
    const profiles = new Set(base.testProfiles.map((profile) => profile.id));
    const reports = new Set(base.reports.map((report) => report.id));
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
    return {
      ...base,
      updatedAt: [base.updatedAt, additions.updatedAt].sort().at(-1),
      testProfiles: [...base.testProfiles, ...additions.testProfiles],
      reports: [...base.reports, ...additions.reports],
      websiteReportIds: additions.reports.map((report) => report.id)
    };
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
  window.ForgePlayWebCatalog = {load, merge, summarize, sortReports, describe, compareVersions};
})();

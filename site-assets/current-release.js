(() => {
  "use strict";

  // Shared renderer for the machine-readable stable release manifest.

  const cacheBustedDataURL = (path) => {
    const url = new URL(path, document.baseURI);
    url.searchParams.set("refresh", Date.now().toString());
    return url.href;
  };

  const manifestURL = cacheBustedDataURL("site-data/current-release.json");
  const trustedHost = "github.com";
  const trustedReleasePath = "/Facta-Leopard/ForgePlay/releases/";
  let currentRelease = null;
  let loadFailed = false;

  const site = () => window.ForgePlaySite;
  const message = (key, fallback = "") => site()?.message(key) || fallback;

  const interpolate = (template, values) => (
    template.replace(/\{([A-Za-z]+)\}/g, (match, key) => (
      Object.hasOwn(values, key) ? String(values[key]) : match
    ))
  );

  const isNonEmptyString = (value) => (
    typeof value === "string" && value.trim().length > 0
  );

  const isUTCDateTime = (value) => (
    typeof value === "string"
      && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(value)
      && !Number.isNaN(Date.parse(value))
  );

  const trustedGitHubURL = (value, pathPrefix) => {
    if (!isNonEmptyString(value)) return false;
    try {
      const url = new URL(value);
      return url.protocol === "https:"
        && url.hostname === trustedHost
        && url.port === ""
        && url.username === ""
        && url.password === ""
        && url.search === ""
        && url.hash === ""
        && url.pathname.startsWith(pathPrefix);
    } catch {
      return false;
    }
  };

  const validateManifest = (candidate) => {
    const download = candidate?.download;
    const valid = candidate
      && candidate.$schema === "./current-release.schema.json"
      && candidate.schemaVersion === 1
      && candidate.product === "ForgePlay"
      && candidate.channel === "stable"
      && /^[0-9]+(?:\.[0-9]+){1,2}$/.test(candidate.marketingVersion)
      && Number.isInteger(candidate.buildNumber)
      && candidate.buildNumber > 0
      && /^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/.test(candidate.releaseTag)
      && isUTCDateTime(candidate.publishedAt)
      && /^[0-9]+(?:\.[0-9]+){1,2}$/.test(candidate.minimumMacOSVersion)
      && trustedGitHubURL(candidate.releaseURL, trustedReleasePath + "tag/")
      && download
      && /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(download.assetName)
      && trustedGitHubURL(download.url, trustedReleasePath + "download/")
      && /^[0-9a-f]{64}$/.test(download.sha256)
      && Number.isInteger(download.byteSize)
      && download.byteSize > 0;

    if (!valid) throw new Error("Invalid current release manifest");

    const expectedReleaseSuffix = "/tag/" + candidate.releaseTag;
    const expectedDownloadFragment = (
      "/download/" + candidate.releaseTag + "/" + download.assetName
    );
    const marketingParts = candidate.marketingVersion
      .split(".")
      .map(Number);
    const tagParts = candidate.releaseTag
      .slice(1)
      .split(/[-+]/, 1)[0]
      .split(".")
      .map(Number);
    while (marketingParts.length < 3) marketingParts.push(0);

    if (
      marketingParts.some((part, index) => part !== tagParts[index])
      || !new URL(candidate.releaseURL).pathname.endsWith(expectedReleaseSuffix)
      || !new URL(download.url).pathname.endsWith(expectedDownloadFragment)
    ) {
      throw new Error("Current release URLs do not match the release tag");
    }

    return candidate;
  };

  const setText = (selector, value) => {
    document.querySelectorAll(selector).forEach((element) => {
      element.textContent = value;
    });
  };

  const setHref = (selector, value) => {
    document.querySelectorAll(selector).forEach((element) => {
      element.href = value;
    });
  };

  const releaseValues = () => ({
    product: currentRelease.product,
    productUpper: currentRelease.product.toLocaleUpperCase("en-US"),
    version: currentRelease.marketingVersion,
    build: currentRelease.buildNumber,
    tag: currentRelease.releaseTag
  });

  const renderFailure = () => {
    if (!loadFailed) return;
    document.querySelectorAll("[data-current-release-card]").forEach((element) => {
      element.dataset.releaseState = "error";
    });
    setText(
      "[data-current-release-meta]",
      message(
        "compat.currentReleaseUnavailable",
        "Release information is temporarily unavailable."
      )
    );
  };

  const render = () => {
    if (!currentRelease) {
      renderFailure();
      return;
    }

    const values = releaseValues();
    document.querySelectorAll("[data-current-release-card]").forEach((element) => {
      element.dataset.releaseState = "ready";
    });
    setText("[data-current-release-tag]", currentRelease.releaseTag);
    setText("[data-current-release-version]", currentRelease.marketingVersion);
    setText("[data-current-release-build]", String(currentRelease.buildNumber));
    setText(
      "[data-current-release-meta]",
      interpolate(
        message(
          "compat.currentReleaseMeta",
          "{product} {version} · Build {build}"
        ),
        values
      )
    );
    setText(
      "[data-current-release-status-summary]",
      interpolate(
        message(
          "home.statusReleaseVersioned",
          "{product} {version} · available now"
        ),
        values
      )
    );
    setText(
      "[data-current-release-label]",
      interpolate(
        message(
          "home.releaseLabelVersioned",
          "{productUpper} {version} · BUILD {build}"
        ),
        values
      )
    );
    setText(
      "[data-current-release-status]",
      interpolate(
        message("home.releaseStatusVersioned", "AVAILABLE NOW · {tag}"),
        values
      )
    );
    setText(
      "[data-current-release-download-label]",
      interpolate(
        message(
          "home.releaseButtonVersioned",
          "Download {product} {version}"
        ),
        values
      )
    );
    setHref("[data-current-release-link]", currentRelease.releaseURL);
    setHref("[data-current-release-download]", currentRelease.download.url);
  };

  const load = async () => {
    try {
      const response = await fetch(manifestURL, {
        cache: "no-store",
        headers: { Accept: "application/json" }
      });
      if (!response.ok) throw new Error("HTTP " + response.status);
      currentRelease = validateManifest(await response.json());
      render();
    } catch {
      loadFailed = true;
      renderFailure();
    }
  };

  document.addEventListener("forgeplay:localechange", render);
  load();
})();

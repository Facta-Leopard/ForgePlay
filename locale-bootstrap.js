(() => {
  "use strict";

  const supportedLocales = Object.freeze([
    "ko",
    "en",
    "de",
    "es",
    "fr",
    "ja",
    "zh-Hans",
    "zh-Hant"
  ]);
  const storageKey = "forgeplay.site.locale";

  const normalizeLocale = (rawLocale) => {
    if (!rawLocale) return null;
    const normalized = String(rawLocale).replace("_", "-").toLowerCase();
    if (
      normalized === "zh"
      || normalized === "zh-hans"
      || normalized.startsWith("zh-cn")
      || normalized.startsWith("zh-sg")
    ) {
      return "zh-Hans";
    }
    if (
      normalized === "zh-hant"
      || normalized.startsWith("zh-tw")
      || normalized.startsWith("zh-hk")
      || normalized.startsWith("zh-mo")
    ) {
      return "zh-Hant";
    }
    return supportedLocales.find((locale) => locale.toLowerCase() === normalized)
      || supportedLocales.find((locale) => (
        normalized.startsWith(`${locale.toLowerCase()}-`)
      ))
      || null;
  };

  const localeFromHash = () => {
    const match = window.location.hash.match(
      /^#(?:privacy|support|why|license)-(ko|en|de|es|fr|ja|zh-Hans|zh-Hant)$/
    );
    return match ? match[1] : null;
  };

  const readStoredLocale = () => {
    try {
      return normalizeLocale(window.localStorage.getItem(storageKey));
    } catch {
      return null;
    }
  };

  const browserLocale = () => {
    for (const locale of navigator.languages || [navigator.language]) {
      const match = normalizeLocale(locale);
      if (match) return match;
    }
    return "en";
  };

  const initialLocale = () => {
    const queryLocale = normalizeLocale(
      new URLSearchParams(window.location.search).get("lang")
    );
    return localeFromHash()
      || queryLocale
      || readStoredLocale()
      || browserLocale();
  };

  const resolvedLocale = initialLocale();
  document.documentElement.lang = resolvedLocale;
  document.documentElement.classList.add("locale-pending");
  window.setTimeout(() => {
    document.documentElement.classList.remove("locale-pending");
  }, 2000);

  window.ForgePlayLocaleBootstrap = Object.freeze({
    supportedLocales,
    storageKey,
    normalizeLocale,
    localeFromHash,
    readStoredLocale,
    browserLocale,
    initialLocale,
    resolvedLocale
  });
})();

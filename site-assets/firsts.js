(() => {
  "use strict";
  // Keep previously shared homepage anchors working after moving the section.
  const redirectLegacySection = () => {
    if (document.body.dataset.page !== "home" || !["#game-mode", "#difference"].includes(window.location.hash)) return false;
    const target = new URL("site-assets/dlss5.html", document.baseURI);
    target.search = window.location.search;
    target.hash = window.location.hash;
    window.location.replace(target.href);
    return true;
  };
  if (redirectLegacySection()) return;
  window.addEventListener("hashchange", redirectLegacySection);
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
  const evidenceOpeners = new WeakMap();
  document.querySelectorAll("[data-open-evidence]").forEach((link) => {
    const targetURL = new URL(link.href, document.baseURI);
    const samePage = targetURL.origin === window.location.origin && targetURL.pathname === window.location.pathname;
    const evidence = samePage ? document.getElementById(targetURL.hash.slice(1)) : null;
    if (!evidence?.matches("details.fp-evidence")) return;
    link.setAttribute("aria-controls", evidence.id);
    link.setAttribute("aria-expanded", String(evidence.open));
    evidence.addEventListener("toggle", () => link.setAttribute("aria-expanded", String(evidence.open)));
    link.addEventListener("click", (event) => {
      event.preventDefault();
      evidenceOpeners.set(evidence, link);
      evidence.open = true;
      const destination = new URL(window.location.href);
      destination.hash = evidence.id;
      if (window.location.hash !== destination.hash) window.history.pushState(null, "", destination);
      evidence.scrollIntoView({block: "start"});
      evidence.querySelector("summary")?.focus({preventScroll: true});
    });
  });
  document.querySelectorAll("details.fp-evidence").forEach((evidence) => {
    const close = () => {
      evidence.open = false;
      (evidenceOpeners.get(evidence) || evidence.querySelector("summary"))?.focus();
    };
    evidence.querySelector("[data-close-evidence]")?.addEventListener("click", close);
    evidence.addEventListener("keydown", (event) => {
      if (event.key !== "Escape" || !evidence.open) return;
      event.preventDefault();
      close();
    });
  });
  const revealLinkedEvidence = () => {
    const target = document.getElementById(window.location.hash.slice(1));
    if (!target?.matches("details.fp-evidence")) return;
    target.open = true;
    requestAnimationFrame(() => target.scrollIntoView({block:"start"}));
  };
  window.addEventListener("hashchange", revealLinkedEvidence);
  revealLinkedEvidence();
})();

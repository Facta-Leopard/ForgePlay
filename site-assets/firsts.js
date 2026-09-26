(() => {
  "use strict";
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
})();

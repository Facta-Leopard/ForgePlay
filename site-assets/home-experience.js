(() => {
  "use strict";

  const body = document.querySelector("body.home-experience");
  if (!body) return;

  const root = document.documentElement;
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const finePointer = window.matchMedia("(pointer: fine)");
  let progressFrame = 0;

  const updateProgress = () => {
    progressFrame = 0;
    const scrollable = Math.max(1, root.scrollHeight - window.innerHeight);
    const progress = Math.min(1, Math.max(0, window.scrollY / scrollable));
    root.style.setProperty("--home-progress", progress.toFixed(4));
  };

  const requestProgressUpdate = () => {
    if (progressFrame) return;
    progressFrame = window.requestAnimationFrame(updateProgress);
  };

  updateProgress();
  window.addEventListener("scroll", requestProgressUpdate, { passive: true });
  window.addEventListener("resize", requestProgressUpdate, { passive: true });

  const stepButtons = [...document.querySelectorAll("[data-game-mode-step]")];
  const stepPanels = [...document.querySelectorAll("[data-game-mode-panel]")];

  const activateStep = (nextIndex, shouldFocus = false) => {
    if (!stepButtons.length || !stepPanels.length) return;
    const normalizedIndex = (nextIndex + stepButtons.length) % stepButtons.length;

    stepButtons.forEach((button, index) => {
      const active = index === normalizedIndex;
      button.setAttribute("aria-selected", String(active));
      button.tabIndex = active ? 0 : -1;
      if (active && shouldFocus) button.focus();
    });

    stepPanels.forEach((panel, index) => {
      panel.hidden = index !== normalizedIndex;
    });
  };

  stepButtons.forEach((button, index) => {
    button.addEventListener("click", () => activateStep(index));
    button.addEventListener("keydown", (event) => {
      const keyTargets = {
        ArrowLeft: index - 1,
        ArrowUp: index - 1,
        ArrowRight: index + 1,
        ArrowDown: index + 1,
        Home: 0,
        End: stepButtons.length - 1
      };
      if (!(event.key in keyTargets)) return;
      event.preventDefault();
      activateStep(keyTargets[event.key], true);
    });
  });

  activateStep(0);

  const hero = document.querySelector(".home-hero");
  if (!hero || reducedMotion.matches || !finePointer.matches) return;

  let pointerFrame = 0;
  let targetX = 0;
  let targetY = 0;

  const renderHeroShift = () => {
    pointerFrame = 0;
    hero.style.setProperty("--hero-shift-x", `${targetX.toFixed(2)}px`);
    hero.style.setProperty("--hero-shift-y", `${targetY.toFixed(2)}px`);
  };

  const requestHeroShift = () => {
    if (pointerFrame) return;
    pointerFrame = window.requestAnimationFrame(renderHeroShift);
  };

  hero.addEventListener("pointermove", (event) => {
    const bounds = hero.getBoundingClientRect();
    targetX = ((event.clientX - bounds.left) / bounds.width - 0.5) * -10;
    targetY = ((event.clientY - bounds.top) / bounds.height - 0.5) * -7;
    requestHeroShift();
  }, { passive: true });

  hero.addEventListener("pointerleave", () => {
    targetX = 0;
    targetY = 0;
    requestHeroShift();
  }, { passive: true });
})();

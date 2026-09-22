(() => {
  "use strict";
  // A separate visual layer: never intercept links, modify app data, or own controls.
  // ?preview=original is a local review aid for comparing with the published design.
  if (new URLSearchParams(location.search).get("preview") === "original") return;
  const body = document.body;
  if (!body?.classList.contains("fp-site")) return;
  body.classList.add("fp-motion");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const fine = matchMedia("(hover: hover) and (pointer: fine)");
  const surfaces = ".fp-news-preview,.fp-game,.developer-app-card,.fp-feature-shell,.update-card,.guide-teaser";
  const main = document.querySelector("main");

  const artSelector = ".fp-panorama,.fp-purpose-art,.story-art";
  const artworks = [...document.querySelectorAll(artSelector)];
  const artwork = document.querySelector(".fp-panorama");
  if (artwork) {
    const scene = document.createElement("div");
    scene.className = "forge-scene";
    scene.setAttribute("aria-hidden", "true");
    for (const [name, width, height] of [["workshop",2172,724],["smith",1254,1254],["tools",2172,724]]) {
      const layer = document.createElement("img");
      layer.className = `forge-layer forge-${name}`;
      layer.src = `site-assets/forge-scene/${name}.${name === "workshop" ? "jpg" : "png"}`;
      layer.width = width; layer.height = height; layer.alt = "";
      layer.decoding = "async";
      scene.append(layer);
    }
    const heat = document.createElement("div");
    heat.className = "forge-heat"; scene.append(heat);
    const sigils = document.createElement("div");
    sigils.className = "forge-sigils";
    for (const [symbol, label, id] of [["X","DirectX","directx"],["M","Metal","metal"]]) {
      const plate = document.createElement("div"); plate.className = `forge-sigil forge-${id}`;
      const mark = document.createElement("strong"); mark.textContent = symbol;
      const caption = document.createElement("span"); caption.textContent = label;
      plate.append(mark,caption); sigils.append(plate);
    }
    scene.append(sigils); artwork.prepend(scene);
  }
  for (const host of document.querySelectorAll(".fp-purpose-art,.story-art")) {
    const scene = document.createElement("div");
    scene.className = "outlook-scene";
    scene.setAttribute("aria-hidden", "true");
    for (const name of ["landscape", "rabbit", "door"]) {
      const layer = document.createElement("img");
      layer.className = `outlook-layer outlook-${name}`;
      layer.src = `site-assets/forge-scene/outlook-${name}.${name === "landscape" ? "jpg" : "png"}`;
      layer.alt = ""; layer.width = 1254; layer.height = 1254;
      layer.decoding = "async";
      if (host.classList.contains("fp-purpose-art")) layer.loading = "lazy";
      scene.append(layer);
    }
    const light = document.createElement("div"); light.className = "outlook-light"; scene.append(light);
    host.prepend(scene);
  }

  // One delegated pointer handler also covers cards rendered after data/locale changes.
  let pointFrame = 0;
  let pointer = null;
  main?.addEventListener("pointermove", event => {
    if (reduce.matches || !fine.matches) return;
    const surface = event.target.closest(surfaces);
    const art = event.target.closest(artSelector);
    if (!surface && !art) return;
    pointer = {surface, art, x:event.clientX, y:event.clientY};
    if (pointFrame) return;
    pointFrame = requestAnimationFrame(() => {
      pointFrame = 0;
      if (!pointer) return;
      const {surface, art, x, y} = pointer;
      if (surface?.isConnected) {
        const bounds = surface.getBoundingClientRect();
        surface.classList.add("motion-surface");
        surface.style.setProperty("--light-x", `${x - bounds.left}px`);
        surface.style.setProperty("--light-y", `${y - bounds.top}px`);
      }
      if (art?.isConnected) {
        const bounds = art.getBoundingClientRect();
        art.style.setProperty("--art-x", `${(x - bounds.left - bounds.width / 2) * .018}px`);
        art.style.setProperty("--art-y", `${(y - bounds.top - bounds.height / 2) * .026}px`);
      }
    });
  }, {passive:true});
  artworks.forEach(art => art.addEventListener("pointerleave", () => {
    art.style.setProperty("--art-x", "0px");
    art.style.setProperty("--art-y", "0px");
  }));
  let scrollFrame = 0;
  const updateDepth = () => {
    scrollFrame = 0;
    if (reduce.matches) return;
    for (const art of artworks) {
      const rect = art.getBoundingClientRect();
      if (rect.bottom < 0 || rect.top > innerHeight) continue;
      const progress = Math.max(-1, Math.min(1, (innerHeight / 2 - rect.top - rect.height / 2) / innerHeight));
      art.style.setProperty("--scroll-depth", `${progress * 12}px`);
    }
  };
  window.addEventListener("scroll", () => {
    if (!scrollFrame && !reduce.matches) scrollFrame = requestAnimationFrame(updateDepth);
  }, {passive:true});

  // Observe static section entrances only. Content is never hidden waiting for JS.
  const entrances = document.querySelectorAll(".guide-teaser,.guide-vision,.fp-section-head,.fp-feature-shell,.fp-download-grid,.fp-purpose-art,.guide-app-experience,.updates-heading");
  const seen = new WeakSet();
  const entranceObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      entry.target.classList.toggle("motion-in-view", entry.isIntersecting);
      if (entry.isIntersecting && !seen.has(entry.target)) {
        seen.add(entry.target);
        if (!reduce.matches) entry.target.classList.add("motion-arrive");
      }
    }
  }, {threshold:.1});
  entrances.forEach(element => entranceObserver.observe(element));

  // Original canvas artwork: individual copper/cobalt filaments, not an imported shader.
  // Capped-resolution canvases; no loop while offscreen or the page is hidden.
  const fields = [];
  let animation = 0;
  let lastFrame = 0;
  let elapsed = 0;
  const draw = (field, time) => {
    const {ctx, width:w, height:h, kind} = field;
    if (!w || !h) return;
    ctx.clearRect(0, 0, w, h);
    const top = kind === "hero";
    if (kind === "outlook") {
      for (let i = 0; i < 15; i++) {
        const age = (time * .055 + i * .137) % 1;
        const x = w * (.12 + .75 * ((i * .371) % 1)) + Math.sin(age * 5 + i) * 9;
        const y = h * (1 - age * 1.15);
        ctx.fillStyle = `rgba(255,185,119,${Math.sin(age * Math.PI) * .45})`;
        ctx.beginPath(); ctx.arc(x,y,i % 3 ? .8 : 1.4,0,Math.PI * 2); ctx.fill();
      }
      return;
    }
    if (!top) {
      // A few embers rise from the work, plus a trace passing between the plaques.
      // Particle paths are deterministic, so reduced-motion uses a stable still.
      const sourceX = w > 600 ? w * .626 : w * .68;
      const sourceY = h * .72;
      for (let i = 0; i < 24; i++) {
        const age = (time * .2 + i * .173) % 1;
        const x = sourceX + Math.sin(i * 2.37) * age * 125;
        const y = sourceY - age * h * .55;
        ctx.globalAlpha = Math.sin(age * Math.PI) * .65;
        ctx.strokeStyle = i % 3 ? "#ffc28a" : "#d87e3a";
        ctx.lineWidth = i % 4 ? 1 : 1.8;
        ctx.beginPath(); ctx.moveTo(x,y); ctx.lineTo(x+Math.sin(i)*3,y+3); ctx.stroke();
      }
      ctx.globalAlpha = 1;
      return;
    }
    const centerY = h * (top ? .68 : .58);
    const bend = Math.sin(time * .24) * h * .055;
    const x0 = w * .60;
    const glow = ctx.createRadialGradient(x0, centerY, 0, x0, centerY, w * .42);
    glow.addColorStop(0, top ? "#ab704017" : "#f29f481f");
    glow.addColorStop(.45, "#3678a010"); glow.addColorStop(1, "#00000000");
    ctx.fillStyle = glow; ctx.fillRect(0, 0, w, h);
    for (let side = 0; side < 2; side++) {
      const color = side ? "100,170,218" : "242,168,99";
      const strands = top ? 23 : 32;
      for (let i = 0; i < strands; i++) {
        const f = i / (strands - 1);
        const spread = (f - .5) * h * (top ? .30 : .40);
        const phase = time * .32 + f * 2;
        const edgeY = h * (side ? .02 : 1.13) + spread;
        const midpoint = centerY + spread * .10 + Math.sin(phase) * h * .028;
        const curve = new Path2D();
        if (side) {
          curve.moveTo(w * 1.09, edgeY);
          curve.bezierCurveTo(w * .72, h * -.20 + spread + bend, w * .81, h * 1.17, w * .31, midpoint);
        } else {
          curve.moveTo(-w * .1, edgeY);
          curve.bezierCurveTo(w * .32, h * 1.3 + spread, w * .27, -h * .35 + spread + bend, w * 1.05, midpoint);
        }
        const gradient = ctx.createLinearGradient(0, 0, w, 0);
        const strength = (.13 + Math.pow(Math.sin(f * Math.PI), 4) * .36) * (top ? .54 : .9);
        gradient.addColorStop(0, `rgba(${color},0)`);
        gradient.addColorStop(.28, `rgba(${color},${strength * .55})`);
        gradient.addColorStop(.65, `rgba(${color},${strength})`);
        gradient.addColorStop(1, `rgba(${color},0)`);
        ctx.strokeStyle = gradient; ctx.lineWidth = i % 7 === 0 ? 1.15 : .65;
        ctx.stroke(curve);
      }
    }
  };
  const visible = () => !document.hidden && fields.some(field => field.visible);
  const tick = now => {
    animation = 0;
    if (!visible() || reduce.matches) { lastFrame = 0; return; }
    if (!lastFrame || now - lastFrame >= 1000 / 30) {
      elapsed += lastFrame ? Math.min((now - lastFrame) / 1000, .06) : 0;
      lastFrame = now;
      for (const field of fields) if (field.visible) draw(field, elapsed);
    }
    animation = requestAnimationFrame(tick);
  };
  const resume = () => {
    if (reduce.matches) {
      cancelAnimationFrame(animation); animation = 0; lastFrame = 0;
      fields.forEach(field => draw(field, 0));
    } else if (!animation && visible()) animation = requestAnimationFrame(tick);
  };
  const fieldObserver = new IntersectionObserver(entries => {
    for (const entry of entries) {
      const field = fields.find(candidate => candidate.canvas === entry.target);
      if (field) {
        field.visible = entry.isIntersecting;
        if (field.kind !== "hero") field.canvas.parentElement.classList.toggle("forge-active", entry.isIntersecting);
      }
    }
    resume();
  }, {rootMargin:"40px"});
  for (const [selector, kind] of [[".fp-hero", "hero"], [".fp-panorama", "art"], [".fp-purpose-art", "outlook"], [".story-art", "outlook"]]) {
    const host = document.querySelector(selector);
    if (!host) continue;
    const canvas = document.createElement("canvas");
    canvas.className = "motion-light-field";
    canvas.setAttribute("aria-hidden", "true");
    const ctx = canvas.getContext("2d", {alpha:true});
    if (!ctx) continue;
    host.prepend(canvas);
    const field = {canvas, ctx, kind, width:0, height:0, visible:false};
    fields.push(field);
    const resize = new ResizeObserver(() => {
      const box = canvas.getBoundingClientRect();
      const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
      field.width = box.width; field.height = box.height;
      canvas.width = Math.round(box.width * ratio); canvas.height = Math.round(box.height * ratio);
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0); draw(field, elapsed);
    });
    resize.observe(host);
    fieldObserver.observe(canvas);
  }
  document.addEventListener("visibilitychange", () => {
    body.classList.toggle("motion-paused", document.hidden);
    resume();
  });
  reduce.addEventListener("change", resume);
})();

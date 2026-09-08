(() => {
  "use strict";
  const dialog = document.querySelector("#fp-poster-dialog");
  const buttons = [...document.querySelectorAll("[data-poster-version]")];
  if (!dialog || !buttons.length) return;
  const image = dialog.querySelector("[data-poster-full]");
  const title = dialog.querySelector("#fp-poster-dialog-title");
  const position = dialog.querySelector("[data-poster-position]");
  const development = dialog.querySelector("[data-poster-development]");
  const posters = buttons.map((button) => {
    const thumbnail = button.querySelector("img");
    return {version:button.dataset.posterVersion, src:thumbnail.getAttribute("src"), width:Number(thumbnail.getAttribute("width")), height:Number(thumbnail.getAttribute("height"))};
  });
  const message = (key, version) => (window.ForgePlaySite?.message(key) || key)
    .replace("{version}", version);
  let currentIndex = 0;
  let opener = null;

  const showPoster = (index) => {
    currentIndex = (index + posters.length) % posters.length;
    const poster = posters[currentIndex];
    image.src = poster.src;
    image.width = poster.width;
    image.height = poster.height;
    image.alt = message("posters.imageAlt", poster.version);
    title.textContent = "ForgePlay " + poster.version;
    position.textContent = (currentIndex + 1) + " / " + posters.length;
    development.hidden = poster.version !== "1.3";
  };

  buttons.forEach((button, index) => {
    button.addEventListener("click", () => {
      opener = button;
      showPoster(index);
      document.body.classList.add("fp-poster-open");
      dialog.showModal();
    });
  });
  dialog.querySelector("[data-poster-close]").addEventListener("click", () => dialog.close());
  dialog.querySelector("[data-poster-previous]").addEventListener("click", () => showPoster(currentIndex - 1));
  dialog.querySelector("[data-poster-next]").addEventListener("click", () => showPoster(currentIndex + 1));
  dialog.addEventListener("keydown", (event) => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
      event.preventDefault();
      showPoster(currentIndex + (event.key === "ArrowLeft" ? -1 : 1));
    }
  });
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const box = dialog.getBoundingClientRect();
    if (event.clientX < box.left || event.clientX > box.right
      || event.clientY < box.top || event.clientY > box.bottom) dialog.close();
  });
  dialog.addEventListener("close", () => {
    document.body.classList.remove("fp-poster-open");
    opener?.focus({preventScroll:true});
  });
  const localize = () => {
    buttons.forEach((button, index) => {
      button.setAttribute("aria-label", message("posters.open", posters[index].version));
      button.querySelector("img").alt = message("posters.imageAlt", posters[index].version);
    });
    if (dialog.open) showPoster(currentIndex);
  };
  document.addEventListener("forgeplay:localechange", localize);
  localize();
})();

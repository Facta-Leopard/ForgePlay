(() => {
  "use strict";
  // Optional, small decoration. The keyring itself does no work until a mouse enters.
  const source=document.currentScript.src;
  const style=document.createElement('link');style.rel='stylesheet';style.href=new URL('fopl-keyring.css?v=20261001-1',source).href;document.head.append(style);
  const keyring=document.createElement('script');keyring.src=new URL('fopl-keyring.js?v=20261001-1',source).href;keyring.async=true;document.head.append(keyring);
  const menu = document.querySelector(".fp-menu");
  const navigation = document.querySelector("#fp-navigation");
  if (!menu || !navigation) return;
  const setMenu = (open) => {
    menu.setAttribute("aria-expanded", String(open));
    navigation.classList.toggle("is-open", open);
  };
  menu.addEventListener("click", () => setMenu(menu.getAttribute("aria-expanded") !== "true"));
  navigation.addEventListener("click", (event) => {
    if (event.target.closest("a")) setMenu(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menu.getAttribute("aria-expanded") === "true") {
      setMenu(false);
      menu.focus();
    }
  });
})();

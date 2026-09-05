(() => {
  "use strict";
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

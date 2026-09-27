(() => {
  "use strict";
  const labels = { ko: "후원기록", en: "Supporters", de: "Unterstützer", es: "Patrocinadores", fr: "Soutiens", ja: "ご支援者", "zh-Hans": "赞助记录", "zh-Hant": "贊助紀錄" };
  function render() {
    const locale = window.ForgePlaySite?.getLocale() || document.documentElement.lang;
    document.querySelectorAll('[data-supporter-nav]').forEach(link => {
      link.textContent = labels[locale] || labels.en;
      if (document.body.dataset.page === 'supporters') link.setAttribute('aria-current', 'page');
    });
  }
  document.addEventListener('forgeplay:localechange', render);
  render();
})();

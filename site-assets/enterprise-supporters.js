(() => {
  'use strict';
  const element = document.querySelector('.enterprise-banner');
  if (!element) return;
  const languages = ['ko','en','de','es','fr','ja','zh-Hans','zh-Hant'];
  const requested = new URL(location.href).searchParams.get('lang');
  let payload = null;
  let placeholderProbe=null,artRevision=0;
  const locale = () => window.ForgePlaySite?.getLocale() || (languages.includes(requested) ? requested : 'en');
  const localized = values => values[locale()] || values.en;
  function render() {
    if (!payload) return;
    const banner = payload.banner;
    element.style.aspectRatio = String(banner.aspectRatio);
    const image = element.querySelector('img');
    // The versioned URL is absolute for native consumers. Resolve the same asset locally for previews.
    const originalURL=new URL('site-assets/supporters/' + banner.imageURL.split('/').pop(), document.baseURI).href;
    image.src = originalURL;
    const revision=++artRevision;
    if(document.documentElement.dataset.siteTheme==='light'&&banner.imageURL.endsWith('/enterprise-arcade.png')){
      placeholderProbe ||= fetch(originalURL,{cache:'force-cache',credentials:'omit',signal:AbortSignal.timeout(10000)})
        .then(async response=>{if(!response.ok||Number(response.headers.get('Content-Length'))>8_000_000)return false;const data=await response.arrayBuffer();if(data.byteLength>8_000_000)return false;const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',data))].map(v=>v.toString(16).padStart(2,'0')).join('');return hash==='0cb07af680b74377938ead746f245a89cdadab93956734ae53c8b968b32f0424';}).catch(()=>false);
      placeholderProbe.then(isDefault=>{if(isDefault&&revision===artRevision&&document.documentElement.dataset.siteTheme==='light')image.src=window.ForgePlaySiteTheme.asset('site-assets/arcade/launcher/forge-banner.png');});
    }
    image.width = banner.imageWidth; image.height = banner.imageHeight;
    image.alt = localized(banner.alt);
    element.querySelector('strong').textContent = localized(banner.titles);
    element.querySelector('.enterprise-banner-copy>span').textContent = payload.names.length ? payload.names.join(' · ') : localized(banner.messages);
    const link = new URL('site-assets/supporters.html',document.baseURI); link.searchParams.set('lang',locale()); link.hash = 'enterprise-supporters'; element.href = link.href;
    element.hidden = false;
    const empty = document.querySelector('.enterprise-empty'); if (empty) empty.hidden = true;
    const error = document.querySelector('[data-banner-error]'); if (error) error.hidden = true;
    if (document.body.classList.contains('enterprise-embed')) { document.documentElement.lang = locale(); document.title = `ForgePlay — ${localized(banner.titles)}`; }
  }
  document.addEventListener('forgeplay:localechange', render);
  document.addEventListener('forgeplay:themechange', render);
  const controller = new AbortController(); const timeout = setTimeout(() => controller.abort(),10000);
  const url = new URL('site-data/enterprise-supporters.json', document.baseURI); url.searchParams.set('refresh',String(Date.now()));
  fetch(url,{cache:'no-store',credentials:'omit',redirect:'error',signal:controller.signal})
    .then(async response => {
      if (!response.ok) throw new Error('Unavailable');
      const text = await response.text(); if (new TextEncoder().encode(text).length > 128000) throw new Error('Too large');
      const data = JSON.parse(text), b = data.banner;
      if (data.schemaVersion !== 1 || !Array.isArray(data.names) || data.names.length > 200 || data.names.some(n => typeof n !== 'string' || !n.trim() || n.length > 80 || /[\p{Cc}\p{Cf}]/u.test(n)) || !b || b.contentMode !== 'fit' || !Number.isFinite(b.aspectRatio) || b.aspectRatio < 1 || b.aspectRatio > 10 || ![b.imageWidth,b.imageHeight].every(n=>Number.isInteger(n)&&n>0&&n<=8192) || !/^https:\/\/facta-leopard\.github\.io\/ForgePlay\/site-assets\/supporters\/[a-z0-9-]+\.png$/.test(b.imageURL)) throw new Error('Invalid banner');
      for (const field of ['titles','messages','alt']) if (!b[field] || languages.some(lang => typeof b[field][lang] !== 'string' || !b[field][lang] || b[field][lang].length > 200)) throw new Error('Invalid localization');
      payload = data; render();
    })
    .catch(() => { /* Keep the localized no-sponsor state; never block the rest of the site. */ })
    .finally(() => clearTimeout(timeout));
})();

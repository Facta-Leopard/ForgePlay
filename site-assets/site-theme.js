(() => {
  'use strict';
  const root=document.documentElement, media=matchMedia('(prefers-color-scheme: light)');
  const scriptURL=document.currentScript.src;
  let darkChromeColor;
  const pictures={
    'arcade/assets/workshop.png':'workshop','arcade/assets/world.png':'world',
    'arcade/assets/tools.png':'tools','arcade/assets/explorer.png':'explorer',
    'arcade/assets/neural.png':'neural','arcade/launcher/forge-banner.png':'forge-banner',
    'arcade/hammer/raised.png':'hammer-raised','arcade/hammer/down.png':'hammer-down',
    'arcade/hammer/contact.png':'hammer-contact','arcade/assets/smith.png':'hammer-contact'
  };
  const asset=path=>{
    const key=new URL(path,document.baseURI).pathname.split('/site-assets/')[1];
    return media.matches&&pictures[key]?new URL('arcade/light/'+pictures[key]+'.webp',scriptURL).href:path;
  };
  const artwork=()=>{
    for(const image of document.querySelectorAll('.fp-brand img,.hero-icon,.fp-trust>img,.mock-body>img,.fp-core img,.fp-runtime-hub img')){
      if(!image.dataset.siteDarkSrc){const src=image.getAttribute('src')||'';if(!/forgeplay-icon\.png(?:[?#]|$)/.test(src))continue;image.dataset.siteDarkSrc=src;}
      image.src=media.matches?new URL('forgeplay-icon-light.webp',scriptURL).href:image.dataset.siteDarkSrc;
      image.classList.toggle('fp-light-brand',media.matches);
    }
    for(const image of document.querySelectorAll('[data-site-art],.fp-neural-art>img')){
      if(!image.dataset.siteArt)image.dataset.siteArt=image.getAttribute('src');
      image.src=asset(image.dataset.siteArt);
    }
  };
  const apply=()=>{
    const mode=media.matches?'light':'dark',changed=root.dataset.siteTheme!==mode;root.dataset.siteTheme=mode;
    const chrome=document.querySelector('meta[name="theme-color"]');
    if(chrome){darkChromeColor??=chrome.getAttribute('content');chrome.setAttribute('content',media.matches?'#e7d5ba':darkChromeColor);}
    artwork();if(changed)document.dispatchEvent(new CustomEvent('forgeplay:themechange',{detail:{mode}}));
  };
  window.ForgePlaySiteTheme=Object.freeze({asset,refreshArtwork:artwork});
  apply();
  media.addEventListener('change',apply);
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',apply,{once:true});
})();

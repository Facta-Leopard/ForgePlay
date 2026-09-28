(() => {
  'use strict';
  if (!document.body.classList.contains('fp-pixel')) return;

  const copy = {
    ko: {stage:'대장간',light:'조명',forge:'망치 휘두르기',shelf:'버전별 포스터',shelfNote:'포스터를 누르면 크게 볼 수 있습니다.',guide:'사용 가이드',games:'게임 호환성',why:'만든 이유',jump:'바로가기'},
    en: {stage:'The forge',light:'Lights',forge:'Swing the hammer',shelf:'Release posters',shelfNote:'Select a poster to see it full size.',guide:'User guide',games:'Compatibility',why:'Why ForgePlay',jump:'Quick links'},
    de: {stage:'Die Schmiede',light:'Licht',forge:'Hammer schwingen',shelf:'Versionsposter',shelfNote:'Poster auswählen und vergrößern.',guide:'Anleitung',games:'Kompatibilität',why:'Warum ForgePlay',jump:'Direktlinks'},
    es: {stage:'La forja',light:'Luz',forge:'Golpear con el martillo',shelf:'Pósteres de versiones',shelfNote:'Selecciona un póster para ampliarlo.',guide:'Guía de uso',games:'Compatibilidad',why:'Por qué ForgePlay',jump:'Accesos directos'},
    fr: {stage:'La forge',light:'Lumière',forge:'Frapper au marteau',shelf:'Affiches des versions',shelfNote:'Sélectionnez une affiche pour l’agrandir.',guide:'Guide d’utilisation',games:'Compatibilité',why:'Pourquoi ForgePlay',jump:'Accès rapides'},
    ja: {stage:'鍛冶場',light:'照明',forge:'ハンマーを振る',shelf:'バージョン別ポスター',shelfNote:'ポスターを選ぶと拡大できます。',guide:'使い方',games:'ゲーム互換性',why:'開発の理由',jump:'クイックリンク'},
    'zh-Hans': {stage:'锻造工坊',light:'灯光',forge:'挥动锤子',shelf:'版本海报',shelfNote:'点击海报可放大查看。',guide:'使用指南',games:'游戏兼容性',why:'开发初衷',jump:'快捷链接'},
    'zh-Hant': {stage:'鍛造工坊',light:'燈光',forge:'揮動鐵鎚',shelf:'版本海報',shelfNote:'點選海報可放大檢視。',guide:'使用指南',games:'遊戲相容性',why:'開發初衷',jump:'快速連結'}
  };
  const text = key => (copy[document.documentElement.lang] || copy.en)[key];
  function node(tag, className, value) { const el = document.createElement(tag); if(className)el.className=className; if(value)el.textContent=value; return el; }


  const bay=document.querySelector('.arcade-scene-bay');
  if(bay){
    const light=bay.querySelector('.arcade-light-switch');
    light?.addEventListener('click',()=>{const on=light.getAttribute('aria-pressed')!=='true';light.setAttribute('aria-pressed',String(on));bay.classList.toggle('arcade-lights-dim',!on);});
    const control=bay.querySelector('.arcade-scene-controls'),spark=bay.querySelector('.pixel-strike'),motion=bay.querySelector('.arcade-motion-toggle');
    if(spark){spark.dataset.retroText='forge';control.append(spark);}
    if(motion){control.append(motion);bay.querySelector('.arcade-art-controls')?.remove();}
  }
  // The same visual language extends to the existing pages and controls, without replacing their handlers.
  const sections=document.querySelectorAll('.guide-teaser,.guide-vision,.fp-library,.fp-feature,.fp-apps,.fp-community,.fp-purpose,.fp-download,.guide-finish,.recognition-board');
  sections.forEach((section,index)=>{section.classList.add('arcade-section');section.style.setProperty('--section-index',`"${String(index+1).padStart(2,'0')}"`);});
  const guideArt=document.querySelector('[data-guide-image-link]');
  if(guideArt) {
    guideArt.classList.add('arcade-preview-screen');
    const lamp=node('span','arcade-screen-led');lamp.setAttribute('aria-hidden','true');guideArt.append(lamp);
  }
  const header=document.querySelector('.fp-header');
  if(header){const rail=node('div','arcade-progress');rail.setAttribute('aria-hidden','true');header.append(rail);const update=()=>{const range=document.documentElement.scrollHeight-innerHeight;rail.style.setProperty('--reading',`${range>0?scrollY/range*100:0}%`);};let frame=0;addEventListener('scroll',()=>{if(!frame)frame=requestAnimationFrame(()=>{frame=0;update();});},{passive:true});addEventListener('resize',update);update();}

  function applyCopy(){
    document.querySelectorAll('[data-retro-text]').forEach(el=>el.textContent=text(el.dataset.retroText));
    document.querySelectorAll('[data-retro-aria]').forEach(el=>el.setAttribute('aria-label',text(el.dataset.retroAria)));
  }
  document.addEventListener('forgeplay:localechange',applyCopy);applyCopy();
})();

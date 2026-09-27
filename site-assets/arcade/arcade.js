(() => {
  'use strict';
  if (!document.body.classList.contains('fp-pixel')) return;

  const copy = {
    ko: {stage:'대장간',light:'조명',forge:'망치 휘두르기',shelf:'업데이트의 기록',shelfNote:'포스터를 누르면 크게 볼 수 있습니다.',guide:'웹에서 체험',games:'게임 호환성',features:'주요 기능',why:'만든 이유',hint:'포인터를 움직이거나 토끼에게 망치를 휘두르게 해보세요.',jump:'구역 바로가기'},
    en: {stage:'The forge',light:'Lights',forge:'Swing the hammer',shelf:'The update collection',shelfNote:'Select a poster to see it full size.',guide:'Try on the web',games:'Compatibility',features:'Features',why:'Why ForgePlay',hint:'Move the pointer or let the rabbit swing the hammer.',jump:'Explore sections'},
    de: {stage:'Die Schmiede',light:'Licht',forge:'Hammer schwingen',shelf:'Die Updatesammlung',shelfNote:'Poster auswählen und vergrößern.',guide:'Im Web testen',games:'Kompatibilität',features:'Funktionen',why:'Warum ForgePlay',hint:'Bewege den Zeiger oder lass den Hasen den Hammer schwingen.',jump:'Bereiche erkunden'},
    es: {stage:'La forja',light:'Luz',forge:'Golpear con el martillo',shelf:'La colección de actualizaciones',shelfNote:'Selecciona un póster para ampliarlo.',guide:'Probar en la web',games:'Compatibilidad',features:'Funciones',why:'Por qué ForgePlay',hint:'Mueve el cursor o haz que el conejo golpee con el martillo.',jump:'Explorar secciones'},
    fr: {stage:'La forge',light:'Lumière',forge:'Frapper au marteau',shelf:'La collection des mises à jour',shelfNote:'Sélectionnez une affiche pour l’agrandir.',guide:'Essayer sur le web',games:'Compatibilité',features:'Fonctionnalités',why:'Pourquoi ForgePlay',hint:'Déplacez le pointeur ou faites frapper le lapin au marteau.',jump:'Explorer les rubriques'},
    ja: {stage:'鍛冶場',light:'照明',forge:'ハンマーを振る',shelf:'アップデートの記録',shelfNote:'ポスターを選ぶと拡大できます。',guide:'Webで体験',games:'ゲーム互換性',features:'主な機能',why:'開発の理由',hint:'ポインターを動かしたり、ウサギにハンマーを振らせたりしてみてください。',jump:'セクションへ移動'},
    'zh-Hans': {stage:'锻造工坊',light:'灯光',forge:'挥动锤子',shelf:'更新记录',shelfNote:'点击海报可放大查看。',guide:'网页体验',games:'游戏兼容性',features:'主要功能',why:'开发初衷',hint:'移动指针，或让兔子挥动锤子。',jump:'浏览各个区域'},
    'zh-Hant': {stage:'鍛造工坊',light:'燈光',forge:'揮動鐵鎚',shelf:'更新紀錄',shelfNote:'點選海報可放大檢視。',guide:'網頁體驗',games:'遊戲相容性',features:'主要功能',why:'開發初衷',hint:'移動游標，或讓兔子揮動鐵鎚。',jump:'瀏覽各個區域'}
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

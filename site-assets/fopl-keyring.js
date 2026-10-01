(() => {
  'use strict';
  const fine=matchMedia('(hover: hover) and (pointer: fine)');
  const reduced=matchMedia('(prefers-reduced-motion: reduce)');
  const ownScript=document.currentScript;
  const assetURL=new URL('fopl/keyring.webp',ownScript.src).href;
  const labels={ko:['포플 키링','포플 키링 숨기기','포플 키링 표시'],en:['Fopl keyring','Hide Fopl keyring','Show Fopl keyring'],de:['Fopl-Anhänger','Fopl-Anhänger ausblenden','Fopl-Anhänger anzeigen'],es:['Llavero de Fopl','Ocultar el llavero de Fopl','Mostrar el llavero de Fopl'],fr:['Porte-clés Fopl','Masquer le porte-clés Fopl','Afficher le porte-clés Fopl'],ja:['ポプルのキーホルダー','キーホルダーを非表示','キーホルダーを表示'],'zh-Hans':['Fopl 钥匙扣','隐藏 Fopl 钥匙扣','显示 Fopl 钥匙扣'],'zh-Hant':['Fopl 鑰匙圈','隱藏 Fopl 鑰匙圈','顯示 Fopl 鑰匙圈']};
  let enabled=true,inside=false,ready=false,frame=0,lastTime=0,lastX=0,angle=0,velocity=0,clickDirection=1;
  let x=0,y=0,drawX=NaN,drawY=NaN,root,image,toggle;
  const allowed=()=>enabled&&fine.matches&&!reduced.matches&&!document.hidden;
  const clamp=(v,min,max)=>Math.max(min,Math.min(max,v));
  const stop=()=>{if(frame)cancelAnimationFrame(frame);frame=0;lastTime=0;angle=0;velocity=0;inside=false;if(root)root.hidden=true;};
  const schedule=()=>{if(!frame&&ready&&inside&&allowed())frame=requestAnimationFrame(tick);};
  const tick=time=>{
    frame=0;if(!inside||!allowed()){stop();return;}
    const dt=lastTime?clamp((time-lastTime)/1000,.001,.032):1/60;lastTime=time;
    velocity=clamp(velocity+clamp(x-lastX,-30,30)*3,-240,240);lastX=x;
    velocity+=(-80*angle-12*velocity)*dt;angle=clamp(angle+velocity*dt,-23,23);
    root.hidden=false;
    if(x!==drawX||y!==drawY){root.style.transform='translate3d('+(x-36).toFixed(2)+'px,'+(y+58).toFixed(2)+'px,0)';drawX=x;drawY=y;}
    image.style.transform='rotate('+angle.toFixed(3)+'deg)';
    if(Math.abs(angle)>.03||Math.abs(velocity)>.08)schedule();
    else{angle=0;velocity=0;lastTime=0;image.style.transform='rotate(0deg)';}
  };
  const prepare=()=>{
    if(root)return;
    root=document.createElement('div');root.className='fopl-keyring';root.hidden=true;root.setAttribute('aria-hidden','true');
    image=document.createElement('img');image.alt='';image.width=144;image.height=162;image.draggable=false;image.decoding='async';
    image.addEventListener('load',()=>{ready=true;schedule();},{once:true});
    image.addEventListener('error',()=>{enabled=false;stop();updateToggle();},{once:true});
    root.append(image);document.body.append(root);image.src=assetURL;
  };
  const move=event=>{
    if(event.pointerType!=='mouse'||!event.isPrimary||!allowed())return;
    x=event.clientX;y=event.clientY;
    if(!inside){lastX=x;drawX=NaN;drawY=NaN;inside=true;}
    prepare();schedule();
  };
  const updateToggle=()=>{
    const permitted=fine.matches&&!reduced.matches;
    if(!permitted){if(toggle)toggle.hidden=true;stop();return;}
    if(!toggle){const footer=document.querySelector('.fp-footer');if(!footer)return;
      toggle=document.createElement('button');toggle.type='button';toggle.className='fopl-keyring-toggle';
      const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox','0 0 15 19');svg.setAttribute('aria-hidden','true');
      const path=document.createElementNS('http://www.w3.org/2000/svg','path');path.setAttribute('d','M7.5 1a3 3 0 1 0 0 6 3 3 0 0 0 0-6Zm0 5v4m-4 0h8v7h-8Z');svg.append(path);
      toggle.append(svg,document.createElement('span'));toggle.addEventListener('click',()=>{enabled=!enabled;stop();updateToggle();});footer.append(toggle);
    }
    toggle.hidden=false;const copy=labels[document.documentElement.lang]||labels.en;
    toggle.lastChild.textContent=copy[0];toggle.setAttribute('aria-pressed',String(enabled));toggle.setAttribute('aria-label',copy[enabled?1:2]);toggle.title=copy[enabled?1:2];
  };
  document.addEventListener('pointermove',move,{passive:true});
  document.addEventListener('pointerdown',event=>{if(event.pointerType!=='mouse'||!event.isPrimary||!allowed())return;move(event);velocity=clamp(velocity+clickDirection*110,-240,240);clickDirection*=-1;schedule();},{passive:true});
  document.documentElement.addEventListener('pointerleave',stop,{passive:true});
  window.addEventListener('blur',stop);
  document.addEventListener('visibilitychange',()=>{if(document.hidden)stop();});
  window.addEventListener('pagehide',stop);
  fine.addEventListener('change',updateToggle);reduced.addEventListener('change',updateToggle);
  document.addEventListener('forgeplay:localechange',updateToggle);
  updateToggle();
})();

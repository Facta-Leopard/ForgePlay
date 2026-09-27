(() => {
  'use strict';
  if(!document.body.classList.contains('fp-site'))return;
  const root='site-assets/arcade/';
  const reduce=matchMedia('(prefers-reduced-motion: reduce)'),fine=matchMedia('(hover:hover) and (pointer:fine)');
  let paused=false;
  const copy={
    ko:['움직임 멈춤','움직임 재생','망치 휘두르기'],en:['Pause motion','Resume motion','Swing the hammer'],
    de:['Bewegung anhalten','Bewegung starten','Hammer schwingen'],es:['Pausar movimiento','Reanudar movimiento','Golpear con el martillo'],
    fr:['Arrêter le mouvement','Reprendre le mouvement','Frapper au marteau'],ja:['動きを停止','動きを再開','ハンマーを振る'],
    'zh-Hans':['暂停动画','继续动画','挥动锤子'],'zh-Hant':['暫停動畫','繼續動畫','揮動鐵鎚']
  };
  const words=()=>copy[document.documentElement.lang]||copy.en;
  const scenes=[];
  // A short lift, a held anticipation, a fast downswing, contact and rebound.
  // All poses share a 1300 × 1210 canvas. The anvil stays on its baseline.
  const strikePoses=[
    {until:.12,name:'down'}, {until:.37,name:'raised'}, {until:.43,name:'down'},
    {until:.58,name:'contact'}, {until:.69,name:'down'}, {until:.82,name:'contact'}
  ];
  function showPose(field,name) {
    if(!field.hammer||field.scene.dataset.hammerPose===name)return;
    field.character.src=field.hammer.frames[name].src;
    field.scene.dataset.hammerPose=name;
  }
  function syncStrikeButton(field) {
    if(field.strike)field.strike.disabled=!field.hammer||field.hammer.elapsed!==null||paused||reduce.matches||document.hidden||!field.visible;
  }
  function resetStrike(field) {
    if(!field.hammer)return;
    field.hammer.elapsed=null;field.hammer.wait=1.6;field.hammer.impacted=false;
    field.burst=0;showPose(field,'contact');syncStrikeButton(field);
  }
  function beginStrike(field) {
    if(!field.hammer||field.hammer.elapsed!==null||paused||reduce.matches||document.hidden||!field.visible)return;
    field.hammer.elapsed=0;field.hammer.impacted=false;field.burst=0;
    showPose(field,'down');syncStrikeButton(field);
  }
  function stepStrike(field,delta) {
    const hammer=field.hammer;if(!hammer)return;
    if(hammer.elapsed===null){hammer.wait-=delta;if(hammer.wait<=0)beginStrike(field);return;}
    hammer.elapsed+=delta;
    const pose=strikePoses.find(p=>hammer.elapsed<p.until);
    if(!pose){hammer.elapsed=null;hammer.wait=4.2;showPose(field,'contact');syncStrikeButton(field);return;}
    showPose(field,pose.name);
    if(hammer.elapsed>=.43&&!hammer.impacted){hammer.impacted=true;field.burst=1;}
  }
  async function loadHammer(field) {
    try {
      const frames=Object.fromEntries(await Promise.all(['raised','down','contact'].map(async name=>{
        const frame=new Image();frame.src=root+'hammer/'+name+'.png';await frame.decode();return [name,frame];
      })));
      field.hammer={frames,elapsed:null,wait:1.6,impacted:false};
      field.scene.classList.add('pixel-hammer-ready');showPose(field,'contact');syncStrikeButton(field);resume();
    } catch {
      // Decorative artwork is optional. Keep the original still if a pose cannot load.
      field.character.src=root+'assets/smith.png';syncStrikeButton(field);
    }
  }
  function image(file,klass,kind) {
    const img=document.createElement('img');img.src=root+'assets/'+file;img.alt='';img.className='pixel-layer '+klass;img.dataset.pixelLayer=kind;img.decoding='async'; return img;
  }
  function makeScene(host,kind) {
    if(kind==='forge'&&!host.id)host.id='pixel-forge';
    const scene=document.createElement('div');scene.className='pixel-scene pixel-'+kind;scene.setAttribute('aria-hidden','true');
    if(kind==='forge') {
      const smith=image('../hammer/contact.png','pixel-character','rabbit');smith.width=1300;smith.height=1210;
      scene.append(image('workshop.png','pixel-background','background'),smith,image('tools.png','pixel-foreground','props'));
    }
    else {scene.append(image('world.png','pixel-background','background'),image('explorer.png','pixel-character','rabbit'));const bridge=document.createElement('div');bridge.className='pixel-bridge';bridge.dataset.pixelLayer='props';scene.append(bridge);}
    const motes=document.createElement('canvas');motes.className='pixel-motes';scene.append(motes);
    host.prepend(scene);host.classList.add('pixel-art-host');
    const ctx=motes.getContext('2d');const field={host,scene,ctx,canvas:motes,kind,character:scene.querySelector('.pixel-character'),visible:false,time:0,burst:0,width:0,height:0,sparkX:.60,sparkY:.73};scenes.push(field);
    const resize=()=>{const rect=host.getBoundingClientRect(),style=getComputedStyle(host);field.sparkX=parseFloat(style.getPropertyValue('--pixel-spark-x'))||.60;field.sparkY=parseFloat(style.getPropertyValue('--pixel-spark-y'))||.73;field.width=Math.round(rect.width/3);field.height=Math.round(rect.height/3);motes.width=field.width;motes.height=field.height;if(ctx)ctx.imageSmoothingEnabled=false;draw(field,0);};
    new ResizeObserver(resize).observe(host);resize();
    host.addEventListener('pointermove',event=>{
      if(reduce.matches||paused||!fine.matches)return;
      const rect=host.getBoundingClientRect();
      const x=Math.round((event.clientX-rect.left-rect.width/2)/rect.width*12),y=Math.round((event.clientY-rect.top-rect.height/2)/rect.height*9);
      host.style.setProperty('--pixel-x',x+'px');host.style.setProperty('--pixel-y',y+'px');
    },{passive:true});
    host.addEventListener('pointerleave',()=>{host.style.setProperty('--pixel-x','0px');host.style.setProperty('--pixel-y','0px');});
    if(kind==='forge') {
      const plates=document.createElement('div');plates.className='pixel-plates';plates.setAttribute('aria-hidden','true');
      for(const [mark,label] of [['X','DirectX'],['M','Metal']]) { const plate=document.createElement('span');plate.className='pixel-plate';const strong=document.createElement('strong');strong.textContent=mark;const text=document.createElement('small');text.textContent=label;plate.append(strong,text);plates.append(plate); }host.append(plates);
      const strike=document.createElement('button');strike.type='button';strike.className='pixel-strike';strike.setAttribute('aria-label',words()[2]);strike.textContent=words()[2];strike.disabled=true;field.strike=strike;
      strike.addEventListener('click',()=>{beginStrike(field);resume();});host.append(strike);
      loadHammer(field);
    }
  }
  document.querySelectorAll('.fp-panorama').forEach(host=>makeScene(host,'forge'));
  document.querySelectorAll('.fp-purpose-art,.story-art').forEach(host=>makeScene(host,'outlook'));

  let raf=0,last=0,time=0;
  function draw(field,t) {
    const {ctx,width:w,height:h,kind}=field;if(!ctx||!w||!h)return;ctx.clearRect(0,0,w,h);
    const forge=kind==='forge';
    // Forge sparks originate only from a hammer impact, never from an ambient loop.
    for(let i=0;i<(forge?0:10);i++) {
      const age=(t*(forge ? .16 : .045)+i*.173)%1;
      const x=forge?w*field.sparkX+Math.sin(i*2.7)*age*w*.15:w*(.10+(i*.173)% .8);
      const y=forge?h*field.sparkY-age*h*.55:h*(1-age);
      ctx.globalAlpha=Math.round(Math.sin(age*Math.PI)*3)/4;ctx.fillStyle=i%3?'#f3bb71':'#87a9a2';ctx.fillRect(Math.round(x),Math.round(y),i%4?1:2,i%4?1:2);
    }
    if(field.burst>0){
      const host=field.host.getBoundingClientRect(),sprite=field.character.getBoundingClientRect();
      const x=(sprite.left-host.left+sprite.width*525/1300)/host.width*w;
      const y=(sprite.top-host.top+sprite.height*789/1210)/host.height*h;
      const age=1-field.burst;
      if(age<.12){ctx.globalAlpha=1-age/.12;ctx.fillStyle='#fff3c7';ctx.fillRect(Math.round(x)-3,Math.round(y)-2,6,3);}
      for(let i=0;i<18;i++){ctx.globalAlpha=field.burst;ctx.fillStyle=i%3?'#ffd29a':'#d18c45';ctx.fillRect(Math.round(x+Math.cos(i*2.4)*age*w*.17),Math.round(y-Math.abs(Math.sin(i*1.9))*age*h*.42+age*age*h*.12),i%4?1:2,2);}
    }
    ctx.globalAlpha=1;
  }
  function frame(now){raf=0;if(paused||reduce.matches||document.hidden||!scenes.some(s=>s.visible)){last=0;return;}if(!last||now-last>=33){const delta=last?Math.min(.1,(now-last)/1000):0;time+=delta;last=now;for(const scene of scenes)if(scene.visible){scene.burst=Math.max(0,scene.burst-delta*2.2);stepStrike(scene,delta);draw(scene,time);}}raf=requestAnimationFrame(frame);}
  function resume(){document.body.classList.toggle('pixel-paused',paused||reduce.matches||document.hidden);if(paused||reduce.matches||document.hidden){cancelAnimationFrame(raf);raf=0;last=0;scenes.forEach(s=>{s.host.style.setProperty('--pixel-x','0px');s.host.style.setProperty('--pixel-y','0px');resetStrike(s);draw(s,0);});}else if(scenes.some(s=>s.visible)){if(!raf)raf=requestAnimationFrame(frame);}else{cancelAnimationFrame(raf);raf=0;last=0;}scenes.forEach(syncStrikeButton);}
  const observer=new IntersectionObserver(entries=>{for(const entry of entries){const scene=scenes.find(s=>s.host===entry.target);if(scene){scene.visible=entry.isIntersecting;scene.host.classList.toggle('pixel-visible',entry.isIntersecting);if(!scene.visible)resetStrike(scene);}}resume();},{rootMargin:'20px'});scenes.forEach(scene=>observer.observe(scene.host));

  const controls = document.createElement('div');controls.className='arcade-art-controls';
  const pause = document.createElement('button');pause.type='button';pause.className='arcade-motion-toggle';pause.setAttribute('aria-pressed','false');controls.append(pause);
  const mainScene=document.querySelector('.fp-panorama,.fp-purpose-art,.story-art');
  if(mainScene)mainScene.append(controls);
  function updateLabels(){pause.textContent=words()[paused?1:0];document.querySelectorAll('.pixel-strike').forEach(button=>button.setAttribute('aria-label',words()[2]));}
  pause.addEventListener('click',()=>{paused=!paused;pause.setAttribute('aria-pressed',String(paused));updateLabels();resume();});
  document.addEventListener('forgeplay:localechange',updateLabels);updateLabels();
  document.addEventListener('visibilitychange',resume);reduce.addEventListener('change',resume);
  document.body.classList.add('arcade-art-ready');
})();

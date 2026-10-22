(() => {
  'use strict';
  // Presentation-only model. No native processes, device access, or persisted settings.
  const initial = () => ({mode:'compact',position:'left',chatter:true,reactions:true,hidden:false,closed:false,keyringVisible:true,alwaysOnTop:true});
  const transition = (state, action, value) => {
    const next={...state};
    if(action==='mode'&&['compact','expanded','keyring'].includes(value)){next.mode=value;next.hidden=false;}
    if(action==='position'&&['left','center','right'].includes(value))next.position=value;
    if(action==='chatter'||action==='reactions'||action==='alwaysOnTop')next[action]=!state[action];
    if(action==='hide')next.hidden=true;
    if(action==='quit'){next.hidden=true;next.closed=true;}
    if(action==='restore')next.hidden=false;
    if(action==='keyringVisible')next.keyringVisible=!state.keyringVisible;
    if(!next.keyringVisible&&next.mode==='keyring')next.mode='compact';
    return next;
  };
  const create = ({root,shell,copy,locale,light,title,renderCompact,home,settings,advanced,setAdvanced,onChatter,refresh,ticker,restart,lupain,toggleLupain,openLupain}) => {
    const n=(tag,cls='',text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const t=key=>copy.strings[key]?.[Math.max(0,copy.locales.indexOf(locale()))]||key;
    let state=initial(),animation=null,bubbleTimer=0,chatterTimer=0,lastImpulse=0,lastPointer=null,inView=true,phrase=0,clicks=0,lastClick=0,menu=null,drag=null;
    const reduced=matchMedia('(prefers-reduced-motion: reduce)');
    const stage=n('div','island-stage'),panel=n('div','island-panel'),chrome=n('header','island-chrome'),compact=n('div','island-compact');
    const companion=n('div','island-companion'),fopl=n('button','island-fopl'),pivot=n('span','island-fopl-pivot'),sprite=n('span','island-fopl-sprite'),bubble=n('p','island-bubble');
    const recovery=n('button','island-recovery');recovery.type=fopl.type='button';bubble.hidden=true;recovery.hidden=true;
    fopl.setAttribute('aria-haspopup','dialog');sprite.setAttribute('aria-hidden','true');pivot.append(sprite);fopl.append(pivot);companion.append(fopl,bubble);
    shell.before(stage);stage.append(panel,companion,recovery);panel.append(chrome,compact,shell);
    const button=(key,action,text)=>{const b=n('button','',text===undefined?t(key):text);b.type='button';b.setAttribute('aria-label',t(key));b.title=t(key);b.addEventListener('click',action);return b;};
    const symbolButton=(key,action,symbol)=>{const b=button(key,action,'');b.append(window.ForgePlayGuideIcons.icon(symbol,22));return b;};
    const visible=()=>!document.hidden&&inView&&!state.hidden&&!root.querySelector('dialog[open]');
    const active=()=>visible()&&state.keyringVisible;
    const quiet=()=>{animation?.cancel();animation=null;clearTimeout(bubbleTimer);clearTimeout(chatterTimer);bubble.hidden=true;sprite.dataset.pose='idle';};
    const speak=(key='hello')=>{
      if(!active())return;
      clearTimeout(bubbleTimer);bubble.textContent=t(key);bubble.hidden=false;sprite.dataset.pose='talk';
      bubbleTimer=setTimeout(()=>{bubble.hidden=true;sprite.dataset.pose='idle';},4200);
    };
    const impulse=(direction=1,force=8)=>{
      if(!active()||reduced.matches)return;
      const now=performance.now();if(now-lastImpulse<140)return;lastImpulse=now;
      animation?.cancel();animation=pivot.animate([0,-force*direction,force*.62*direction,-force*.3*direction,force*.1*direction,0].map(v=>({transform:`rotate(${v}deg)`})),{duration:1100,easing:'ease-out'});
    };
    const scheduleChatter=()=>{
      clearTimeout(chatterTimer);
      if(!state.chatter||!active())return;
      chatterTimer=setTimeout(()=>{if(state.chatter&&active())speak(['tipFold','tipMenu','tipHome','hello'][phrase++%4]);scheduleChatter();},18000);
    };
    const syncActivity=()=>{stage.dataset.paused=String(!visible());if(!active())quiet();else scheduleChatter();};
    const menuAnchor=()=>state.keyringVisible?fopl:chrome.querySelector('[data-island-menu]');
    const closeMenu=()=>{if(menu){menu.remove();menu=null;}menuAnchor()?.focus({preventScroll:true});};
    const change=(action,value)=>{state=transition(state,action,value);if(action==='chatter')onChatter(state.chatter);if(action==='hide')quiet();refresh();if(action==='hide')recovery.focus({preventScroll:true});else if(action==='mode'&&state.mode!=='keyring')chrome.querySelector('[data-island-handle]')?.focus({preventScroll:true});else menuAnchor()?.focus({preventScroll:true});};
    const openMenu=event=>{
      event?.preventDefault();if(menu){closeMenu();return;}
      menu=n('div','island-menu');menu.setAttribute('role','dialog');menu.setAttribute('aria-label',t('menu'));menu.tabIndex=-1;
      const add=(key,action,pressed)=>{const b=button(key,action);if(pressed!==undefined)b.setAttribute('aria-pressed',String(pressed));menu.append(b);return b;};
      add('compact',()=>{closeMenu();change('mode','compact');},state.mode==='compact');
      add('expanded',()=>{closeMenu();change('mode','expanded');},state.mode==='expanded');
      add('keyring',()=>{closeMenu();change('mode','keyring');},state.mode==='keyring').disabled=!state.keyringVisible;
      add('keyringVisible',()=>{closeMenu();change('keyringVisible');},state.keyringVisible);
      add('hide',()=>{closeMenu();change('hide');});menu.append(n('hr'));
      for(const key of ['chatter','reactions'])add(key,()=>{closeMenu();change(key);},state[key]);
      add('alwaysOnTop',()=>{closeMenu();change('alwaysOnTop');},state.alwaysOnTop).title=t('topDemo');
      add('lupainToggle',()=>{closeMenu();toggleLupain();},lupain());
      add('lupainOpen',()=>{closeMenu();openLupain();});
      const group=n('fieldset'),legend=n('legend','',t('position'));group.append(legend);
      for(const value of ['left','center','right']){const b=button(value,()=>{closeMenu();change('position',value);});b.setAttribute('aria-pressed',String(state.position===value));group.append(b);}menu.append(group);
      add('advanced',()=>{closeMenu();setAdvanced(!advanced());refresh();},advanced());menu.append(n('hr'));
      add('settings',()=>{closeMenu();settings();});add('close',closeMenu);stage.append(menu);
      const rect=menuAnchor().getBoundingClientRect(),bounds=stage.getBoundingClientRect();
      menu.style.left=Math.max(8,Math.min(rect.left-bounds.left+50,bounds.width-280))+'px';
      menu.style.top=Math.max(8,rect.top-bounds.top-70)+'px';
      menu.addEventListener('keydown',e=>{if(e.key==='Escape'){e.stopPropagation();closeMenu();}if(e.key==='Tab'){const items=[...menu.querySelectorAll('button')];if(e.shiftKey&&document.activeElement===items[0]){e.preventDefault();items.at(-1).focus();}else if(!e.shiftKey&&document.activeElement===items.at(-1)){e.preventDefault();items[0].focus();}}});
      menu.querySelector('button').focus({preventScroll:true});
    };
    fopl.addEventListener('contextmenu',openMenu);
    panel.addEventListener('contextmenu',openMenu);
    fopl.addEventListener('keydown',e=>{if(e.key==='ContextMenu'||(e.shiftKey&&e.key==='F10'))openMenu(e);});
    fopl.addEventListener('click',()=>{
      if(!state.reactions){openMenu();return;}
      const now=performance.now();clicks=now-lastClick<900?clicks+1:1;lastClick=now;
      impulse(clicks%2?1:-1,clicks>2?15:9);speak(clicks>2?'tickle':'hello');sprite.dataset.pose=clicks>2?'laugh':'react';
    });
    // Touch and keyboard users can open the same options without a context-click.
    const options=button('menu',openMenu,'···');options.className='island-fopl-options';companion.append(options);
    recovery.addEventListener('click',()=>{if(state.closed){state=initial();restart();refresh();}else change('restore');});
    stage.addEventListener('pointermove',event=>{
      if(!event.isPrimary||event.pointerType==='touch')return;
      if(lastPointer!==null&&Math.abs(event.clientX-lastPointer)>5)impulse(event.clientX>lastPointer?1:-1,4);
      lastPointer=event.clientX;
    },{passive:true});
    stage.addEventListener('pointerleave',()=>{lastPointer=null;});
    stage.addEventListener('click',event=>{if(menu&&!menu.contains(event.target)&&!companion.contains(event.target)&&!event.target.closest('[data-island-menu]'))closeMenu();else if(!companion.contains(event.target))impulse(1,5);});
    const observer=new IntersectionObserver(entries=>{inView=entries[0].isIntersecting;syncActivity();});observer.observe(stage);
    const visibility=()=>syncActivity();document.addEventListener('visibilitychange',visibility);
    reduced.addEventListener('change',quiet);
    const render=()=>{
      const restoreMenu=Boolean(menu);
      if(menu){menu.remove();menu=null;}
      stage.classList.toggle('island-light',light());stage.dataset.mode=state.mode;stage.dataset.position=state.position;
      stage.dataset.keyringVisible=String(state.keyringVisible);
      stage.dataset.alwaysOnTop=String(state.alwaysOnTop);
      panel.hidden=state.hidden||state.mode==='keyring';companion.hidden=state.hidden||!state.keyringVisible;recovery.hidden=!state.hidden;recovery.textContent=t(state.closed?'restartDemo':'restore');
      shell.hidden=state.mode!=='expanded';compact.hidden=state.mode!=='compact';
      fopl.setAttribute('aria-label',t('fopl'));options.setAttribute('aria-label',t('menu'));options.title=t('menu');
      chrome.replaceChildren();const handle=button('handle',event=>{if(event.detail===0)change('mode',state.mode==='expanded'?'compact':'expanded');},'');handle.className='island-handle';handle.setAttribute('aria-expanded',String(state.mode==='expanded'));handle.dataset.islandHandle='';
      handle.addEventListener('pointerdown',event=>{if(event.button!==0)return;drag={y:event.clientY,id:event.pointerId};handle.setPointerCapture(event.pointerId);});
      handle.addEventListener('pointerup',event=>{if(!drag)return;const delta=event.clientY-drag.y;drag=null;change('mode',Math.abs(delta)>24?(delta>0?'expanded':'compact'):(state.mode==='expanded'?'compact':'expanded'));});
      handle.addEventListener('pointercancel',()=>{drag=null;});
      const row=n('div','island-chrome-row'),lights=n('span','island-lights');lights.append(button('quit',()=>change('quit'),'●'),button('minimize',()=>change('hide'),'●'));
      const titleNode=n('strong','island-title',title());row.append(lights,titleNode);
      const controls=n('div','island-controls');controls.append(symbolButton('keyring',()=>change('mode','keyring'),'collapseAll'),symbolButton(state.mode==='expanded'?'compact':'expanded',()=>change('mode',state.mode==='expanded'?'compact':'expanded'),state.mode==='expanded'?'collapse':'expand'));
      controls.firstElementChild.disabled=!state.keyringVisible;
      const menuButton=button('menu',openMenu,'···');menuButton.dataset.islandMenu='';menuButton.setAttribute('aria-haspopup','dialog');controls.append(menuButton);
      const brand=button('home',home,''),image=n('img');image.src='site-assets/forgeplay-icon.png';image.alt='';image.width=image.height=28;brand.append(image);controls.append(brand);row.append(controls);chrome.append(handle,row,ticker());
      compact.replaceChildren();if(state.mode==='compact')renderCompact(compact);
      syncActivity();if(restoreMenu)openMenu();
    };
    const reset=()=>{quiet();state=initial();render();};
    const setMode=(mode,update=true)=>{state=transition(state,'mode',mode);if(update)refresh();};
    window.addEventListener('pagehide',()=>{quiet();observer.disconnect();document.removeEventListener('visibilitychange',visibility);reduced.removeEventListener('change',quiet);},{once:true});
    return {render,reset,setMode,speak,get mode(){return state.mode;},get alwaysOnTop(){return state.alwaysOnTop;},setAlwaysOnTop(value){state.alwaysOnTop=Boolean(value);},setChatter(value){state.chatter=Boolean(value);syncActivity();}};
  };
  window.ForgePlayIslandDemo=Object.freeze({initial,transition,create});
})();

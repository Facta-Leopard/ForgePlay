(() => {
  'use strict';
  // UI-only port of VRDashboard/VRDevicesView. No native bridge, device API or persistence.
  const initial = () => ({page:'play',environment:null,listening:false,connected:false,tracking:false,
    steam:false,remembered:false,mode:'combined',controller:'mac',quality:1600,showCode:false,
    theme:'dark',topic:'start',error:false,game:false,bindings:{}});
  const locked = state => state.connected || state.steam;
  const transition = (state, action, value) => {
    const next = {...state};
    if(action==='environment' && !state.steam && ['shared','own',null].includes(value)) next.environment=value;
    if(action==='mode' && !locked(state) && ['hands','gamepad','combined'].includes(value)) next.mode=value;
    if(action==='controller' && !locked(state) && ['mac','vision'].includes(value)) next.controller=value;
    if(action==='quality' && !locked(state) && [1280,1600,1920].includes(value)) next.quality=value;
    if(action==='prepare' && !state.listening) next.listening=true;
    if(action==='connect' && state.listening) {next.connected=true;next.remembered=true;}
    if(action==='track' && state.connected) {next.tracking=true;if(state.environment) next.steam=true;}
    if(action==='steam' && state.environment) next.steam=true;
    if(action==='game' && state.steam && state.tracking) next.game=true;
    if(action==='forceStop') {next.steam=false;next.game=false;}
    if(action==='stop') {next.listening=false;next.connected=false;next.tracking=false;next.steam=false;next.game=false;next.showCode=false;}
    if(action==='resetPairing') {next.connected=false;next.tracking=false;next.remembered=false;next.showCode=false;}
    return next;
  };
  const bitrate = quality => Math.min(100,Math.max(25,Math.round(60*(quality/1600)**2/5)*5));
  const create = ({copy,locale,exit}) => {
    let state=initial(),host,modal=null,modalReturn=null,scroll=0;
    const t=(key,values={})=>Object.entries(values).reduce((text,[key,value])=>text.replaceAll('{'+key+'}',String(value)),copy.strings[key][Math.max(0,copy.locales.indexOf(locale()))]);
    const n=(tag,cls='',text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const icon=(name,size=18)=>window.ForgePlayGuideIcons.icon(name,size);
    const button=(key,action,style='',glyph)=>{const b=n('button','vr-button '+style);b.type='button';b.dataset.vrAction=key;if(glyph)b.append(icon(glyph));b.append(n('span','',t(key)));b.addEventListener('click',action);return b;};
    const p=(key,values)=>n('p','vr-muted',t(key,values));
    const row=(...children)=>{const e=n('div','vr-actions');e.append(...children);return e;};
    const help=(key)=>{const b=button('help',()=>open('help',key),'vr-icon','info');b.setAttribute('aria-label',t('help')+' · '+t(key));return b;};
    const panel=(title,subtitle,glyph)=>{const e=n('section','vr-panel'),h=n('div','vr-panel-heading');h.append(icon(glyph,21),n('h3','',t(title)));if(subtitle)h.append(help(subtitle));e.append(h);return e;};
    const pill=(text,good=false)=>{const e=n('span','vr-pill'+(good?' is-ready':''));e.append(icon(good?'checkCircle':'vision',14),n('span','',text));return e;};
    const set=(action,value)=>{state=transition(state,action,value);render();};
    const go=(page,topic)=>{state.page=page;if(topic)state.topic=topic;scroll=0;render(true);};
    const open=(type,value)=>{modal={type,value};modalReturn=document.activeElement?.dataset?.vrAction;render();};
    const close=()=>{modal=null;render();};
    const linkText=(key,action)=>button(key,action,'vr-text');
    const choice=(key,action,selected,disabled=false,glyph,detail)=>{const b=button(key,action,'vr-choice',glyph);b.setAttribute('aria-pressed',String(selected));b.disabled=disabled;if(detail)b.append(n('small','',t(detail)));b.append(icon(selected?'checkCircleFill':'circle',17));return b;};
    const disclosure=(key,child)=>{const d=n('details','vr-disclosure');d.append(n('summary','',t(key)),child);return d;};
    const status=()=>t(state.tracking?'trackingReady':state.listening?'waitingConnection':state.steam?'steamRunning':'beforeSession');
    const portal=()=>{const art=n('div','vr-portal');art.setAttribute('aria-hidden','true');art.append(n('i','vr-floor'),n('i','vr-orbit one'),n('i','vr-orbit two'),n('i','vr-orbit three'),icon('visionFill',130),n('i','vr-star'));return art;};
    const headingKey=()=>!state.environment?'heroSteam':!state.listening?'heroConnect':!state.connected?(state.remembered?'heroRemembered':'heroPair'):!state.tracking?'heroTracking':!state.steam?'heroReady':'heroPlay';
    const nextKey=()=>!state.environment?'connectSteam':!state.listening?'prepareVision':!state.connected?'waitingVision':!state.tracking?'trackingHelp':!state.steam?'launchSteam':'reopenSteam';
    const next=()=>{if(!state.environment)open('environment');else if(!state.listening)set('prepare');else if(!state.connected)return;else if(!state.tracking)go('guide','display');else if(!state.steam)set('steam');else open('help','steamHelp');};
    const environmentSheet=body=>{
      body.append(p('environmentHelp'),p('examplePaths'));
      const pick=n('div','vr-environment-choice');pick.append(icon('display',24),n('strong','','ForgePlay Steam'),n('code','','…/ForgePlay/Prefixes/SteamShared'),icon('checkCircleFill',20));body.append(pick,p('closeDesktop'));
      body.append(row(button('folder',()=>open('folder'),'','folder'),button('cancel',close),button('useSteam',()=>{modal=null;set('environment','shared');},'primary')));
    };
    const connection=()=>{
      const box=panel('visionConnection','connectionHelp','vision');
      const device=n('div','vr-device');device.append(icon('display',28),n('strong','',t('exampleMac')),pill(t(state.connected?'connected':state.listening?'waitingVision':'beforeConnection'),state.connected));box.append(device);
      if(!state.listening){box.append(p('connectionHelp'),button('prepare',()=>set('prepare'),'primary','wifi'));}
      else if(state.connected){box.append(pill(t(state.tracking?'trackingReady':'connectedPreparing'),state.tracking),p(state.tracking?'steamHelp':'trackingInstructions'),p('audioHelp'));}
      else if(state.remembered){box.append(pill(t('rememberedDevice'),true),p('rememberedHelp'));}
      else{
        box.append(p('codeInstructions'));const code=n('div','vr-code'),head=row(n('small','',t('code')),button(state.showCode?'hideCode':'showCode',()=>{state.showCode=!state.showCode;render();},'vr-icon','eye'));
        code.append(head,n('code','',state.showCode?'DEMO 1234 DEMO 5678\nDEMO 9012 DEMO 3456':'•••• •••• •••• ••••\n•••• •••• •••• ••••'),linkText('copyCode',()=>open('help','codeExample')));box.append(code,p('codeExample'),disclosure('qr',p('qrHelp')));
      }
      box.append(linkText('resetPairing',()=>open('confirm','resetPairing')));return box;
    };
    const environment=()=>{
      const box=panel('steamEnvironment','environmentHelp','link');
      box.append(p(state.environment==='shared'?'sharedHelp':state.environment==='own'?'ownHelp':'chooseEnvironment'));
      if(state.environment)box.append(pill(t(state.environment==='shared'?'shared':'own'),true));
      const choose=button(state.environment?'otherSteam':'connectSteam',()=>open('environment'),'','folder');choose.disabled=state.steam;const controls=row(choose);
      if(state.environment==='shared'){controls.append(button('finder',()=>open('help','examplePaths')));const detach=button('disconnect',()=>set('environment',null));detach.disabled=state.steam;controls.append(detach);}
      box.append(controls,disclosure('whereFolder',p('folderHelp')),p('runtimeHelp'));
      if(!state.environment){const install=n('div');install.append(p('installHelp'),button('installer',()=>open('install'),'','download'));box.append(disclosure('installOwn',install));}
      return box;
    };
    const play=body=>{
      const hero=n('section','vr-hero'),copy=n('div','vr-hero-copy');copy.append(n('small','vr-eyebrow','FORGEPLAY / PCVR'),n('h3','',t(headingKey())),p(headingKey()+'Body'));
      const main=button(nextKey(),next,'primary',state.tracking?'play':'arrow');main.disabled=Boolean(state.environment&&state.listening&&!state.connected);const buttons=row(main);
      if(state.environment&&!state.steam)buttons.append(button('inputSettings',()=>go('devices')));copy.append(buttons);
      if(state.environment&&!state.steam&&!state.tracking)copy.append(linkText('steamFirst',()=>set('steam')));
      if(state.steam)copy.append(pill(t('steamRunning'),true));hero.append(copy,portal());body.append(hero);
      if(state.environment&&state.listening&&!state.connected)body.append(connection());
      const steps=n('div','vr-readiness');for(const [i,key,ready,action] of [[1,'existingSteam',!!state.environment,()=>state.environment?go('devices'):open('environment')],[2,'vision',state.connected,()=>go('devices')],[3,'playReady',state.tracking,()=>go('guide','display')]]){const b=button(key,action,'vr-step');b.prepend(n('span','vr-step-number',ready?'✓':String(i).padStart(2,'0')));b.append(n('small','',t(ready?'ready':'notReady')));steps.append(b);}body.append(steps);
      const lower=n('div','vr-two'),summary=panel('myEnvironment',null,'sliders');
      for(const [key,value]of [['existingSteam',state.environment==='shared'?'shared':state.environment==='own'?'own':'notReady'],['input',state.mode]]){const r=n('div','vr-summary');r.append(n('span','',t(key)),n('strong','',t(value)));summary.append(r);}
      if(state.mode!=='hands')summary.append(p('controllerLocationValue',{device:state.controller==='mac'?'Mac':'Vision Pro'}));summary.append(linkText('changeEnvironment',()=>go('devices')));
      const start=panel('newHere',null,'book');start.append(p('startHelp'),button('openGuide',()=>go('guide','start'),'','arrow'));lower.append(summary,start);body.append(lower);
    };
    const devices=body=>{
      const top=n('div','vr-device-grid'),input=panel('playStyle','inputHelp','controller');
      for(const mode of ['hands','gamepad','combined'])input.append(choice(mode,()=>set('mode',mode),state.mode===mode,locked(state),mode==='hands'?'hand':'controller',mode+'Detail'));
      if(state.mode!=='hands'){input.append(p('controllerLocation'));const segments=row();for(const id of ['mac','vision'])segments.append(choice(id,()=>set('controller',id),state.controller===id,locked(state)));input.append(segments,p('controllerSupport'));if(state.controller==='vision')input.append(p('remoteControllerHelp'));}
      if(locked(state))input.append(p('optionsLocked'));top.append(connection(),input);body.append(top);
      const quality=panel('quality','qualityHelp','display'),choices=n('div','vr-quality');
      for(const [value,key]of [[1280,'responsive'],[1600,'balanced'],[1920,'clear']])choices.append(choice(key,()=>set('quality',value),state.quality===value,locked(state),null,key+'Detail'));
      quality.append(choices,p('qualityValue',{size:state.quality,rate:bitrate(state.quality)}),p('qualityHelp'));body.append(quality);
      const controls=panel('gameControls','bindingHelp','sliders'),keyboard=button('keyboard',()=>open('help','keyboardHelp'),'','keyboard');keyboard.disabled=true;
      controls.append(row(button('editBindings',()=>open('bindings'),'','sliders'),keyboard),p(state.game?'sampleGameLoaded':'noGameActions'),p('keyboardHelp'));body.append(controls,environment());
    };
    const topics=['start','prefix','installation','input','display','audio','connection','finish'];
    const guide=body=>{
      const banner=n('div','vr-guide-banner');banner.append(icon('display',25),n('strong','',t('guideIntro')),icon('arrow',20),icon('vision',32));body.append(banner);
      const layout=n('div','vr-guide-layout'),tabs=n('nav','vr-topics');tabs.setAttribute('aria-label',t('guide'));
      for(const id of topics){const b=button('topic'+id,()=>go('guide',id));b.dataset.vrTopic=id;b.setAttribute('aria-current',state.topic===id?'true':'false');tabs.append(b);}
      const article=n('article','vr-panel');article.append(n('h3','',t('topic'+state.topic)));const steps=n('ol','vr-guide-steps');for(const text of t('guide'+state.topic).split('\n'))steps.append(n('li','',text));article.append(steps);layout.append(tabs,article);body.append(layout);
    };
    const select=(body,key,values,value,changed)=>{
      const label=n('label','vr-field'),control=n('select');control.dataset.vrField=key;control.setAttribute('aria-label',t(key));
      for(const [id,text]of values){const option=n('option','',text);option.value=id;option.selected=id===value;control.append(option);}control.addEventListener('change',()=>changed(control.value));label.append(n('span','',t(key)),control);body.append(label);return control;
    };
    const bindingDialog=body=>{
      body.append(p('bindingHelp'),p(state.game?'sampleGameLoaded':'noGameActions'));
      if(!state.game)return;
      const action=modal.value||'primary',layout=n('div','vr-binding-grid'),nav=n('nav');
      for(const key of ['primary','move','menu'])nav.append(choice('action'+key,()=>{modal.value=key;render();},action===key));
      const form=n('div'),saved=state.bindings[action]||{input:'RT',mode:'button',deadzone:15};
      const draft={...saved};form.append(n('strong','','/actions/example/in/'+action));
      select(form,'bindingInput',['RT','LT','RB','LB','A','B','X','Y','Left stick','Right stick','D-Pad'].map(v=>[v,{'Left stick':t('leftStick'),'Right stick':t('rightStick')}[v]||v]),draft.input,v=>{draft.input=v;});
      select(form,'bindingMode',['button','trigger','joystick','scroll'].map(v=>[v,t('mode'+v)]),draft.mode,v=>{draft.mode=v;});
      const range=n('input');range.type='range';range.min=0;range.max=50;range.value=draft.deadzone;range.setAttribute('aria-label',t('deadzone'));const output=n('output','',draft.deadzone+'%');range.addEventListener('input',()=>{draft.deadzone=Number(range.value);output.textContent=draft.deadzone+'%';});const rangeRow=n('label','vr-field');rangeRow.append(n('span','',t('deadzone')),range,output);form.append(rangeRow);
      form.append(row(button('defaults',()=>{delete state.bindings[action];render();}),button('save',()=>{state.bindings[action]={...draft};modal={type:'help',value:'saved'};render();},'primary')));layout.append(nav,form);body.append(layout);
    };
    const renderModal=()=>{
      if(!modal)return;
      const dialog=n('dialog','vr-dialog'+(state.theme==='light'?' vr-light':''));dialog.setAttribute('aria-labelledby','vr-dialog-title');const header=n('div','vr-modal-head');
      const titles={environment:'connectSteam',folder:'folder',install:'installOwn',bindings:'editBindings',diagnostics:'diagnostics',appearance:'appearance',help:'help',confirm:modal.value};
      const title=n('h2','',t(titles[modal.type]));title.id='vr-dialog-title';header.append(title,button('close',close,'vr-icon','close'));dialog.append(header);const body=n('div','vr-modal-body');dialog.append(body);
      if(modal.type==='environment')environmentSheet(body);
      else if(modal.type==='folder'){body.append(p('folderHelp'),p('examplePaths'),button('useExample',()=>{modal=null;set('environment','shared');},'primary'));}
      else if(modal.type==='install'){body.append(p('installHelp'),p('noInstallation'),button('useExample',()=>{modal=null;set('environment','own');},'primary'));}
      else if(modal.type==='help')body.append(p(modal.value));
      else if(modal.type==='appearance')for(const key of ['dark','light'])body.append(choice(key,()=>{state.theme=key;render();},state.theme===key));
      else if(modal.type==='bindings')bindingDialog(body);
      else if(modal.type==='diagnostics'){
        body.append(p('diagnosticsHelp'));for(const [key,value]of [['connection',t(state.connected?'connected':'beforeConnection')],['hands',state.tracking&&state.mode!=='gamepad'?'2 / 2':'0 / 2'],['trackingSamples','—'],['encodeFPS','—'],['decodeFPS','—'],['presented',t(state.tracking?'ready':'notReady')],['bandwidth','—']]){const r=n('div','vr-summary');r.append(n('span','',t(key)),n('strong','',value));body.append(r);}body.append(p('fpsHelp'));
      }else if(modal.type==='confirm'){
        const action=modal.value;body.append(p(action+'Help'),row(button('cancel',close),button('confirm',()=>{modal=null;set(action==='endSession'?'stop':action);},'primary')));
      }
      host.append(dialog);dialog.addEventListener('cancel',event=>{event.preventDefault();close();});dialog.showModal();
    };
    const render=(resetScroll=false)=>{
      if(!host)return;
      const oldFocus=document.activeElement?.dataset?.vrAction;scroll=resetScroll?0:host.querySelector('.vr-scroll')?.scrollTop||scroll;
      host.replaceChildren();host.className='sim-window v2-shell v2-vr'+(state.theme==='light'?' vr-light':'');
      const tour=n('div','vr-tour'),tourCopy=n('div');tourCopy.append(n('strong','',t('webDemo')),n('p','',t('demoNotice')));tour.append(tourCopy);
      if(state.listening&&!state.connected)tour.append(button('simulateConnect',()=>set('connect'),'primary'));
      else if(state.connected&&!state.tracking)tour.append(button('simulateTracking',()=>set('track'),'primary'));
      else if(state.tracking&&state.steam&&!state.game)tour.append(button('sampleGame',()=>set('game'),'primary'));
      else tour.append(linkText('restart',()=>{state=initial();modal=null;render(true);}));host.append(tour);
      const chrome=n('div','vr-chrome'),lights=n('div','v2-window-lights');for(const color of ['red','yellow','green']){const dot=n('span','v2-window-light '+color);dot.setAttribute('aria-hidden','true');lights.append(dot);}chrome.append(lights,button('launcher',exit,'vr-text','launcher'),n('span','','ForgePlay VR'),button('appearance',()=>open('appearance'),'vr-icon','palette'));host.append(chrome);
      const layout=n('div','vr-layout'),sidebar=n('aside','vr-sidebar'),brand=n('div','vr-brand');brand.append(icon('visionFill',34),n('strong','','FORGEPLAY\nVR'));sidebar.append(brand);
      const nav=n('nav');nav.setAttribute('aria-label',t('navigation'));
      for(const [id,key,glyph,native]of [['play','play','layers','square.stack.3d.up'],['devices','devices','vision','vision.pro'],['guide','guide','book','book.closed']]){const b=button(key,()=>go(id),'vr-nav',glyph);b.dataset.vrNav=id;b.dataset.nativeSymbol=native;b.setAttribute('aria-current',String(state.page===id));nav.append(b);}sidebar.append(nav);
      const identity=n('div','vr-sidebar-card');identity.append(icon('vision',30),n('strong','','Designed for\nApple Vision Pro'),p('sidebar'));sidebar.append(identity,n('small','vr-preview','PREVIEW / 0.1'),p('development'));layout.append(sidebar);
      const main=n('div','vr-main'),body=n('div','vr-scroll');body.tabIndex=-1;body.dataset.vrPage=state.page;const head=n('header','vr-page-head'),title=n('div');title.append(n('h2','',t(state.page)),p(state.page+'Lead'));head.append(title,pill(t(state.connected?'connected':'beforeConnection'),state.connected));body.append(head);
      if(state.error){const error=n('aside','vr-error');error.append(icon('warning'),p('busyError'),button('troubleshoot',()=>go('guide','connection')));body.append(error);}
      ({play,devices,guide})[state.page](body);main.append(body);
      const footer=n('footer','vr-session'),statusCopy=n('div');statusCopy.setAttribute('role','status');statusCopy.append(n('strong','',status()),n('small','',t('simulatedStatus')));footer.append(n('span','vr-dot'+(state.tracking?' is-ready':'')),statusCopy,button('diagnostics',()=>open('diagnostics'),'vr-icon','diagnostics'));
      if(state.environment){const stop=button('forceStop',()=>open('confirm','forceStop'),'vr-text');footer.append(stop);}
      const end=button('endSession',()=>state.steam?open('confirm','endSession'):set('stop'),'','power');end.disabled=!state.listening&&!state.steam;footer.append(end);main.append(footer);layout.append(main);host.append(layout);body.scrollTop=scroll;renderModal();
      if(!modal){const key=modalReturn||oldFocus;const target=[...host.querySelectorAll('button')].find(e=>e.dataset.vrAction===key);if(target&&!target.disabled)target.focus({preventScroll:true});modalReturn=null;}
    };
    return {render:element=>{host=element;render();},reset:()=>{state=initial();modal=null;scroll=0;},hint:()=>t('coach')};
  };
  window.ForgePlayVRDemo=Object.freeze({create,initial,transition,locked,bitrate});
})();

(() => {
  'use strict';
  // UI-only port of the Mac and Vision companion views. No device API or persistence.
  const demoCode='DEMO1234DEMO5678DEMO9012DEMO3456';
  const validCode=value=>String(value).replace(/[\s-]/g,'').toUpperCase()===demoCode;
  const initial = () => ({page:'play',environment:null,listening:false,connected:false,tracking:false,
    steam:false,remembered:false,mode:'combined',controller:'mac',quality:1600,showCode:false,
    theme:'dark',visionTheme:'dark',device:'mac',macPrepared:false,visionPrepared:false,
    selectedMac:false,pairCode:'',immersive:false,home:false,hasPlayed:false,
    pinch:true,showHands:true,microphone:false,foveation:false,autoPlay:false,rate:0,
    topic:'start',error:false,game:false,bindings:{}});
  const locked = state => state.connected || state.steam;
  const transition = (state, action, value) => {
    const next = {...state};
    if(action==='acknowledge') next[state.device==='mac'?'macPrepared':'visionPrepared']=true;
    if(action==='device' && ['mac','vision'].includes(value)) next.device=value;
    if(action==='environment' && state.macPrepared && !state.steam && ['shared','own',null].includes(value)) next.environment=value;
    if(action==='mode' && !locked(state) && ['hands','gamepad','combined'].includes(value)) next.mode=value;
    if(action==='controller' && !locked(state) && ['mac','vision'].includes(value)) next.controller=value;
    if(action==='quality' && !locked(state) && [1280,1600,1920].includes(value)) next.quality=value;
    if(action==='rate' && !locked(state) && [0,30,45,60].includes(value)) next.rate=value;
    if(action==='prepare' && state.macPrepared && state.environment && !state.listening) next.listening=true;
    if(action==='selectMac' && state.visionPrepared && state.listening) next.selectedMac=true;
    if(action==='connect' && state.visionPrepared && state.listening && state.selectedMac && validCode(state.pairCode)) {next.connected=true;next.remembered=true;}
    if(['device','acknowledge','reopenVision','prepare'].includes(action) && next.device==='vision' && next.visionPrepared && next.listening && next.remembered) next.connected=true;
    if(action==='reopenVision') next.home=false;
    if((action==='play' || (!state.connected && next.connected && next.autoPlay)) && next.connected && next.visionPrepared) {next.tracking=true;next.immersive=true;next.home=false;next.hasPlayed=true;if(next.environment) next.steam=true;}
    if(action==='home') {next.immersive=false;next.tracking=false;next.home=true;}
    if(action==='disconnectVision') {next.connected=false;next.immersive=false;next.tracking=false;next.home=false;}
    if(action==='pinch' && state.mode!=='gamepad') next.pinch=!state.pinch;
    if(['showHands','microphone','autoPlay'].includes(action)) next[action]=!state[action];
    if(action==='foveation' && !state.immersive) next.foveation=!state.foveation;
    if(action==='steam' && state.environment) next.steam=true;
    if(action==='game' && state.steam && state.tracking) next.game=true;
    if(action==='forceStop') {next.steam=false;next.game=false;}
    if(action==='stop') {next.listening=false;next.connected=false;next.tracking=false;next.steam=false;next.game=false;next.showCode=false;next.immersive=false;next.home=false;next.selectedMac=false;next.pairCode='';}
    if(action==='resetPairing') {next.connected=false;next.tracking=false;next.remembered=false;next.showCode=false;next.immersive=false;next.home=false;next.selectedMac=false;next.pairCode='';}
    return next;
  };
  const bitrate = quality => Math.min(100,Math.max(25,Math.round(60*(quality/1600)**2/5)*5));
  const create = ({copy,locale,exit,apps=()=>[]}) => {
    let state=initial(),host,modal=null,modalReturn=null,scroll=0,fieldFocus=null;
    let expanded={mac:new Set(),vision:new Set()};
    const t=(key,values={})=>Object.entries(values).reduce((text,[key,value])=>text.replaceAll('{'+key+'}',String(value)),copy.strings[key][Math.max(0,copy.locales.indexOf(locale()))]);
    const n=(tag,cls='',text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const icon=(name,size=18)=>window.ForgePlayGuideIcons.icon(name,size);
    const button=(key,action,style='',glyph)=>{const b=n('button','vr-button '+style);b.type='button';b.dataset.vrAction=key;if(glyph)b.append(icon(glyph));b.append(n('span','',t(key)));b.addEventListener('click',action);return b;};
    const p=(key,values)=>n('p','vr-muted',t(key,values));
    const row=(...children)=>{const e=n('div','vr-actions');e.append(...children);return e;};
    const help=(key)=>{const b=button('help',()=>open('help',key),'vr-icon','info');b.setAttribute('aria-label',t('help')+' · '+t(key));return b;};
    const panel=(title,subtitle,glyph)=>{const e=n('section','vr-panel'),h=n('div','vr-panel-heading');h.append(icon(glyph,21),n('h3','',t(title)));if(subtitle)h.append(help(subtitle));e.append(h);return e;};
    const pill=(text,good=false)=>{const e=n('span','vr-pill'+(good?' is-ready':''));e.append(icon(good?'checkCircle':'vision',14),n('span','',text));return e;};
    const set=(action,value)=>{state=transition(state,action,value);render(['device','acknowledge','connect','play','home','reopenVision','disconnectVision','stop','resetPairing'].includes(action));};
    const go=(page,topic)=>{state.page=page;if(topic)state.topic=topic;scroll=0;render(true);};
    const open=(type,value)=>{modal={type,value};modalReturn=document.activeElement?.dataset?.vrAction;render();};
    const close=()=>{modal=null;render();};
    const linkText=(key,action)=>button(key,action,'vr-text');
    const choice=(key,action,selected,disabled=false,glyph,detail)=>{const b=button(key,action,'vr-choice',glyph);b.setAttribute('aria-pressed',String(selected));b.disabled=disabled;if(detail)b.append(n('small','',t(detail)));b.append(icon(selected?'checkCircleFill':'circle',17));return b;};
    const toggle=(key,value,action,detail,disabled=false)=>{const wrap=n('div','vr-toggle-row'),b=button(key,action,'vr-toggle');b.setAttribute('role','switch');b.setAttribute('aria-checked',String(value));b.disabled=disabled;wrap.append(b);if(detail)wrap.append(p(detail));return wrap;};
    const disclosure=(key,child)=>{const d=n('details','vr-disclosure');d.dataset.vrDisclosure=key;d.open=expanded[state.device].has(key);d.append(n('summary','',t(key)),child);return d;};
    const isLight=()=> (state.device==='vision'?state.visionTheme:state.theme)==='light';
    const status=()=>t(state.tracking?'trackingReady':state.listening?'waitingConnection':state.steam?'steamRunning':'beforeSession');
    let visorSequence=0;
    const visor=()=>{
      // First-party geometry from VRInterface/ForgePlayVisor.swift and ForgePlayMark.swift.
      const svg=(tag,attrs={})=>{const e=document.createElementNS('http://www.w3.org/2000/svg',tag);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,v);return e;};
      const id='vr-visor-'+(++visorSequence),root=svg('svg',{viewBox:'0 0 1000 500',class:'vr-brand-visor','aria-hidden':'true'}),defs=svg('defs');
      const gradient=(name,colors)=>{const g=svg('linearGradient',{id:id+name,x1:'0',y1:'0',x2:'1',y2:'1'});colors.forEach((color,i)=>g.append(svg('stop',{offset:(i/(colors.length-1)*100)+'%','stop-color':color})));defs.append(g);};
      gradient('rim',isLight()?['#f4d1a7','#aa5c28','#d9985d']:['#f4caa0','#b87b42','#eba968']);gradient('glass',isLight()?['#77523a','#332015','#20160e']:['#6b4730','#21150f','#130e0a']);gradient('mark',['#fff1cf','#ffd09a','#eea35e']);root.append(defs);
      const outline='M110 80 C180 20 360 25 500 65 C640 25 820 20 890 80 C1015 160 950 410 830 435 C690 485 590 330 500 330 C410 330 310 485 170 435 C50 410 -15 160 110 80 Z';
      root.append(svg('path',{d:outline,fill:'url(#'+id+'rim)',stroke:isLight()?'#af6c37':'#f8d9b2','stroke-width':'2'}),svg('path',{d:outline,transform:'translate(500 248) scale(.943 .88) translate(-500 -248)',fill:'url(#'+id+'glass)',stroke:'#1b0f09','stroke-width':'4'}));
      const mark=svg('svg',{x:370,y:78,width:260,height:260,viewBox:'0 0 1254 1254',fill:'url(#'+id+'mark)'});
      for(const points of ['203,450 508,226 568,226 662,152 662,450','662,227 889,84 758,231 987,276 776,321 872,378 1086,423 1129,450 662,450','110,515 195,515 239,591 261,591 244,520 619,520 619,619 375,619 446,723 553,723 553,827 444,827 444,942 315,1077 315,824 365,773 262,631 190,631','619,520 1152,520 977,805 954,824 934,830 797,830 797,723 878,723 967,619 730,619 730,1070 668,1137 619,1080'])mark.append(svg('polygon',{points}));root.append(mark,svg('path',{d:'M90 134 C155 67 330 73 440 113 C295 96 155 156 110 230 Z',fill:'#fff4e5',opacity:'.12'}));return root;
    };
    const portal=()=>{const art=n('div','vr-portal');art.setAttribute('aria-hidden','true');art.append(n('i','vr-floor'),n('i','vr-orbit one'),n('i','vr-orbit two'),n('i','vr-orbit three'),visor(),n('i','vr-star'));return art;};
    const headingKey=()=>!state.environment?'heroSteam':!state.listening?'heroConnect':!state.connected?(state.remembered?'heroRemembered':'heroPair'):!state.tracking?'heroTracking':!state.steam?'heroReady':'heroPlay';
    const nextKey=()=>!state.environment?'connectSteam':!state.steam?'launchSteam':'reopenSteam';
    const next=()=>{if(!state.environment)open('environment');else if(!state.steam)set('steam');else open('help','steamHelp');};
    const environmentSheet=body=>{
      body.append(p('environmentHelp'),p('examplePaths'));
      const pick=n('div','vr-environment-choice');pick.append(icon('display',24),n('strong','','ForgePlay Steam'),n('code','','…/ForgePlay/Prefixes/SteamShared'),icon('checkCircleFill',20));body.append(pick,p('closeDesktop'));
      body.append(row(button('folder',()=>open('folder'),'','folder'),button('cancel',close),button('useSteam',()=>{modal=null;set('environment','shared');},'primary')));
    };
    const connection=()=>{
      const box=panel('visionConnection','connectionHelp','vision');
      const device=n('div','vr-device');device.append(icon('display',28),n('strong','',t('exampleMac')),pill(t(state.connected?'connected':state.listening?'waitingVision':'beforeConnection'),state.connected));box.append(device);
      if(!state.listening){const prepare=button('prepare',()=>set('prepare'),'primary','wifi');prepare.disabled=!state.environment;box.append(p('connectionHelp'),prepare);if(!state.environment)box.append(p('chooseEnvironment'));}
      else if(state.connected){box.append(pill(t(state.tracking?'trackingReady':'connectedPreparing'),state.tracking),p(state.tracking?'steamHelp':'trackingInstructions'),p('audioHelp'));}
      else if(state.remembered){box.append(pill(t('rememberedDevice'),true),p('rememberedHelp'));}
      else{
        box.append(p('codeInstructions'));const code=n('div','vr-code'),head=row(n('small','',t('code')),button(state.showCode?'hideCode':'showCode',()=>{state.showCode=!state.showCode;render();},'vr-icon','eye'));
        code.append(head,n('code','',state.showCode?'DEMO 1234 DEMO 5678\nDEMO 9012 DEMO 3456':'•••• •••• •••• ••••\n•••• •••• •••• ••••'),linkText('copyCode',()=>open('help','codeExample')));box.append(code,p('codeExample'));
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
      const main=button(nextKey(),next,'primary','play'),buttons=row(main);
      if(state.environment)buttons.append(button(state.listening?'inputSettings':'prepareVision',()=>state.listening?go('devices'):set('prepare')));copy.append(buttons);
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
      if(state.mode!=='gamepad')input.append(n('strong','',t('handAim')),toggle('pinch',state.pinch,()=>set('pinch'),'handAimHelp'));
      if(state.mode!=='hands'){input.append(p('controllerLocation'));const segments=row();for(const id of ['mac','vision'])segments.append(choice(id,()=>set('controller',id),state.controller===id,locked(state)));input.append(segments,p('controllerSupport'));if(state.controller==='vision')input.append(p('remoteControllerHelp'));}
      if(locked(state))input.append(p('optionsLocked'));top.append(connection(),input);body.append(top);
      const quality=panel('quality','qualityHelp','display'),choices=n('div','vr-quality');
      for(const [value,key]of [[1280,'responsive'],[1600,'balanced'],[1920,'clear']])choices.append(choice(key,()=>set('quality',value),state.quality===value,locked(state),null,key+'Detail'));
      quality.append(choices,p('qualityValue',{size:state.quality,rate:state.rate||bitrate(state.quality)}),p('qualityHelp'));
      const rate=select(quality,'rate',[[0,t('rateAutomatic')],[30,'30 Mbps'],[45,'45 Mbps'],[60,'60 Mbps']],String(state.rate),v=>set('rate',Number(v)));rate.disabled=locked(state);quality.append(p('rateHelp'));body.append(quality);
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
      for(const [id,text]of values){const option=n('option','',text);option.value=id;option.selected=String(id)===String(value);control.append(option);}control.addEventListener('change',()=>changed(control.value));label.append(n('span','',t(key)),control);body.append(label);return control;
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
    const preparation=(body,first=false)=>{
      body.append(n('h2','',t('prepTitle')),n('strong','vr-prep-required',t('macRequired')),p('companionHelp'));
      const steps=n('ol','vr-prep-steps');for(const key of ['prepDesktop','prepGame','prepShared','prepVision']){const [title,...detail]=t(key).split('\n'),step=n('li');step.append(n('strong','',title),n('p','vr-muted',detail.join('\n')));steps.append(step);}body.append(steps,p('preparationScope'));
      body.append(row(button('desktopGuide',()=>{modal=null;exit('desktop');},'','book'),button('otherApps',()=>open('apps'),'','grid')));
      if(first)body.append(button('continueSetup',()=>set('acknowledge'),'primary','arrow'));
    };
    const appsDialog=body=>{
      const platform=modal.value||'mac',tabs=row();for(const key of ['mac','ipad','iphone']){const b=n('button','vr-button',({mac:'Mac',ipad:'iPad',iphone:'iPhone'})[key]);b.type='button';b.setAttribute('aria-pressed',String(platform===key));b.addEventListener('click',()=>{modal.value=key;render();});tabs.append(b);}body.append(tabs);
      const items=apps().filter(a=>a.platform===platform&&a.id!=='forgeplay');
      if(!items.length)body.append(p('appsUnavailable'));
      for(const app of items){const card=n('article','vr-panel');card.append(n('h3','',app.name),n('p','vr-muted',app.summaries[locale()]||app.summaries.en));if(/^https:\/\/apps\.apple\.com\//.test(app.href||'')){const link=n('a','vr-button',t('appStore'));link.href=app.href;link.target='_blank';link.rel='noopener noreferrer';card.append(link);}body.append(card);}
    };
    const vision=body=>{
      const header=n('div','vr-vision-heading'),title=n('div');title.append(n('h2','',t(state.connected?(state.hasPlayed?'visionResume':'visionInput'):state.remembered?'visionRemembered':'visionChoose')),p(state.connected?'inputCheck':'visionChooseHelp'));header.append(title,portal());body.append(header);
      const requirement=panel('macRequired',null,'display');requirement.append(button('prepTitle',()=>open('preparation'),'vr-text'));body.append(requirement);
      if(state.connected){
        const input=panel('inputCheck',null,'hand');input.append(pill(t('exampleMac'),true),button(state.hasPlayed?'playResume':'playStart',()=>set('play'),'primary','vision'),p('playWindowHelp'));
        input.append(button('recenter',()=>open('help','recenterHelp')),n('strong','',t('handAim')),toggle('pinch',state.pinch,()=>set('pinch'),'handAimHelp',state.mode==='gamepad'),toggle('showHands',state.showHands,()=>set('showHands'),'showHandsHelp'),toggle('microphone',state.microphone,()=>set('microphone'),'microphoneHelp'),button('disconnectVision',()=>set('disconnectVision')));body.append(input);
      }else{
        const connect=panel('selectMac',null,'display');
        if(!state.listening){connect.append(p('noMacHelp'),button('macApp',()=>set('device','mac'),'','display'));}
        else if(state.remembered){connect.append(p('rememberedHelp'),button('reopenVision',()=>set('reopenVision'),'primary'));}
        else{
          connect.append(choice('exampleMac',()=>set('selectMac'),state.selectedMac));
          if(state.selectedMac){const label=n('label','vr-field'),input=n('input');input.type='password';input.maxLength=64;input.autocomplete='off';input.value=state.pairCode;input.setAttribute('aria-label',t('pairCode'));input.dataset.vrField='pairCode';label.append(n('span','',t('pairCode')),input);connect.append(label,p('codeExample'));
            const pair=button('rememberConnect',()=>set('connect'),'primary','link');pair.disabled=!validCode(state.pairCode);input.addEventListener('input',()=>{state.pairCode=input.value;pair.disabled=!validCode(state.pairCode);});
            connect.append(row(button('exampleCode',()=>{state.pairCode=demoCode;render();}),pair));
          }
        }body.append(connect);
      }
      const manage=n('div','vr-settings-body');select(manage,'appearance',[['light',t('light')],['dark',t('dark')]],state.visionTheme,v=>{state.visionTheme=v;render();});manage.append(toggle('autoPlay',state.autoPlay,()=>set('autoPlay'),'autoPlayHelp'),p('rememberedHelp'),button('resetPairing',()=>open('confirm','resetPairing')));body.append(disclosure('connectionManager',manage));
      const compare=n('div','vr-settings-body');compare.append(toggle('foveation',state.foveation,()=>set('foveation'),'foveationHelp'),p('diagnosticsHelp'));body.append(disclosure('videoCompare',compare),row(button('guide',()=>open('visionGuide'),'','book'),button('otherApps',()=>open('apps'),'','grid')),p('compatibilityNote'));
    };
    const renderModal=()=>{
      if(!modal)return;
      const dialog=n('dialog','vr-dialog'+(isLight()?' vr-light':''));dialog.setAttribute('aria-labelledby','vr-dialog-title');const header=n('div','vr-modal-head');
      const titles={environment:'connectSteam',folder:'folder',install:'installOwn',bindings:'editBindings',diagnostics:'diagnostics',appearance:'macSettings',help:'help',preparation:'prepTitle',apps:'otherApps',visionGuide:'guide',confirm:modal.value};
      const title=n('h2','',t(titles[modal.type]));title.id='vr-dialog-title';header.append(title,button('close',close,'vr-icon','close'));dialog.append(header);const body=n('div','vr-modal-body');dialog.append(body);
      if(modal.type==='environment')environmentSheet(body);
      else if(modal.type==='folder'){body.append(p('folderHelp'),p('examplePaths'),button('useExample',()=>{modal=null;set('environment','shared');},'primary'));}
      else if(modal.type==='install'){body.append(p('installHelp'),p('noInstallation'),button('useExample',()=>{modal=null;set('environment','own');},'primary'));}
      else if(modal.type==='help')body.append(p(modal.value));
      else if(modal.type==='appearance'){body.append(p('macSettingsHelp'));for(const key of ['dark','light'])body.append(choice(key,()=>{state.theme=key;render();},state.theme===key));}
      else if(modal.type==='preparation')preparation(body);
      else if(modal.type==='apps')appsDialog(body);
      else if(modal.type==='visionGuide')for(const topic of topics)body.append(disclosure('topic'+topic,p('guide'+topic)));
      else if(modal.type==='bindings')bindingDialog(body);
      else if(modal.type==='diagnostics'){
        body.append(p('diagnosticsHelp'));for(const [key,value]of [['connection',t(state.connected?'connected':'beforeConnection')],['hands',state.tracking&&state.mode!=='gamepad'?'2 / 2':'0 / 2'],['trackingSamples','—'],['encodeFPS','—'],['decodeFPS','—'],['presented',t(state.tracking?'ready':'notReady')],['bandwidth','—']]){const r=n('div','vr-summary');r.append(n('span','',t(key)),n('strong','',value));body.append(r);}body.append(p('fpsHelp'));
      }else if(modal.type==='confirm'){
        const action=modal.value;body.append(p(action+'Help'),row(button('cancel',close),button('confirm',()=>{modal=null;set(action==='endSession'?'stop':action);},'primary')));
      }
      host.append(dialog);dialog.addEventListener('cancel',event=>{event.preventDefault();close();});dialog.showModal();
    };
    const complete=(body,oldFocus)=>{
      body.scrollTop=scroll;renderModal();
      if(!modal){const key=modalReturn||oldFocus,target=fieldFocus?[...host.querySelectorAll('[data-vr-field]')].find(e=>e.dataset.vrField===fieldFocus):[...host.querySelectorAll('button')].find(e=>e.dataset.vrAction===key);if(target&&!target.disabled)target.focus({preventScroll:true});else if(key){body.tabIndex=-1;body.focus({preventScroll:true});}modalReturn=null;fieldFocus=null;}
    };
    const render=(resetScroll=false)=>{
      if(!host)return;
      const oldFocus=document.activeElement?.dataset?.vrAction;fieldFocus=document.activeElement?.dataset?.vrField;scroll=resetScroll?0:host.querySelector('.vr-scroll')?.scrollTop||scroll;
      if(host.dataset.vrDevice)expanded[host.dataset.vrDevice]=new Set([...host.querySelectorAll('details[data-vr-disclosure][open]')].map(e=>e.dataset.vrDisclosure));
      host.replaceChildren();host.className='sim-window v2-shell v2-vr'+(isLight()?' vr-light':'');host.dataset.vrDevice=state.device;
      const tour=n('div','vr-tour'),tourCopy=n('div');tourCopy.append(n('strong','',t('webDemo')),n('p','',t('demoNotice')));tour.append(tourCopy);
      tour.append(linkText('restart',()=>{state=initial();modal=null;expanded={mac:new Set(),vision:new Set()};delete host.dataset.vrDevice;render(true);}));host.append(tour);
      const switcher=row();switcher.classList.add('vr-device-switch');switcher.setAttribute('aria-label',t('deviceSwitch'));for(const [id,key,glyph] of [['mac','macApp','display'],['vision','visionApp','vision']]){const b=button(key,()=>set('device',id),'',glyph);b.setAttribute('aria-pressed',String(state.device===id));switcher.append(b);}host.append(switcher);
      const prepared=state.device==='mac'?state.macPrepared:state.visionPrepared;
      if(state.device==='vision'&&prepared&&(state.immersive||state.home)){
        const space=n('section','vr-immersive-space');space.append(visor(),n('h2','',t(state.home?'homeExample':'immersiveExample')),p(state.home?'homeHelp':'immersiveHelp'),button(state.home?'reopenVision':'goHome',()=>set(state.home?'reopenVision':'home'),'primary'),p('simulatedStatus'));host.append(space);complete(space,oldFocus);return;
      }
      if(state.device==='vision'){
        const window=n('section','vr-vision-window'),head=n('div','vr-vision-bar');head.append(visor(),n('strong','','ForgePlay VR'),button('help',()=>open('visionGuide'),'vr-icon','info'));window.append(head);
        const body=n('div','vr-scroll');body.tabIndex=-1;if(!prepared)preparation(body,true);else vision(body);window.append(body);host.append(window);complete(body,oldFocus);return;
      }
      const chrome=n('div','vr-chrome'),lights=n('div','v2-window-lights');for(const color of ['red','yellow','green']){const dot=n('span','v2-window-light '+color);dot.setAttribute('aria-hidden','true');lights.append(dot);}chrome.append(lights,button('launcher',exit,'vr-text','launcher'),n('span','','ForgePlay VR'),button('appearance',()=>open('appearance'),'vr-icon','palette'));host.append(chrome);
      if(!prepared){const body=n('div','vr-scroll vr-preparation');preparation(body,true);host.append(body);complete(body,oldFocus);return;}
      const layout=n('div','vr-layout'),sidebar=n('aside','vr-sidebar'),brand=n('div','vr-brand');brand.append(visor(),n('strong','','FORGEPLAY\nVR'));sidebar.append(brand);
      const nav=n('nav');nav.setAttribute('aria-label',t('navigation'));
      for(const [id,key,glyph,native]of [['play','play','layers','square.stack.3d.up'],['devices','devices','vision','vision.pro'],['guide','guide','book','book.closed']]){const b=button(key,()=>go(id),'vr-nav',glyph);b.dataset.vrNav=id;b.dataset.nativeSymbol=native;b.setAttribute('aria-current',String(state.page===id));nav.append(b);}sidebar.append(nav,linkText('prepTitle',()=>open('preparation')));
      const identity=n('div','vr-sidebar-card');identity.append(icon('vision',30),n('strong','','Designed for\nApple Vision Pro'),p('sidebar'));sidebar.append(identity,n('small','vr-preview','PREVIEW / 0.1'),p('development'));layout.append(sidebar);
      const main=n('div','vr-main'),body=n('div','vr-scroll');body.tabIndex=-1;body.dataset.vrPage=state.page;const head=n('header','vr-page-head'),title=n('div');title.append(n('h2','',t(state.page)),p(state.page+'Lead'));head.append(title,pill(t(state.connected?'connected':'beforeConnection'),state.connected));body.append(head);
      if(state.error){const error=n('aside','vr-error');error.append(icon('warning'),p('busyError'),button('troubleshoot',()=>go('guide','connection')));body.append(error);}
      if(state.steam)body.append(pill(t('steamRunning'),true));
      ({play,devices,guide})[state.page](body);if(state.tracking&&state.steam&&!state.game)body.append(button('sampleGame',()=>set('game')));main.append(body);
      const footer=n('footer','vr-session'),statusCopy=n('div');statusCopy.setAttribute('role','status');statusCopy.append(n('strong','',status()),n('small','',t('simulatedStatus')));footer.append(n('span','vr-dot'+(state.tracking?' is-ready':'')),statusCopy,button('diagnostics',()=>open('diagnostics'),'vr-icon','diagnostics'));
      if(state.environment){const stop=button('forceStop',()=>open('confirm','forceStop'),'vr-text');footer.append(stop);}
      const end=button('endSession',()=>state.steam?open('confirm','endSession'):set('stop'),'','power');end.disabled=!state.listening&&!state.steam;footer.append(end);main.append(footer);layout.append(main);host.append(layout);complete(body,oldFocus);
    };
    return {render:element=>{host=element;render();},reset:()=>{state=initial();modal=null;scroll=0;expanded={mac:new Set(),vision:new Set()};if(host)delete host.dataset.vrDevice;},hint:()=>t('coach')};
  };
  window.ForgePlayVRDemo=Object.freeze({create,initial,transition,locked,bitrate,validCode,demoCode});
})();

(() => {
  "use strict";
  const root = document.querySelector("[data-guide-v2]");
  if (!root) return;
  const locales = ["ko", "en", "de", "es", "fr", "ja", "zh-Hans", "zh-Hant"];
  const locale = () => locales.includes(document.documentElement.lang) ? document.documentElement.lang : "en";
  const fetchJSON = async path => { const response = await fetch(path, {cache:"no-store", credentials:"omit", signal:AbortSignal.timeout(15000)}); if (!response.ok) {const error=new Error(path);error.status=response.status;throw error;} return response.json(); };
  const node = (tag, cls = "", text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text !== undefined) n.textContent = text; return n; };
  const symbol=(name,size=18)=>window.ForgePlayGuideIcons.icon(name,size);
  const viewGlyphs={steam:'playCircle',profiles:'controllerFill',battlenet:'controller',epic:'controller',stove:'controller',exe:'terminalFill',dashboard:'grid',why:'bookFill',setup:'checklist',catalog:'list',diagnostics:'diagnostics',apps:'launcher'};
  const nativeSymbols={steam:'play.circle.fill',profiles:'gamecontroller.fill',battlenet:'gamecontroller',epic:'gamecontroller',stove:'gamecontroller',exe:'terminal.fill',dashboard:'square.grid.2x2',why:'book.closed.fill',setup:'checklist'};
  const actionGlyph=text=>{if(!ui)return null;const pairs=[["Steam 실행","play"],["프로그램 실행","play"],["설정 저장","download"],["저장공간 관리","drive"],["Wine 강제 종료","stop"],["EXE 파일 선택","folder"],["사용법","help"],["루트 선택","folder"],["프로필 권장값 복원","refresh"],["키보드 설정하기","keyboard"],["컨트롤러 확인","controller"],["외장 드라이브/폴더 연결","folderPlus"],["Steam 참고 목록 새로고침","refresh"],["스냅샷 목록 확인","refresh"],["선택한 백업 삭제","trash"],["지원 번들 생성","download"],["최근 로그 다시 분석","refresh"],["AI 로컬 분석 전 미리보기","eye"],["연결 해제","close"],["Rosetta 설치","download"],["Steam 프리픽스 재생성","refresh"],["AWDL 상태 새로고침","refresh"]];return pairs.find(([label])=>U(label)===text)?.[1]||null;};
  const btn = (text, action, cls = "", glyph) => {const b=node("button",cls);b.type="button";const name=glyph===false?null:glyph||actionGlyph(text);if(name)b.append(symbol(name));if(text)b.append(node('span','v2-button-label',text));b.addEventListener("click",action);return b;};
  const external = (text, href) => { const a = node("a", "sim-link", text); a.href = href; a.target = "_blank"; a.rel = "noopener noreferrer"; return a; };
  let map, ui, copy, demos, launcherCopy, desktopCopy, coordinatorNotice, coordinatorDefaults, catalog, appCatalog, notices, shell, dialog, coach, focusBeforeDialog, vrDemo;
  let supporters=[], remoteBanners=new Map(), catalogLoading=false, catalogFailed=false;
  const artworkRoot='site-assets/guide/launcher-current/';
  let surface = "launcher", view = "steam", workspace = "launch", preference = "general", lesson = "free";
  let utilityReturn={surface:'launcher',view:'steam',workspace:'launch'};
  let expandedWindow=false;
  const inertBackground=new Map();
  const applyWindowSize=()=>{root.classList.toggle('v2-immersive',expandedWindow);const control=root.querySelector('[data-v2-expand]');if(control){control.replaceChildren(symbol('window'),node('span','',C(expandedWindow?'windowRestore':'windowExpand')));control.setAttribute('aria-pressed',String(expandedWindow));}
    if(expandedWindow){root.setAttribute('role','dialog');root.setAttribute('aria-modal','true');let branch=root;while(branch.parentElement){for(const sibling of branch.parentElement.children){if(sibling===branch||inertBackground.has(sibling))continue;inertBackground.set(sibling,sibling.inert);sibling.inert=true;}branch=branch.parentElement;if(branch===document.body)break;}}
    else{root.setAttribute('role','region');root.removeAttribute('aria-modal');for(const[element,previous]of inertBackground)element.inert=previous;inertBackground.clear();}
  };
  const freshConfig = () => ({renderer:"D3DMetal - NVIDIA", neural:false, coordinator:false, highlights:true, assistantText:true, assistantVoice:true, voiceStyle:"F1", pitch:3.5, rate:1, method:"HyPER-GAN", resolution:"native", style:"Cityscapes", passes:1, strength:100, fg:false, interpolation:"Simple", frameCheck:true, gameMode:true, network:"standard", microphone:false, vram:"auto", heap:true, retina:false});
  const fresh = () => ({configs:{}, saved:{}, ready:true, setup:9, launched:{}, installed:{steam:true}, file:null, installer:false, library:null, profileRoot:false, profileSaved:false, theme:"system", pointer:false, mapping:false, command:"Ctrl", option:"Alt", control:"Ctrl", quitKeys:false, switchKeys:false, spaces:false, screenshots:false, awdl:true, retained:30, logLimit:30, autoCleanup:true, aiEnabled:false, appPlatform:'mac', chat:[], snapshots:[{id:"Recovery-example",protected:false},{id:"Manual-backup-example",protected:true}], snapshotLoaded:false, checkedController:false, expanded:{}, tickerPaused:false});
  const newState = () => Object.assign(fresh(),{retina:false,savedRetina:false,profile:"helldivers2",poppleTips:true,advanced:false,coordinatorPrefs:{accepted:false,details:false,mode:"pushToTalk",shortcut:"Fn",position:"frame-check",bubbleColor:"navy",boxColor:"cyan",bubbleWidth:300,bubbleFont:13,maxBox:10,targets:"",instructions:""}});
  let state = newState();
  const configKey = () => view==='profiles' ? 'profiles-'+state.profile : view;
  const config = () => state.configs[configKey()] ||= freshConfig();
  const retinaEnabled = () => view==='profiles' ? config().retina : state.retina;
  const saveConfig = () => {state.saved[configKey()]=JSON.stringify(config());if(view!=='profiles')state.savedRetina=state.retina;render();};
  const configSaved = () => state.saved[configKey()]===JSON.stringify(config())&&(view==='profiles'||state.savedRetina===state.retina);
  const U = (key, value) => (ui[locale()]?.[key] ?? ui.en?.[key] ?? key).replace("%@", value ?? "%@");
  const C = key => (copy[locale()]?.[key] ?? copy.en[key] ?? key)
    .replaceAll('{version}',map.version).replaceAll('{build}',String(map.build));
  const guideVersion = () => `${map.version} (${map.build})`;
  const L = key => launcherCopy.strings[key][launcherCopy.locales.indexOf(locale())];
  const M = key => desktopCopy.strings[key][desktopCopy.locales.indexOf(locale())];
  const D = key => demos[locale()]?.[key] ?? demos.en[key] ?? key;
  const W = key => window.ForgePlaySite?.message(key) || key;
  const viewName = id => id==='setup'?M('setup'):map.views[id]?.name ? U(map.views[id].title,map.views[id].name) : U(map.views[id]?.title || id);
  const platform = () => map.views[view]?.name || (["steam","profiles"].includes(view) ? "Steam" : C("program"));
  const note = (parent,text,important=false) => parent.append(node("p",important?"sim-note sim-important":"sim-note",String(text).replaceAll('\\n','\n')));
  const actions = (...buttons) => { const row=node("div","sim-actions"); row.append(...buttons); return row; };
  const card = (title,help,glyph) => {const c=node("section","sim-card");const h=node("div","v2-card-heading");h.append(symbol(glyph||viewGlyphs[view]||'sliders'),node("h3","",title));if(help)h.append(info(title,help));c.append(h);return c;};
  const badge=(text,status='ok')=>{const b=node('span','v2-status-badge');b.dataset.status=status;b.append(symbol(status==='ok'?'checkCircle':status==='warning'?'warning':'circle',13),node('span','',text));return b;};
  const disclosure=(title,key,content)=>{const d=node('details','v2-disclosure');d.open=Boolean(state.expanded[key]);const summary=node('summary');summary.append(symbol('chevron',12),node('span','',title));d.append(summary,content);d.addEventListener('toggle',()=>{state.expanded[key]=d.open;});return d;};
  const helpText = id => (map.views[id]?.notes || []).map(key=>U(key)).join("\n\n");
  const show = (title,text,choices=[]) => {
    if(!dialog.open)focusBeforeDialog=document.activeElement;
    preferencesOpen=false;delete dialog.dataset.kind;dialog.classList.remove("v2-preferences","v2-founder-dialog");dialog.classList.toggle('sim-light',isLight());dialog.classList.toggle('v2-launcher-dialog',surface==='launcher');dialog.replaceChildren(); const head=node("div","sim-dialog-head"); const heading=node("h2","",title); heading.id="v2-dialog-title";
    head.append(heading,btn(D("close"),()=>dialog.close())); dialog.append(head,node("p","",text));
    if(choices.length) dialog.append(actions(...choices.map(([label,action])=>btn(label,()=>{dialog.close();action();}))));
    if(!dialog.open)dialog.showModal();
  };
  const info = (title,text) => {
    const b=btn("",()=>{
      const popup=node('div','v2-info-popover'+(isLight()?' v2-light-popover':''));if(!popup.showPopover){show(title,text);return;}
      root.querySelectorAll('.v2-info-popover').forEach(p=>p.hidePopover());popup.setAttribute('popover','auto');popup.setAttribute('role','dialog');popup.setAttribute('aria-labelledby','v2-information-title');
      const header=node('div','v2-popover-head'),heading=node('h3','',title);heading.id='v2-information-title';const close=btn('',()=>popup.hidePopover(),'v2-icon-button','close');close.setAttribute('aria-label',D('close'));
      header.append(heading,close);popup.append(header,node('p','',text));(preferencesOpen?dialog:root).append(popup);
      const rect=b.getBoundingClientRect(),width=Math.min(370,innerWidth-32);popup.style.width=width+'px';popup.style.maxHeight=Math.min(520,innerHeight-32)+'px';popup.style.left=Math.max(16,Math.min(rect.left-18,innerWidth-width-16))+'px';
      popup.addEventListener('toggle',event=>{if(event.newState==='closed'){popup.remove();if(b.isConnected)b.focus({preventScroll:true});}});popup.showPopover();const height=popup.getBoundingClientRect().height;const preferred=rect.bottom+height+10<innerHeight-16?rect.bottom+10:rect.top-height-10;popup.style.top=Math.max(16,Math.min(preferred,innerHeight-height-16))+'px';
    },"v2-info",'info');b.setAttribute("aria-label",`${title} · ${C("help")}`);return b;
  };
  const go = id => {if(['catalog','diagnostics','apps'].includes(id)){if(surface!=='utility')utilityReturn={surface,view,workspace};surface='utility';}else surface='mac';view=id;workspace='launch';render(true);if(id==='catalog')void refreshCatalog();if(expandedWindow)root.scrollTop=0;shell.querySelector('.sim-content')?.focus({preventScroll:true});};
  const closeUtility=()=>{({surface,view,workspace}=utilityReturn);render(true);};
  const windowLights=(close)=>{const lights=node('div','v2-window-lights');for(const[k,color]of ['red','yellow','green'].entries()){if(k===0&&close){const b=btn('',close,'v2-window-light '+color,'close');b.setAttribute('aria-label',D('close'));lights.append(b);}else{const dot=node('span','v2-window-light '+color);dot.setAttribute('aria-hidden','true');lights.append(dot);}}return lights;};
  const toggle = (parent,label,obj,key,help,changed) => {
    const row=node("div","sim-toggle-row"), id=`v2-${surface}-${view}-${key}`; const text=node("span","",label); text.id=id+"-label";
    const b=btn("",()=>{obj[key]=!obj[key];if(changed)changed(obj[key]);render();},"sim-switch");b.id=id;b.setAttribute("role","switch");b.setAttribute("aria-checked",String(obj[key]));b.setAttribute("aria-labelledby",text.id);b.append(node("span"));
    const caption=node("div","v2-control-label");const glyph={pointer:'pointer',mapping:'keyboard',quitKeys:'lock',switchKeys:'key',spaces:'grid',screenshots:'display',awdl:'wifi'}[key];if(glyph)caption.append(symbol(glyph));caption.append(text);if(help)caption.append(info(label,help));row.dataset.option=key;row.append(caption,b);parent.append(row);
  };
  const select = (parent,label,obj,key,values,change,help) => {
    const row=node("div","sim-field"),s=node("select"),caption=node('div','v2-control-label');s.id=`v2-${view}-${key}`;s.setAttribute("aria-label",label);const text=node('label','',label);text.htmlFor=s.id;const glyph={network:'network',microphone:'mic',vram:'memory',command:'keyboard',option:'keyboard',control:'keyboard',retained:'logs'}[key];if(glyph)caption.append(symbol(glyph));caption.append(text);if(help)caption.append(info(label,help));
    for(const[value,title,disabled]of values){const o=node("option","",title);o.value=value;o.selected=String(obj[key])===String(value);o.disabled=Boolean(disabled);s.append(o);}
    s.addEventListener("change",()=>{obj[key]=typeof obj[key]==="number"?Number(s.value):typeof obj[key]==='boolean'?s.value==='true':s.value;if(change)change();render();});row.dataset.option=key;row.append(caption,s);parent.append(row);
  };
  const explain = id => show(viewName(id),helpText(id));
  const setWorkspace = id => {workspace=id;render(true);};
  const renderers = parent => {
    const c=config(), group=node("div","sim-renderers");
    for(const [name,api] of [["D3DMetal - NVIDIA","DirectX 11/12 · 64-bit"],["DXMT","DirectX 10/11"],["DXVK","DirectX 10/11"],["WineD3D","Direct3D 9 · 32-bit · OpenGL"]]){
      const b=btn("",()=>{c.renderer=name;if(name==='WineD3D')c.coordinator=false;render();},c.renderer===name?"sim-selected":"");b.id="v2-renderer-"+name.replaceAll(" ","");b.setAttribute("aria-pressed",String(c.renderer===name));const caption=node('span');caption.append(node("strong","",name),node("small","",api));b.append(symbol(c.renderer===name?'checkCircleFill':'circle',18),caption);
      if(name==="DXVK")b.title=M('dxvk');group.append(b);
    }
    const heading=node('div','v2-form-heading');heading.append(node('strong','',U(view==='steam'?"다음 Steam 실행 설정":"렌더러")),info(U("렌더러"),C('backendIntro')+'\n\n'+M('dxvk')));parent.append(heading,group);
  };
  const coordinatorSlider = (parent,label,obj,key,min,max,step,suffix='') => {
    const row=node('label','sim-field v2-coordinator-slider'),input=node('input'),value=node('output');input.type='range';input.id='v2-coordinator-'+key;input.min=min;input.max=max;input.step=step;input.value=obj[key];input.setAttribute('aria-label',label);value.htmlFor=input.id;
    const display=()=>{value.textContent=String(Math.round(Number(input.value)*100)/100)+suffix;};display();
    input.addEventListener('input',()=>{obj[key]=Number(input.value);display();});input.addEventListener('change',render);row.append(node('span','',label),input,value);parent.append(row);
  };
  const coordinatorColors = (parent,label,prefs,key,colors) => {
    const group=node('div','v2-coordinator-colors');group.setAttribute('role','group');group.setAttribute('aria-label',label);
    for(const[value,title,color]of colors){const b=btn(U(title),()=>{prefs[key]=value;render();},'v2-color-choice',false);b.style.setProperty('--swatch',color);b.setAttribute('aria-pressed',String(prefs[key]===value));group.append(b);}parent.append(node('strong','',label),group);
  };
  const coordinatorEditor = targets => {
    const p=state.coordinatorPrefs,key=targets?'targets':'instructions',title=U(targets?'검출 대상 설정':'게임 안내 지시문');
    const defaultValue=()=>targets?coordinatorDefaults.targets.join(', '):coordinatorDefaults.instructions[locale()==='ko'?'ko':'en'];
    show(title,M(targets?'targetHelp':'instructionHelp'));
    const input=node('textarea','v2-coordinator-editor'),status=node('p','sim-note');input.rows=targets?3:10;input.maxLength=targets?2048:1500;input.value=p[key]||defaultValue();input.setAttribute('aria-label',title);
    const apply=btn(U('적용'),()=>{p[key]=input.value.trim()===defaultValue()?'':input.value.trim();dialog.close();render();},'sim-primary','check');
    const check=()=>{const values=input.value.split(',').map(v=>v.trim()).filter(Boolean);apply.disabled=targets&&(values.length<1||values.length>5);status.textContent=targets?M('targetCount').replace('{count}',String(values.length)):`${[...input.value].length} / 1500`;};input.addEventListener('input',check);check();
    dialog.append(input,status,actions(btn(U(targets?'기본 검출 대상 복원':'기본 지시문 복원'),()=>{input.value=defaultValue();check();},'','refresh'),btn(U('취소'),()=>dialog.close()),apply));
  };
  const coordinatorNoticeView = (c,enablePending=false) => {
    show(U('AI Coordinator 사용 고지'),M('legalHelp')+'\n\n'+M('restrictionHelp'));
    const legal=node('section','v2-coordinator-notice');
    for(const[title,href]of [[M('noticeKorean'),'site-data/guide-notices/coordinator.ko.txt'],[M('noticeEnglish'),'site-data/guide-notices/coordinator.en.txt'],['GPL-3.0-only','LICENSES/GPL-3.0-only.txt'],['OWLv2 · Apache-2.0','site-data/guide-notices/owlv2-license.txt'],['Supertonic2 · OpenRAIL-M','site-data/guide-notices/supertonic2-license.txt']])legal.append(external(title,href));
    const list=node('details'),items=node('ul');list.append(node('summary','',M('restrictions')));for(const name of coordinatorNotice.restrictedGames)items.append(node('li','',name));list.append(items);legal.append(list);dialog.append(legal);
    if(enablePending){const label=node('label','v2-demo-consent'),check=node('input');check.type='checkbox';label.append(check,node('span','',M('demoConsent')));const enable=btn(M('demoEnable'),()=>{state.coordinatorPrefs.accepted=true;state.coordinatorPrefs.details=true;c.coordinator=true;dialog.close();render();},'sim-primary');enable.disabled=true;check.addEventListener('change',()=>{enable.disabled=!check.checked;});dialog.append(label,actions(btn(U('취소'),()=>dialog.close()),enable));}
  };
  const coordinatorDetails = (parent,c) => {
    const p=state.coordinatorPrefs;
    select(parent,U('안내 방식'),p,'mode',[['automatic',U('필요할 때 자동 안내')],['pushToTalk',U('자동 안내 + 단축키 질문')],['continuous',U('연속 대화')]],null,M('conversationHelp'));
    parent.append(btn(U('음성 질문 사용법'),()=>show(U('음성 질문 사용법'),M('conversationHelp')+'\n\n'+M('temporaryHelp')),'','help'));
    if(p.mode!=='automatic'){
      if(p.mode==='pushToTalk')select(parent,U('질문 단축키'),p,'shortcut',['Fn','F16','F17','F18'].map(n=>[n,n]),null,M('shortcutHelp'));
      note(parent,M('temporaryHelp'));parent.append(actions(...['마이크 권한 확인',...(p.mode==='pushToTalk'?['단축키 권한 확인']:[]),'준비 상태 새로고침','macOS 음성 인식 데이터 설치'].map(key=>btn(U(key),()=>show(U(key),M('permissionDemo'))))));
    }
    parent.append(btn(U('게임 안내 지시문'),()=>coordinatorEditor(false),'','chat'));note(parent,U(p.instructions?'사용자 게임 안내 지시문 사용 중':'기본 게임 안내 지시문 사용 중'));
    if(c.coordinator&&c.assistantVoice){
      select(parent,U('안내 목소리'),{voice:'popple'},'voice',[['popple',U('포플 목소리')],['future',U('다른 목소리 · 추가 예정'),true]],null,M('voiceHelp'));
      select(parent,U('음색'),c,'voiceStyle',['F1','F2','F3','F4','F5'].map(n=>[n,n+(n==='F1'?' · '+U('기본값'):'')]));
      coordinatorSlider(parent,U('피치'),c,'pitch',0,6,.5,' '+U('반음'));coordinatorSlider(parent,U('말 빠르기'),c,'rate',.75,1.35,.05,'×');
      parent.append(actions(btn(U('미리듣기'),()=>show(U('미리듣기'),M('voiceDemo')),'','volume'),btn(M('resetDefaults'),()=>{Object.assign(c,{voiceStyle:'F1',pitch:3.5,rate:1});render();},'','refresh')));note(parent,M('voiceHelp'));
    }
    const positions=[['top-left','왼쪽 위'],['top','위 가운데'],['top-right','오른쪽 위'],['left','왼쪽 가운데'],['right','오른쪽 가운데'],['bottom-left','왼쪽 아래'],['bottom','아래 가운데'],['bottom-right','오른쪽 아래']];
    parent.append(node('strong','',U('말풍선 위치')));const map=node('div','v2-bubble-position-map');map.append(node('span','',U('게임 화면')));
    for(const[value,title]of positions){const b=btn('',()=>{p.position=value;render();},'v2-position-choice','chat');b.dataset.position=value;b.setAttribute('aria-label',U(title));b.setAttribute('aria-pressed',String(p.position===value));b.title=U(title);map.append(b);}parent.append(map);
    const restorePosition=btn(U('Frame Check 아래 (기본)'),()=>{p.position='frame-check';render();},'',p.position==='frame-check'?'checkCircleFill':'circle');restorePosition.setAttribute('aria-pressed',String(p.position==='frame-check'));parent.append(restorePosition);
    note(parent,U(p.position==='frame-check'?'Frame Check 아래 (기본)':positions.find(v=>v[0]===p.position)[1]));
    coordinatorColors(parent,U('말풍선 색상'),p,'bubbleColor',[['navy','짙은 파랑','#06131c'],['charcoal','차콜','#141414'],['copper','구리색','#3b1f14'],['teal','청록색','#082b21'],['plum','자주색','#301c47']]);
    coordinatorSlider(parent,U('말풍선 폭'),p,'bubbleWidth',240,560,20,' pt');coordinatorSlider(parent,U('말풍선 글자 크기'),p,'bubbleFont',11,22,1,' pt');
    const preview=node('div','v2-bubble-sample',ui[locale()==='ko'?'ko':'en']['준비됐어. 같이 가보자!']);preview.dataset.color=p.bubbleColor;preview.style.width=p.bubbleWidth+'px';preview.style.fontSize=p.bubbleFont+'px';parent.append(preview);
    parent.append(btn(U('말풍선 크기 기본값'),()=>{p.bubbleWidth=300;p.bubbleFont=13;render();},'','refresh'));note(parent,M('appearanceHelp'));
    select(parent,U('인식 모델'),{model:'OWLv2'},'model',[['OWLv2','OWLv2'],...['Grounding DINO Tiny','SigLIP 2','TinyCLIP'].map(n=>[n,n+' · '+U('추가될 수 있음'),true])],null,M('modelHelp'));
    parent.append(btn(U('검출 대상 설정'),()=>coordinatorEditor(true),'','search'));note(parent,U(p.targets?'사용자 지정 검출 대상 사용 중':'기본 검출 대상 사용 중'));
    coordinatorColors(parent,U('캐릭터 박스 색상'),p,'boxColor',[['cyan','하늘색','#33ccff'],['green','초록색','#4dff80'],['orange','주황색','#ffa633'],['pink','분홍색','#ff66bf'],['white','흰색','#ffffff']]);
    coordinatorSlider(parent,U('최대 박스 크기'),p,'maxBox',5,100,1,'%');note(parent,M('boxHelp'));
    parent.append(actions(btn(U('크기 비교 보기'),()=>{show(U('박스 크기 비교'),M('boxHelp'));const grid=node('div','v2-box-area-grid');for(const value of [5,10,15,25,35,50]){const figure=node('figure'),screen=node('div'),area=node('i');area.style.width=Math.sqrt(value/100)*100+'%';area.style.height=Math.sqrt(value/100)*100+'%';screen.append(area);figure.append(screen,node('figcaption','',value+'%'));grid.append(figure);}dialog.append(grid);} ,'','grid'),btn(U('기본값 10%'),()=>{p.maxBox=10;render();},'','refresh')));
    note(parent,M('coordinatorLanguage'));note(parent,M('liveSettings'));
  };
  const coordinatorControl = (parent,c) => {
    const row=node('div','sim-toggle-row'),label=node('div','v2-control-label');
    label.append(node('span','',M('coordinator')),info(M('coordinator'),M('coordinatorHelp')));
    const control=btn('',()=>{
      if(c.coordinator){c.coordinator=false;render();return;}
      if(state.coordinatorPrefs.accepted){c.coordinator=true;state.coordinatorPrefs.details=true;render();}else coordinatorNoticeView(c,true);
    },'sim-switch');control.id='v2-coordinator-toggle';control.setAttribute('role','switch');control.setAttribute('aria-label',M('coordinator'));control.setAttribute('aria-checked',String(c.coordinator));control.append(node('span'));
    control.disabled=!c.coordinator&&(c.neural||c.renderer==='WineD3D');row.append(label,control);parent.append(row);
    if(c.neural)note(parent,U('DLSS5를 먼저 끄면 AI Coordinator를 켤 수 있습니다.'),true);
    if(c.renderer==='WineD3D')note(parent,U('AI Coordinator는 D3DMetal, DXMT, DXVK에서 사용할 수 있습니다.'),true);
    if(c.coordinator){toggle(parent,U('영역 박스와 은은한 강조'),c,'highlights',M('boxHelp'));toggle(parent,U('말풍선 안내'),c,'assistantText',M('appearanceHelp'));toggle(parent,U('음성 안내'),c,'assistantVoice',M('voiceHelp'));}
    parent.append(btn(U('AI Coordinator 사용 금지 목록'),()=>coordinatorNoticeView(c),'','list'));
    const details=node('details','v2-disclosure v2-coordinator-details');details.open=state.coordinatorPrefs.details;details.append(node('summary','',U('Coordinator 세부 설정')));details.addEventListener('toggle',()=>{state.coordinatorPrefs.details=details.open;});const body=node('div','v2-coordinator-settings');coordinatorDetails(body,c);details.append(body);parent.append(details);
  };
  const processing = parent => {
    const c=config(), block=node("div","v2-processing");
    toggle(block,U("DLSS5 Emulation (베타)"),c,"neural",helpText("dlss5")+'\n\n'+M('resolutionHelp'),on=>{if(on)c.frameCheck=true;});
    block.querySelector('[data-option="neural"] button[role="switch"]').disabled=c.coordinator;
    if(c.coordinator)note(block,U('AI Coordinator를 먼저 끄면 DLSS5를 켤 수 있습니다.'),true);
    if(c.neural){
      select(block,U("보정 방식"),c,"method",[["HyPER-GAN","HyPER-GAN"],["MLX-DLSS","MLX-DLSS Neural Rendering"]]);
      if(c.method==="MLX-DLSS")note(block,C("mlx"),true);
      else{
        select(block,U("보정 해상도"),c,"resolution",[["720p",U("720p · 속도 우선")],["native",U("원본 해상도")]]);
        select(block,U("화면 스타일"),c,"style",[["Cityscapes","Cityscapes"],["Mapillary Vistas","Mapillary Vistas"]]);
        select(block,U("보정 반복"),c,"passes",[1,2,3,4,5].map(n=>[n,String(n)]),null,C('passes'));
        const row=node("label","sim-field"),slider=node("input"),value=node("output","",`${c.strength}%`);slider.type="range";slider.min="0";slider.max="100";slider.step="5";slider.value=c.strength;slider.setAttribute("aria-label",U("보정 강도"));
        slider.addEventListener("input",()=>{c.strength=Number(slider.value);value.textContent=c.strength+"%";});slider.addEventListener("change",render);row.append(node("span","",U("보정 강도")),slider,value);block.append(row);
      }
    }
    toggle(block,U("Frame Generation (베타)"),c,"fg",helpText("fg"));
    if(c.fg){select(block,U("프레임 생성 방식"),c,"interpolation",["Simple","Motion Lite","Motion Quality","Motion Repair"].map(n=>[n,U(n)]),null,U({"Simple":"같은 위치의 두 화면을 섞습니다. 부담이 가장 적지만 움직이는 물체가 겹쳐 보일 수 있습니다.","Motion Lite":"작은 영역의 움직임을 찾아 중간 위치에 표시합니다. 복잡한 경계에서는 오차가 생길 수 있습니다.","Motion Quality":"더 촘촘하게 움직임을 추정합니다. 세밀한 움직임에 유리하지만 GPU 부담이 늘어납니다.","Motion Repair":"정밀 추정 후 작은 빈틈과 어긋난 경계를 원본 화면에서 다시 찾아 복원합니다. 두 원본에 없는 내용은 복원할 수 없습니다."}[c.interpolation]));
      const fps=actions(btn("120 FPS",()=>show("120 FPS",C("target")),"sim-selected"));for(const n of [144,240]){const b=btn(`${n} FPS · ${U("준비 중")}`,()=>{});b.disabled=true;fps.append(b);}block.append(node("p","sim-note",U("목표 표시 FPS")),fps);
    }
    toggle(block,"Frame Check",c,"frameCheck",helpText("framecheck"));
    coordinatorControl(block,c);
    parent.append(block);
  };
  const launchView = parent => {
    const c=config(), name=platform(), title=view==="steam"?U("Steam 실행"):view==="exe"?U("프로그램 실행"):U("%@ 실행",name);
    const box=card(U("백엔드 선택 후 실행"),helpText(view));
    const launch=btn(title,()=>{if(!['steam','profiles','exe'].includes(view)&&!state.installed[view]){show(C("installTitle"),C("installNotice"),[[C("exampleInstaller"),()=>{state.installed[view]=true;render();}]]);return;}state.launched[configKey()]=true;render();show(title,['steam','profiles'].includes(view)?D("launch"):view==="exe"?D("exeLaunch"):C("platformLaunch"));},"sim-primary",'play');launch.dataset.launch='';launch.disabled=!state.ready||(view==="exe"&&!state.file);
    box.append(actions(launch,btn(U("설정 저장"),saveConfig),btn(view==="exe"?U("EXE 파일 선택"):U("저장공간 관리"),()=>view==="exe"?chooseFile():view==='profiles'?show(U('저장공간 관리'),helpText('storage')):setWorkspace("storage")),btn(U("Wine 강제 종료"),()=>show(U("Wine 강제 종료"),C("stopNotice"),[[C("confirmExample"),()=>{state.launched={};render();}]]))));
    if(!state.ready)box.append(btn(C("setupNeeded"),()=>go("setup")));
    if(view==="exe"&&state.file){box.append(node("p","sim-file",state.file));if(state.installer)note(box,C("installerMode"),true);}
    const status=node('div','v2-launch-status');status.append(badge(D(state.ready?'ready':'waiting'),state.ready?'ok':'warning'),info(U("최근 Steam 실행 상태"),state.launched[configKey()]?C('launchResult'):C('readyExample')));box.append(status);
    if(view==="battlenet")box.append(btn(C("safariTitle"),()=>show(C("safariTitle"),C("safariBody"))));
    renderers(box);processing(box);toggle(box,"Game Mode",c,"gameMode",C("gameMode"));
    select(box,U("네트워크 (베타)"),c,"network",[["standard",U("표준 네트워크")],["Ethernet",U("Ethernet 호환성")],["Wi-Fi",U("Wi-Fi 호환성")]],null,U(c.network==="standard"?"게임에 네트워크 종류를 원래대로 표시합니다. 연결 형식 인식에 문제가 없다면 이 설정을 사용하세요.":c.network==="Wi-Fi"?"게임이 연결을 Wi-Fi로 인식하도록 표시합니다. 게임의 네트워크 종류 인식 문제를 비교할 때 사용하며, 실제 연결 방식이나 속도는 바뀌지 않습니다.":"게임이 연결을 유선 Ethernet으로 인식하도록 표시합니다. 게임의 네트워크 종류 인식 문제를 비교할 때 사용하며, 실제 연결 방식이나 속도는 바뀌지 않습니다."));
    select(box,U("오디오 입력 (베타)"),c,"microphone",[[false,U("오디오 입력 끔")],[true,U("오디오 입력 켬")]],null,C('microphone'));
    select(box,U("게임 비디오 메모리 (베타)"),c,"vram",[["auto",U("자동")],...[2,4,8,12,16].map(n=>[String(n),n+" GB"])],null,U("게임에 알려줄 비디오 메모리 용량입니다. 실제 메모리를 미리 차지하지 않습니다. 자동은 Mac 통합 메모리의 절반을 기준으로 2~16 GB 안에서 정하며, 변경한 값은 다음 실행부터 적용됩니다."));
    const keyboard=node('div','v2-native-action-row');keyboard.append(symbol('keyboard'),node('span','',U("키보드 입력")),node('small','',U("시스템 기본값")),btn(U("설정하기"),()=>openPreferences('input')));keyboard.lastChild.setAttribute('aria-label',U('키보드 설정하기'));box.append(keyboard);
    const controller=node('div','v2-native-action-row');controller.append(symbol('controller'),node('span','',U('컨트롤러')),badge(U('미확인'),'neutral'),btn(U("컨트롤러 확인"),()=>{state.checkedController=true;render();show(U("컨트롤러 확인"),C("controller"));}));box.append(controller);
    const saved=configSaved(),summary=node('div','v2-configuration-summary');summary.append(symbol(saved?'download':'sliders'),node('strong','',U(saved?"다음 실행 초안 · 저장됨":"다음 실행 초안 · 저장되지 않은 변경")),info(U('설정 저장'),C(saved?'saved':'unsaved')));summary.append(node('small','',`${c.renderer} · ${c.fg?'FG':'FG OFF'} · ${c.frameCheck?'Frame Check':'Frame Check OFF'} · ${c.network==='standard'?U('표준 네트워크'):c.network}`));box.append(summary);
    const recent=node('div');note(recent,state.launched[configKey()]?C('launchResult'):U('미확인'));recent.append(btn(U('문제 진단 (베타)'),()=>show(L('diagnostics'),M('diagnosticsGuide')),'','diagnostics'));box.append(disclosure(U('최근 Steam 실행 상태'),view+'-recent',recent));
    if(state.advanced){const advanced=node('div');advanced.append(btn(U('Steam 프리픽스 재생성'),()=>show(U('Steam 프리픽스 재생성'),D('rebuild'))));box.append(disclosure(U('고급 정보'),view+'-advanced',advanced));}
    if(state.launched[configKey()])box.append(btn(U("문제 진단 (베타)"),()=>show(L("diagnostics"),M("diagnosticsGuide"))));
    parent.append(box);
  };
  const chooseFile = () => show(U("EXE 파일 선택"),D("fileHint"),["ClassicGame.exe","Setup.exe","WindowsUtility.exe"].map(file=>[file,()=>{state.file=file;state.installer=file==="Setup.exe";render();}]));
  const storageView = parent => {
    const managed=card(U('공통 Windows 저장공간'),helpText('storage'),'drive'),location=node('div','v2-native-action-row');location.append(symbol('folder'),node('span','',U('앱 데이터 위치')),node('code','','ForgePlay / SteamShared'),btn(U('관리'),()=>show(U('앱 데이터 위치'),C('step3'))));managed.append(location);parent.append(managed);
    const box=card(U("Steam 저장공간 연결"),helpText("storage"),'drive');note(box,U('macOS 저장공간을 연결해 ForgePlay에 접근 권한을 부여하세요. 빈 위치는 Steam이 새 라이브러리를 만들 수 있는 Windows 드라이브로 연결하고, 기존 SteamLibrary는 자동 인식합니다.'));
    box.append(actions(btn(U("외장 드라이브/폴더 연결"),()=>show(D("choose"),D("fileHint"),[[D("existing"),()=>{state.library="existing";render();}],[D("emptyLabel"),()=>{state.library="empty";render();}]])),btn(U("Steam 참고 목록 새로고침"),()=>show(U("Steam 참고 목록 새로고침"),C("refreshLibrary")))));
    if(state.library){const result=node("div","sim-result");result.append(symbol('drive',32),node("strong","",state.library==="existing"?"SteamLibrary · F:\\":"ExternalDrive · F:\\"));note(result,D(state.library==="existing"?"connected":"empty"));result.append(btn(U("연결 해제"),()=>{state.library=null;render();}));box.append(result);}parent.append(box);
    const records=card(U('Steam 라이브러리 참고 목록'),null,'list');note(records,U('이 목록은 Steam 라이브러리 연결과 진단 참고용입니다. ForgePlay는 여기서 게임을 직접 실행하지 않고 Windows용 Steam만 실행합니다.'));const empty=node('div','v2-empty-state');empty.append(symbol('search',38),node('strong','',U('Steam 참고 기록이 비어 있습니다')),node('p','sim-note',D('fileHint')));records.append(empty);parent.append(records);
  };
  const componentsView = parent => {const box=card(U("필수 구성요소 설치 도구"),helpText("components"));note(box,C("components"));box.append(actions(...["VC++","DirectX",".NET","OpenAL","XNA","PhysX"].map(n=>btn(n,()=>show(n,D("fileHint")+"\n\n"+helpText("components"))))));parent.append(box);};
  const setupView = parent => {
    const box=card(M('setup'),M('readiness'),'checklist');note(box,M('readiness'));
    const steps=[['앱 데이터 준비','drive',C('step0')],['Mac 상태 확인','display',C('step1')],['ForgePlay Runtime','gear',C('step2')],['Steam 프리픽스','drive',C('step3')],['Steam 설치','download',C('step4')],['Steam 실행 경로 정비','display',M('rendererManagement')],['Steam 로그인 및 라이브러리','person',C('step5')],['라이브러리 연결','folderPlus',U('선택 사항으로 Steam 라이브러리 참고 목록을 찾거나 외장 라이브러리를 Windows 드라이브로 연결합니다.')],['Steam 실행','checkCircle',U('Windows용 Steam을 실행할 준비가 되었습니다.')]];
    const progress=node('progress');progress.max=steps.length;progress.value=state.setup;progress.setAttribute('aria-label',U('준비 상태'));box.append(progress);
    for(const[k,[label,glyph,detail]]of steps.entries()){
      const neutral=k===5||k===6,row=node('div','sim-setup-row');row.dataset.complete=String(!neutral&&k<state.setup);
      const caption=node('div');caption.append(node('strong','',U(label)),node('p','sim-note',detail));row.append(symbol(!neutral&&k<state.setup?'checkCircleFill':glyph,22),caption);
      if(neutral)row.append(badge(M(k===5?'autoManaged':'inSteam'),'neutral'));
      else if(k===state.setup)row.append(btn(C('tryStep'),()=>{state.setup++;while([5,6].includes(state.setup))state.setup++;state.ready=state.setup===steps.length;render();},'','arrow'));
      else row.append(badge(D(k<state.setup?'ready':'waiting'),k<state.setup?'ok':'neutral'));
      box.append(row);
    }
    box.append(actions(btn(U("Rosetta 설치"),()=>show(U("Rosetta 설치"),C("rosetta"))),btn(C("firstUse"),()=>{state.setup=0;state.ready=false;render();})));
    if(state.ready)box.append(btn(U("Steam 실행 화면 열기"),()=>go("steam"),"sim-primary"));parent.append(box);
  };
  const profilesView = parent => {
    const picker=card(U('게임 프로필'),helpText('profiles'));select(picker,U('게임 프로필'),state,'profile',[['helldivers2','HELLDIVERS 2 · App ID 553850'],['witcher3','The Witcher 3 Remastered · DX12']]);parent.append(picker);
    if(state.profile==='witcher3'){
      const box=card('The Witcher 3 Remastered · DX12');
      note(box,U('먼저 일반 Steam 실행을 사용하세요. D3DMetal에서 게임 창이 검게 멈출 때만 이 시험 보완을 고려하세요. Steam 자체 실행 실패나 로그인 문제를 해결하는 기능은 아닙니다.'));
      note(box,U('보완을 적용하거나 복구하기 전에 위처 3 게임을 정상 종료하세요. Steam 클라이언트는 켜 두어도 됩니다.'));
      box.append(btn(U('게임 폴더 선택'),()=>show(U('게임 폴더 선택'),D('fileHint'),[[C('confirmExample'),()=>{state.witcherFolder=true;render();}]]),'','folder'));
      note(box,state.witcherFolder?'The Witcher 3 · '+D('example'):U('게임 폴더를 선택하세요.'));
      const apply=btn(U('위처 3 보완 적용'),()=>show(U('위처 3 호환성 보완을 적용할까요?'),U('선택한 게임 폴더의 FidelityFX 로더를 보존한 뒤 교체합니다. 일부 그래픽 효과가 생략될 수 있으며, 보완 해제로 원본을 복구할 수 있습니다. 게임 파일이 업데이트되었으면 자동으로 덮어쓰지 않습니다.')+'\n\n'+D('notice'),[[C('confirmExample'),()=>{state.witcherPatched=true;render();}]]));apply.disabled=!state.witcherFolder;
      const restore=btn(U('보완 해제·원본 복구'),()=>show(U('보완 해제·원본 복구'),D('notice'),[[C('confirmExample'),()=>{state.witcherPatched=false;render();}]]));restore.disabled=!state.witcherPatched;
      box.append(actions(apply,restore,btn(U('상태 확인'),()=>show(U('상태 확인'),state.witcherPatched?U('위처 3 보완이 적용되어 있고 원본이 보존되어 있습니다.'):D('notice'))),btn(U('이전 보완 기록 정리'),()=>show(U('이전 보완 기록 정리'),U('현재 게임 파일은 그대로 두고 ForgePlay가 보존했던 이전 로더와 보완 기록만 제거합니다.')+'\n\n'+D('notice')))));
      if(state.witcherPatched)note(box,U('위처 3 보완이 적용되어 있고 원본이 보존되어 있습니다.')+' · '+D('example'));
      note(box,U('보완은 원본 복구 전까지 유지됩니다. 아래에서 D3DMetal을 선택한 뒤 Steam을 실행하세요. 실행 옵션과 Retina 선택은 이 게임의 호환성 설정에 별도로 저장됩니다.'));parent.append(box);launchView(parent);return;
    }
    const c=config(),box=card('HELLDIVERS 2',helpText('profiles'));note(box,C("profile"));
    box.append(actions(btn(U("루트 선택"),()=>show(U("루트 선택"),D("fileHint"),[[C("confirmExample"),()=>{state.profileRoot=true;render();}]])),btn(U("프로필 권장값 복원"),()=>{state.configs[configKey()]=freshConfig();render();}),btn(U("설정 저장"),saveConfig)));
    note(box,state.profileRoot?C("rootConnected"):C("rootNeeded"));renderers(box);toggle(box,'Game Mode',c,'gameMode',C('gameMode'));
    toggle(box,'Heap zero memory',c,'heap',U("이 게임 프로필의 메모리 호환성 선택이며 다른 Steam 실행 구성과 독립적으로 저장됩니다."));
    note(box,U("선택한 매니페스트 루트 안에서 정확히 일치하는 GameGuard 구성요소 또는 파일 이름만 게임 렌더러 환경과 렌더러 DLL 재정의에서 제외됩니다."));
    select(box,U("네트워크 (베타)"),c,'network',[["standard",U("표준 네트워크")],["Ethernet",U("Ethernet 호환성")],["Wi-Fi",U("Wi-Fi 호환성")]]);
    toggle(box,U("오디오 입력 (베타)"),c,'microphone',C('microphone'));
    select(box,U("게임 비디오 메모리 (베타)"),c,'vram',[["auto",U("자동")],...[2,4,8,12,16].map(n=>[String(n),n+' GB'])]);
    const launch=btn(U("Steam 실행"),()=>show(U("Steam 실행"),D("launch")),"sim-primary",'play');launch.disabled=!state.profileRoot||!state.ready;box.append(launch);note(box,configSaved()?C('saved'):C('unsaved'));parent.append(box);
  };
  const dashboardView = parent => {
    const workflow=card(U(state.ready?'Windows용 Steam 실행':'다음 작업'),C('dashboard'),'playCircle');workflow.classList.add('v2-workflow');workflow.append(badge(U(state.ready?'실행 준비 완료':'준비 필요'),state.ready?'ok':'warning'));note(workflow,U('Windows용 Steam을 열고 Steam 라이브러리에서 게임을 실행합니다.'));workflow.append(actions(btn(U(state.ready?'백엔드 선택 후 실행':'설정 계속'),()=>go(state.ready?'steam':'setup'),'','sliders'),btn(U('문제 진단 (베타)'),()=>show(L('diagnostics'),M('diagnosticsGuide')),'','diagnostics')));parent.append(workflow);
    const heading=node('div','v2-section-heading');heading.append(symbol('shield'),node('h3','',U('준비 상태')));parent.append(heading);const grid=node('div','sim-status-grid');for(const[key,glyph]of [['Mac 상태','display'],['ForgePlay Runtime','gear'],['Steam 프리픽스','drive'],['Windows용 Steam','playCircle']]){const item=node('div');item.append(symbol(glyph,25),node('small','',U(key)),badge(D(state.ready?'ready':'waiting'),state.ready?'ok':'warning'));grid.append(item);}parent.append(grid);
    const rosetta=card(U('Rosetta 설치'),C('rosetta'),'chip');rosetta.append(badge(U('미확인'),'neutral'),btn(U('다시 확인'),()=>show(U('Rosetta 설치'),C('rosetta'))));parent.append(rosetta);
    const recent=card(U('최근 활동'),null,'logs');recent.append(btn(U('최근 Steam 실행 상태'),()=>show(U('최근 Steam 실행 상태'),C('launchResult'))),btn(U('문제 진단 (베타)'),()=>show(L('diagnostics'),M('diagnosticsGuide')),'','diagnostics'));parent.append(recent);
  };
  const catalogView = parent => {
    const box=card(U("게임 호환성 DB"),helpText("catalog"));note(box,D("catalog"));const search=node("input");search.type="search";search.placeholder=W("compat.searchPlaceholder");search.setAttribute("aria-label",W("compat.searchPlaceholder"));const list=node("div","sim-catalog");
    const refresh=btn(L('refresh'),()=>void refreshCatalog(),'','refresh');refresh.disabled=catalogLoading;box.append(refresh);
    if(catalogLoading)note(box,L('refreshing'));if(catalogFailed)note(box,L('refreshFailed'),true);
    const model=window.ForgePlayWebCatalog, platformRow=node('label','sim-field'), platform=node('select');
    platform.setAttribute('aria-label',W('compat.platformLabel'));
    for(const value of ['all',...model.platforms]){const option=node('option','',value==='all'?W('compat.platformAll'):model.platformLabel(value,W));option.value=value;platform.append(option);}
    platform.value=state.catalogPlatform||'all';platformRow.append(node('span','',W('compat.platformLabel')),platform);
    const update=()=>{
      list.replaceChildren();if(!catalog){note(list,W("compat.dataError"));return;}
      const groups=model.platformGroups(catalog,platform.value);
      const matched=groups.filter(group=>Object.values(group.game.titles).some(t=>t.toLowerCase().includes(search.value.toLowerCase())));
      for(const {game,launchPlatform,reports,summary:assessment} of matched){
        const description=model.describe(assessment,W),item=node('details');item.dataset.tone=assessment.tone;item.dataset.launchPlatform=launchPlatform;
        const summary=node('summary'),mark=node('span','fp-platform-badge',model.platformLabel(launchPlatform,W));mark.dataset.launchPlatform=launchPlatform;
        summary.append(node('strong','',game.titles[locale()]||game.titles.en),mark,node('span','',description.statusText+' · '+description.versionText));item.append(summary);
        for(const report of model.sortReports(reports))note(item,`ForgePlay ${report.forgePlayVersion||'—'} — ${report.notes?.[locale()]||report.notes?.en||''}`);
        list.append(item);
      }
      if(!matched.length)note(list,W(platform.value!=='all'&&!groups.length?'compat.platformEmpty':'compat.empty'));
    };
    search.addEventListener('input',update);platform.addEventListener('change',()=>{state.catalogPlatform=platform.value;update();});
    box.append(search,platformRow,list);update();parent.append(box);
  };
  const refreshCatalog = async () => {
    if(catalogLoading)return;catalogLoading=true;catalogFailed=false;
    if(surface==='utility'&&view==='catalog')render();
    try{catalog=await window.ForgePlayWebCatalog.load();}catch{catalogFailed=true;}
    finally{catalogLoading=false;if(surface==='utility'&&view==='catalog')render();}
  };
  const diagnosticReply = question => /FG|DLSS|frame|프레임|フレーム|帧|影格/i.test(question)?"replyGraphics":/library|라이브러리|外|储存|儲存/i.test(question)?"replyStorage":"replyGeneral";
  const diagnosticsView = parent => {
    const greeting=node('div','v2-fopl-greeting'),mascot=node('img');mascot.src=artworkRoot+'fopl-diagnostics.webp';mascot.alt='';greeting.append(mascot,node('p','',L('foplHello')));parent.append(greeting);
    const chat=card(U("문제 진단 (베타)"),C('chatNotice'),'diagnostics');chat.append(badge(D('example'),'neutral'));chat.append(actions(...["questionGraphics","questionStorage","questionStartup"].map(k=>btn(C(k),()=>{state.aiEnabled=true;state.chat.push({key:k,reply:({questionGraphics:'replyGraphics',questionStorage:'replyStorage',questionStartup:'replyGeneral'})[k]});render();}))));
    const transcript=node("div","v2-chat");transcript.setAttribute("role","log");for(const entry of state.chat){transcript.append(node("p","v2-chat-user",entry.key?C(entry.key):entry.question),node("p","v2-chat-reply",C("sampleReply")+"\n"+C(entry.reply)));}chat.append(transcript);
    const form=node("form","v2-chat-form"),input=node("textarea");input.rows=2;input.maxLength=500;input.placeholder=C("chatPlaceholder");input.setAttribute("aria-label",C("chatPlaceholder"));const send=node("button","sim-primary");send.append(symbol('send'),node('span','',U('질문 보내기')));send.type="submit";form.append(input,send);form.addEventListener("submit",event=>{event.preventDefault();const q=input.value.trim();if(!q)return;state.aiEnabled=true;state.chat.push({question:q,reply:diagnosticReply(q)});render();});chat.append(form);parent.append(chat);
    const logs=card(U("최근 로그 다시 분석"));note(logs,C("logs"));logs.append(actions(btn(U("최근 로그 다시 분석"),()=>show(D("result"),C("replyGeneral"))),btn(U("AI 로컬 분석 전 미리보기"),()=>show(U("AI 로컬 분석 전 미리보기"),D("ai")+"\n\n"+C("chatNotice"))),btn(U("지원 번들 생성"),()=>show(U("지원 번들 생성"),D("bundle")))));parent.append(logs);
    const snapshots=card(U("복구 스냅샷 관리"),helpText("snapshots"));snapshots.append(btn(U("스냅샷 목록 확인"),()=>{state.snapshotLoaded=true;render();}));if(state.snapshotLoaded){for(const record of state.snapshots){const row=node("div","v2-snapshot");row.append(node("code","",record.id),node("span","",record.protected?C("protected"):C("exampleBackup")));const remove=btn(U("선택한 백업 삭제"),()=>show(U("선택한 복구 백업을 삭제할까요?"),C("deleteBackup"),[[U("취소"),()=>{}],[C("confirmExample"),()=>{state.snapshots=state.snapshots.filter(r=>r.id!==record.id);render();}]]));remove.disabled=record.protected;row.append(remove);snapshots.append(row);}if(!state.snapshots.length)note(snapshots,U("남아 있는 복구 스냅샷이 없습니다."));}parent.append(snapshots);
  };
  const prefsView = parent => {
    const tabbar=node("div","sim-subnav");for(const id of ["general","input","environment","maintenance","about"]){const b=btn(viewName(id),()=>{preference=id;renderPreferences();});b.setAttribute("aria-pressed",String(preference===id));tabbar.append(b);}parent.append(tabbar);const box=card(preference==='maintenance'?U('문제 분석 기록 보존'):viewName(preference),helpText(preference),{general:'gear',input:'keyboard',environment:'list',maintenance:'logs',about:'info'}[preference]);
    if(preference==="general"){
      const general=node('div','v2-general-grid'),right=node('div'),language=card(U('앱 언어'),C('preferences'),'globe'),grid=node('div','v2-language-grid');for(const l of locales){const title=({ko:'한국어',en:'English',de:'Deutsch',es:'Español',fr:'Français',ja:'日本語','zh-Hans':'简体中文','zh-Hant':'繁體中文'})[l];const b=btn(title,()=>{const master=document.querySelector('[data-language-select]');master.value=l;master.dispatchEvent(new Event('change',{bubbles:true}));},l===locale()?'sim-selected':'',l===locale()?'checkCircle':'circle');b.setAttribute('aria-pressed',String(l===locale()));grid.append(b);}language.append(grid);general.append(language,right);parent.append(general);
      const appearance=card(U('화면 스타일'),null,'palette'),themes=node('div','sim-subnav');for(const[key,label]of [['system','시스템 설정 따르기'],['light','라이트'],['dark','다크']]){const b=btn(U(label),()=>{state.theme=key;render();});b.setAttribute('aria-pressed',String(state.theme===key));themes.append(b);}appearance.append(themes);right.append(appearance);
      toggle(appearance,U('포플 자동 말풍선'),state,'poppleTips',U('앱이 앞에 있을 때 가끔 인사와 현재 화면의 사용 팁을 보여줍니다. 소리는 나지 않습니다.'));
      toggle(appearance,U('고급 정보 표시'),state,'advanced');
      const ai=card(U('문제 진단 (베타)'),C('chatNotice'),'diagnostics');toggle(ai,U('AI 문제 진단(베타) 사용'),state,'aiEnabled',C('chatNotice'));ai.append(badge(U('미확인'),'neutral'),node('p','sim-note','Apple Foundation Models'));right.append(ai);return;
    }else if(preference==="input"){
      note(box,U('입력 보호는 일반 Steam과 Steam 호환성 실행에 적용됩니다. 설정을 바꾼 뒤 Steam을 완전히 종료하고 다시 실행하세요. 이미 실행 중인 Steam과 다른 플랫폼·EXE에는 새 설정이 적용되지 않습니다.'));
      toggle(box,U("게임이 전면일 때 macOS 포인터 숨기기 (베타)"),state,"pointer");toggle(box,U("게임용 보조키 매핑 사용"),state,"mapping");
      if(state.mapping)for(const key of ["command","option","control"])select(box,key[0].toUpperCase()+key.slice(1),state,key,[["Ctrl","Ctrl"],["Alt","Alt"],["none",U("전달 안 함")]]);
      for(const[key,label]of [["quitKeys","게임 중 앱 종료·창 관리 단축키 차단"],["switchKeys","게임 중 앱 전환·검색 단축키 차단"],["spaces","게임 중 Mission Control·Spaces 키보드 단축키 차단"],["screenshots","게임 중 macOS 기본 스크린샷 단축키 차단"]])toggle(box,U(label),state,key);
      const permissions=node('div','v2-permission-status');for(const name of ['손쉬운 사용 권한','입력 모니터링 권한']){const row=node('div');row.append(symbol('shield'),node('span','',U(name)),badge(U('미확인'),'neutral'));permissions.append(row);}box.append(permissions);parent.append(box);const awdl=card('AWDL',C('awdl'),'wifi');toggle(awdl,'AWDL',state,'awdl');if(!state.awdl)note(awdl,D('visionWarning'),true);awdl.append(btn(U('AWDL 상태 새로고침'),()=>show('AWDL',D('notice'))));parent.append(awdl);return;
    }else if(preference==="environment"){note(box,helpText("environment"));box.append(actions(btn(U("Steam 프리픽스 재생성"),()=>show(U("Steam 프리픽스 재생성"),D("rebuild"))),btn(U("설정"),()=>{dialog.close();go("setup");})));}
    else if(preference==="maintenance"){toggle(box,U('오래된 문제 분석 기록 자동 정리'),state,'autoCleanup');for(const[key,label,max]of [['retained','최근 %d일 보존',365],['logLimit','Steam 실행 로그 세트 최대 %d개 보존',200]]){const row=node('label','sim-field');const input=node('input');input.type='number';input.min=1;input.max=max;input.value=state[key];input.setAttribute('aria-label',U(label).replace('%d',''));input.addEventListener('change',()=>{state[key]=Math.min(max,Math.max(1,Number(input.value)||1));render();});row.append(node('span','',U(label).replace('%d',state[key])),input);box.append(row);}box.append(actions(btn(U('보존 설정 저장'),()=>show(U('보존 설정 저장'),D('saved')),'','check'),btn(U("지금 정리"),()=>show(U("지금 정리"),D("notice")),'','trash'),btn(U("지원 번들 생성"),()=>show(U("지원 번들 생성"),D("bundle")))));}
    else {note(box,"ForgePlay "+guideVersion());box.append(external(W("shared.navLicense"),"license.html?lang="+locale()),external(W("shared.navPrivacy"),"privacy.html?lang="+locale()));}
    parent.append(box);
  };
  let preferencesOpen=false;
  const isLight=()=>state.theme==='light'||(state.theme==='system'&&(document.documentElement.dataset.siteTheme?document.documentElement.dataset.siteTheme==='light':matchMedia('(prefers-color-scheme: light)').matches));
  const renderPreferences = () => {dialog.classList.toggle('sim-light',isLight());dialog.replaceChildren();const header=node("div","sim-dialog-head");const h=node("h2","",U("환경 설정"));h.id="v2-dialog-title";header.append(symbol('gear',22),h,btn(D("close"),()=>dialog.close()));dialog.append(header);prefsView(dialog);};
  const openPreferences = (pane="general") => {focusBeforeDialog=document.activeElement;preference=pane;preferencesOpen=true;dialog.classList.remove('v2-founder-dialog');dialog.classList.toggle('v2-launcher-dialog',surface==='launcher');dialog.classList.add("v2-preferences");renderPreferences();dialog.showModal();};
  const appsView = parent => {
    const tabs=node('div','sim-subnav');for(const[id,label]of [['mac','Mac'],['ipad','iPad'],['iphone','iPhone']]){const b=btn(label,()=>{state.appPlatform=id;render();});b.setAttribute('aria-pressed',String(state.appPlatform===id));tabs.append(b);}parent.append(tabs);
    const sections=node('div','sim-subnav');for(const key of ['released','developing']){const b=btn(L(key),()=>{state.appSection=key;render();});b.setAttribute('aria-pressed',String((state.appSection||'released')===key));sections.append(b);}parent.append(sections);
    const grid=node('div','v2-app-catalog'),items=state.appSection==='developing'?appCatalog?.inDevelopment:appCatalog?.apps;
    for(const app of items?.filter(a=>a.id!=='forgeplay'&&a.platform===state.appPlatform)||[]){const item=node('article'),image=node('img');image.src=app.artwork;image.alt='';image.width=48;image.height=48;image.loading='lazy';item.append(image,node('strong','',app.name),node('p','sim-note',app.summaries[locale()]||app.summaries.en));if(app.href)item.append(external(C('more'),app.href));grid.append(item);}parent.append(grid,external(C('more'),'index.html?lang='+locale()+'#other-apps'));
  };
  let mascotAnimation=null,lastMascotSwing=0;
  const swingMascot = (direction=1) => {
    const element=shell?.querySelector('.v2-mascot-hang');
    if(!element||document.hidden||root.classList.contains('v2-guide-offscreen')||matchMedia('(prefers-reduced-motion: reduce)').matches)return;
    const now=performance.now();if(now-lastMascotSwing<120)return;lastMascotSwing=now;
    mascotAnimation?.cancel();mascotAnimation=element.animate([{transform:'rotate(0deg)'},{transform:'rotate('+(-11*direction)+'deg)'},{transform:'rotate('+(7*direction)+'deg)'},{transform:'rotate('+(-3*direction)+'deg)'},{transform:'rotate(0deg)'}],{duration:900,easing:'ease-out'});
  };
  const desktopMascot = () => {
    const group=node('div','v2-desktop-mascot'),button=btn('',()=>show(M('fopl'),M('foplHint')),'v2-mascot-button',false),hang=node('span','v2-mascot-hang'),sprite=node('span','v2-mascot-sprite');
    button.setAttribute('aria-label',M('talk'));hang.append(sprite);hang.setAttribute('aria-hidden','true');button.append(hang);
    group.append(button,node('strong','',M('fopl')),node('small','','ForgePlay Mascot'));return group;
  };
  const retinaControl = () => {
    const enabled=retinaEnabled(),row=node('div','v2-retina-control'),control=btn('',()=>{if(view==='profiles')config().retina=!enabled;else state.retina=!enabled;render();},'sim-switch',false);
    control.id='v2-retina-toggle';control.setAttribute('role','switch');control.setAttribute('aria-label',M('retina'));control.setAttribute('aria-checked',String(enabled));control.append(node('span'));
    row.append(node('span','v2-retina-label',M('retina')),control,node('small','',M(enabled?'on':'off')));
    const saved=view==='profiles'?JSON.parse(state.saved[configKey()]||'{}').retina===enabled:state.retina===state.savedRetina;
    if(!saved)row.append(node('small','v2-retina-unsaved',M('unsaved')));
    row.append(info(M('retina'),U('Retina는 기본 꺼짐입니다. 켜면 Windows 게임에 더 높은 실제 픽셀 해상도가 제공될 수 있으며, 4K 지원은 게임과 디스플레이에 따라 다릅니다. 일반 실행 화면은 설정을 공유하고 Steam 호환성 실행은 게임별로 따로 저장합니다. 설정 저장 후 Windows 런처와 게임을 종료하고 다시 실행하세요.')+'\n\n'+M('resolutionHelp')));return row;
  };
  const renderMac = () => {
    const utility=surface==='utility',bar=node("div","sim-titlebar"),leading=node('div','v2-toolbar-leading');leading.append(windowLights(utility?closeUtility:null));
    if(!utility){const back=btn('',()=>{surface='launcher';render();},'v2-toolbar-button','launcher');back.setAttribute('aria-label',U('런처로 돌아가기'));leading.append(back);}
    const settings=btn('',()=>openPreferences(),'v2-toolbar-button','gear');settings.setAttribute('aria-label',U('환경 설정'));bar.append(leading,node('strong','',utility?viewName(view):'ForgePlay'),settings);shell.append(bar);
    const layout=node("div","sim-layout"),sidebar=node("aside","sim-sidebar"),brand=node("div","sim-brand"),icon=node("img");
    icon.src=artworkRoot+'brand-'+(isLight()?'light':'dark')+'.webp';icon.className='v2-mac-brand';icon.alt="";icon.width=40;icon.height=40;
    const brandText=node('div');brandText.append(node('strong','','ForgePlay'),node('small','',U('Windows 게임을 Mac에서 더 쉽게.')));brand.append(icon,brandText);sidebar.append(brand);
    const navigation=node("nav");navigation.setAttribute("aria-label",C("macNavigation"));
    for(const id of ["setup","steam","profiles","battlenet","epic","stove","exe","dashboard"]){const b=btn(viewName(id),()=>go(id),"sim-nav-item",viewGlyphs[id]);b.dataset.v2Nav=id;b.dataset.nativeSymbol=nativeSymbols[id];b.setAttribute("aria-pressed",String(view===id));navigation.append(b);}
    const setup=btn(U(state.ready?'시스템 준비 완료':'시스템 확인 필요'),()=>go('setup'),'sim-update',state.ready?'checkCircle':'warning');setup.append(symbol('chevron',12));setup.title=M('setup');setup.dataset.status=state.ready?'ok':'warning';
    sidebar.append(navigation,desktopMascot(),setup);if(!utility)layout.append(sidebar);
    const launchPages=["steam","battlenet","epic","stove","exe"],hasRetina=launchPages.includes(view)||view==='profiles';
    const body=node("div","sim-body"),heading=node("div","v2-view-heading"),headingCopy=node('div'),headingTitle=node('h2');
    headingTitle.append(symbol(viewGlyphs[view]||'sliders',25),node('span','',viewName(view)));headingCopy.append(headingTitle);
    const headerActions=node('div','v2-view-actions');if(hasRetina)headerActions.append(retinaControl());
    const usage=()=>show(viewName(view),(view==='setup'?M('readiness'):C(['battlenet','epic','stove'].includes(view)?'hintPlatform':"hint"+view[0].toUpperCase()+view.slice(1)))+"\n\n"+helpText(view)+(hasRetina?'\n\n'+M('retinaHelp')+'\n\n'+M('resolutionHelp'):'')+'\n\n'+M('diagnosticsGuide'));
    headerActions.append(btn(U("사용법"),usage));heading.append(headingCopy,headerActions);body.append(heading);
    if(hasRetina&&retinaEnabled())body.append(node('p','v2-retina-warning',M('resolutionHelp')));
    if(launchPages.includes(view)){const tabs=node("div","sim-subnav");for(const[id,key,glyph]of [["launch","실행 및 그래픽",'playCircle'],["storage","저장공간",'drive'],["components","구성요소",'puzzle']]){const b=btn(U(key),()=>setWorkspace(id),'',glyph);b.setAttribute("aria-pressed",String(workspace===id));tabs.append(b);}body.append(tabs);}
    const content=node("div","sim-content");content.tabIndex=-1;content.dataset.v2Content=view;
    if(launchPages.includes(view)){({launch:launchView,storage:storageView,components:componentsView})[workspace](content);}
    else ({setup:setupView,profiles:profilesView,dashboard:dashboardView,catalog:catalogView,diagnostics:diagnosticsView,apps:appsView})[view]?.(content);
    let previousScroll=0;content.addEventListener('scroll',()=>{const next=content.scrollTop;swingMascot(next>=previousScroll?1:-1);previousScroll=next;},{passive:true});
    body.append(content);layout.append(body);shell.append(layout);
  };
  const brandImage = () => {const image=node('img','v2-brand-mark');image.src=artworkRoot+'brand-'+(isLight()?'light':'dark')+'.webp';image.alt='';image.width=74;image.height=74;return image;};
  const launcherTiles=[
    ['mac','display','mac','captionMac'],['vr','vision','vr','coming'],
    ['retro','controller','old-game','coming'],['console','controllerFill','console-game','coming'],
    ['catalog','checklist','compatibility','captionCatalog'],['like','thumb','like',null],
    ['sponsor','heart','sponsor',null],['diagnostics','pulse','diagnostics','captionDiagnostics'],
    ['license','logs','license','captionLicense'],['apps','grid',null,'captionApps'],
    ['founder','bulb',null,'captionWhy'],['updates','refresh','updates','coming']
  ];
  const tileLabel = id => ({mac:'Mac',vr:'VR',retro:'Old Game',console:'ConSole Game',catalog:C('launcherCompatibility'),like:C('like'),sponsor:C('sponsor'),diagnostics:L('diagnosticsTile'),license:L('license'),apps:U('제작자의 다른 앱'),founder:L('why'),updates:L('oneClickUpdate')})[id];
  const openFounder = async () => {
    show(L('why'),L('whyHelp'));dialog.dataset.kind='founder';dialog.classList.add('v2-founder-dialog');
    const selected=locale(),navigation=node('details','v2-founder-toc'),body=node('div','v2-founder-body',L('loading'));
    navigation.append(node('summary','',L('contents')));body.tabIndex=0;body.setAttribute('aria-busy','true');dialog.append(navigation,body);
    try {
      const markdown=await window.ForgePlayFounderNote.fetchMarkdown(selected);
      if(!body.isConnected||!dialog.open||dialog.dataset.kind!=='founder')return;
      const result=window.ForgePlayFounderNote.renderMarkdown(markdown,selected);
      navigation.append(result.tocFragment);body.replaceChildren(result.fragment);
      for(const a of dialog.querySelectorAll('a[href^="#"]'))a.addEventListener('click',event=>{
        event.preventDefault();const target=dialog.querySelector('#'+CSS.escape(a.getAttribute('href').slice(1)));
        if(target){navigation.open=false;target.scrollIntoView({block:'start'});target.tabIndex=-1;target.focus({preventScroll:true});}
      });
    }catch{if(body.isConnected){body.replaceChildren(node('p','',L('refreshFailed')),btn(L('retry'),()=>void openFounder()));}}
    finally{body.setAttribute('aria-busy','false');}
  };
  const openUpdates = () => show(L('oneClickUpdate'),L('development'));
  const activateLauncherTile = id => {
    if(id==='vr'){surface='vr';render(true);return;}
    if(['retro','console'].includes(id)){show(tileLabel(id),L('development'));return;}
    if(['mac','catalog','diagnostics','apps'].includes(id)){go(id==='mac'?(state.ready?'steam':'setup'):id);return;}
    if(id==='founder'){void openFounder();return;}
    if(id==='updates'){openUpdates();return;}
    if(id==='license'){show(L('license'),L('licenseHelp'));dialog.append(external(W('shared.navLicense'),'license.html?lang='+locale()));return;}
    show(tileLabel(id),C('support'));dialog.append(external(C('official'),id==='like'?'https://github.com/Facta-Leopard/ForgePlay':'https://github.com/sponsors/facta-leopard'));
  };
  const launcherBanner = (slot,asset,key,cls) => {
    const item=node('div',cls);item.dataset.bannerSlot=slot;const image=node('img');
    image.src=remoteBanners.get(slot)||artworkRoot+'fopl-'+asset+'.webp';image.alt='';image.decoding='async';
    image.className=remoteBanners.has(slot)?'v2-banner-remote':'v2-banner-fopl';
    if(!remoteBanners.has(slot))item.append(window.ForgePlayGuideIcons.backdrop(({'left-portrait':'portal','bottom-left':'journey','bottom-right':'arcade'})[slot]));
    item.append(image,node('p','',C(key).replaceAll('\\n','\n')));return item;
  };
  const renderLauncher = () => {
    const chrome=node('div','v2-launcher-chrome');chrome.append(windowLights(),node('span','','ForgePlay'));shell.append(chrome);
    const header=node('div','v2-launcher-header'),brand=node('div'),reserved=node('div','v2-header-banner');
    brand.append(node('strong','','ForgePlay'),node('small','','Play Beyond Boundaries.'));
    reserved.dataset.bannerSlot='header-center';reserved.setAttribute('aria-hidden','true');
    if(remoteBanners.has('header-center')){const image=node('img');image.src=remoteBanners.get('header-center');image.alt='';reserved.append(image);}
    header.append(brandImage(),brand,reserved,node('p','v2-handwriting','Games.\nOn your terms.'));shell.append(header);
    const ticker=node('div','v2-ticker'),track=node('div','v2-ticker-track'),belt=node('div','v2-ticker-belt');
    const thanks=C('launcherThanks')+(supporters.length?'   '+L('supporters')+' '+supporters.join(' · '):'');
    const message=node('span','',thanks),repeat=node('span','',thanks);repeat.setAttribute('aria-hidden','true');belt.append(message,repeat);track.append(belt);ticker.append(brandImage(),track);
    const pause=btn('',()=>{state.tickerPaused=!state.tickerPaused;render();},'v2-icon-button',state.tickerPaused?'play':'pause');
    pause.setAttribute('aria-label',C('tickerPause'));pause.setAttribute('aria-pressed',String(state.tickerPaused));ticker.dataset.paused=String(state.tickerPaused);ticker.append(pause);shell.append(ticker);
    requestAnimationFrame(()=>{if(message.isConnected){const width=message.getBoundingClientRect().width;belt.style.setProperty('--ticker-distance',(-width)+'px');belt.style.setProperty('--ticker-duration',(width/40)+'s');}});
    const grid=node('div','v2-launcher-layout');grid.append(launcherBanner('left-portrait','left-portrait','launcherGate','v2-launcher-art'));
    const tiles=node('div','v2-launcher-tiles');
    for(const[id,glyph,art,caption]of launcherTiles){
      const b=btn('',()=>activateLauncherTile(id),'v2-launcher-tile'),image=node('img','v2-tile-art');
      image.src=art?artworkRoot+'fopl-'+art+'.webp':artworkRoot+(id==='apps'?'creator-apps-tile':'why-forgeplay-tile')+'-'+(isLight()?'light':'dark')+'.webp';
      image.alt='';image.decoding='async';b.dataset.creator=String(!art);b.dataset.v2Tile=id;
      const title=tileLabel(id),action=caption?L(caption):id==='like'?'GitHub Star':'GitHub Sponsors';
      b.setAttribute('aria-label',title);b.title=title+' · '+action;
      if(art)b.append(window.ForgePlayGuideIcons.backdrop(id));
      const visibleTitle=id==='diagnostics'?title.replace(/\s*([（(])/u,'\n$1'):title;
      b.append(image,symbol(glyph,30),node('strong','',visibleTitle),node('small','',action));tiles.append(b);
    }grid.append(tiles);
    const news=node('aside','v2-launcher-news');renderNews(news);grid.append(news);shell.append(grid);
    const banners=node('div','v2-launcher-banners'),brandPanel=node('div','v2-banner v2-banner-brand'),brandText=node('div');
    brandText.append(node('strong','','ForgePlay'),node('small','','Play Beyond Boundaries.'));brandPanel.append(brandImage(),brandText);
    banners.append(launcherBanner('bottom-left','bottom-left','launcherWorld','v2-banner'),brandPanel,launcherBanner('bottom-right','bottom-right','launcherForge','v2-banner'));shell.append(banners);
    const footer=node('div','v2-launcher-footer');footer.append(node('span','','SILICON | Windows Games on macOS'),node('span','','Play Beyond Boundaries.'),node('span','','v'+guideVersion()),btn('',()=>openPreferences(),'v2-icon-button','gear'));footer.lastChild.setAttribute('aria-label',U('환경 설정'));shell.append(footer);
    const theme=node('div','v2-launcher-tools');theme.append(info(L('appearance'),L('startup')),node('span','',L('appearance')));
    for(const id of ['light','dark']){const b=btn(L(id),()=>{state.theme=id;render();});b.dataset.launcherTheme=id;b.setAttribute('aria-pressed',String(isLight()===(id==='light')));theme.append(b);}shell.append(theme);
  };
  const loadLauncherBanners = async () => {
    try{
      let data;
      try{data=await fetchJSON('site-data/launcher-banners.json');}
      catch(error){
        if(error.status!==404)throw error;
        const legacy=await fetchJSON('site-data/enterprise-supporters.json');
        if(legacy.schemaVersion!==1||!legacy.banner)throw Error('legacy banner contract');
        data={schemaVersion:1,banners:[{...legacy.banner,order:4,slot:'bottom-right'}]};
      }
      const slots=['header-center','left-portrait','bottom-left','bottom-right'];
      if(data.schemaVersion!==1||!Array.isArray(data.banners)||data.banners.length>4)throw Error('banner contract');
      const entries=data.banners;const seen=new Set();
      for(const b of entries){if(!Number.isInteger(b.order)||slots[b.order-1]!==b.slot||seen.has(b.slot)||b.contentMode!=='fit'||!/^https:\/\/facta-leopard\.github\.io\/ForgePlay\/site-assets\/supporters\/[a-z0-9-]+\.png$/.test(b.imageURL))throw Error('banner entry');seen.add(b.slot);}
      const next=new Map();
      const load=async b=>{
        try{
          const response=await fetch(b.imageURL,{credentials:'omit',signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('banner image');
          const reader=response.body.getReader(),chunks=[];let size=0;
          try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>8_000_000)throw Error('banner size');chunks.push(value);}}finally{await reader.cancel();}
          const blob=new Blob(chunks,{type:'image/png'}),bytes=await blob.arrayBuffer();
          const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
          if(hash==='0cb07af680b74377938ead746f245a89cdadab93956734ae53c8b968b32f0424')return;
          const decoded=await createImageBitmap(blob);const valid=decoded.width===b.imageWidth&&decoded.height===b.imageHeight&&decoded.width<=8192&&decoded.height<=8192&&decoded.width*decoded.height<=12_000_000;decoded.close();if(!valid)throw Error('banner dimensions');
          next.set(b.slot,URL.createObjectURL(blob));
        }catch{if(remoteBanners.has(b.slot))next.set(b.slot,remoteBanners.get(b.slot));}
      };
      for(let i=0;i<entries.length;i+=2)await Promise.all(entries.slice(i,i+2).map(load));
      for(const [slot,url]of remoteBanners)if(next.get(slot)!==url)URL.revokeObjectURL(url);
      remoteBanners=next;if(surface==='launcher')render();
    }catch{/* A failed optional feed leaves the current/default illustrations in place. */}
  };
  const renderNews = news => {const heading=node('div','v2-news-heading'),refresh=btn('',async()=>{refresh.disabled=true;try{notices=await fetchJSON('site-data/announcements.json');renderNews(news);}catch{refresh.disabled=false;show(C('refreshNews'),W('updates.dataError'));}},'v2-icon-button','refresh');refresh.setAttribute('aria-label',C('refreshNews'));heading.append(node('h3','',C('launcherNews')),refresh);news.replaceChildren(heading);for(const n of notices?.announcements?.slice(0,3)||[]){const a=node("a");a.href="updates.html?lang="+locale()+"#update-"+n.id;a.append(node("small","",n.publishedAt),node("strong","",n.titles[locale()]||n.titles.en));news.append(a);}news.append(node("p","sim-note",C("newsSource")));};
  const render = (resetScroll=false) => {
    if(!shell)return;const focused=document.activeElement;const focusId=focused.id;const nav=focused.dataset?.v2Nav;const focusText=focused.tagName==='BUTTON'?focused.textContent:null;const scroll=shell.querySelector('.sim-content')?.scrollTop||0;
    mascotAnimation?.cancel();shell.replaceChildren();shell.className="sim-window v2-shell "+(surface==="launcher"?"v2-launcher":"v2-mac")+(surface==='utility'?' v2-utility':'')+(isLight()?" sim-light":"");if(surface==="launcher")renderLauncher();else if(surface==='vr')vrDemo.render(shell);else renderMac();
    const hint=surface==="launcher"?"hintLauncher":workspace==="storage"?"hintStorage":workspace==="components"?"hintComponents":"hint"+view[0].toUpperCase()+view.slice(1);coach.textContent=surface==='vr'?vrDemo.hint():C(hint);root.querySelector('[data-v2-notice]').textContent=C("notice");
    root.querySelector('[data-v2-reset]').textContent=C("reset");root.querySelector('[data-v2-title]').textContent=C("title");root.querySelector('[data-v2-lead]').textContent=C("lead");
    applyWindowSize();
    for(const e of document.querySelectorAll('[data-guide2-text]'))e.textContent=C(e.dataset.guide2Text);
    document.title='ForgePlay — '+C('title');document.querySelector('[data-guide-nav]')?.setAttribute('aria-current','page');
    for(const selector of ['meta[name="description"]','meta[property="og:description"]','meta[name="twitter:description"]'])document.querySelector(selector)?.setAttribute('content',C('pageIntro'));
    for(const b of root.querySelectorAll('[data-v2-lesson]')){b.textContent=b.dataset.v2Lesson==='lessonCoordinator'?M('coordinatorLesson'):C(b.dataset.v2Lesson);b.setAttribute('aria-pressed',String(lesson===b.dataset.v2Lesson));}
    if(preferencesOpen&&dialog.open)renderPreferences();
    if(focusId)document.getElementById(focusId)?.focus({preventScroll:true});else if(nav)root.querySelector(`[data-v2-nav="${nav}"]`)?.focus({preventScroll:true});
    else if(focusText)[...(dialog.open?dialog:root).querySelectorAll('button')].find(b=>b.textContent===focusText)?.focus({preventScroll:true});
    if(shell.querySelector('.sim-content'))shell.querySelector('.sim-content').scrollTop=resetScroll===true?0:scroll;
  };
  Promise.all([fetchJSON('site-data/guide-v2-map.json'),fetchJSON('site-data/guide-v2-ui.json'),fetchJSON('site-data/guide-v2-copy.json'),fetchJSON('site-data/guide-demo.json'),fetchJSON('site-data/guide-vr-copy.json'),fetchJSON('site-data/guide-launcher-copy.json'),fetchJSON('site-data/guide-desktop-copy.json'),fetchJSON('site-data/guide-coordinator-notice.json'),fetchJSON('site-data/guide-coordinator-defaults.json')]).then(async([m,u,c,d,vrCopy,lc,dc,cn,cd])=>{
    map=m;ui=u;copy=c;demos=d;launcherCopy=lc;desktopCopy=dc;coordinatorNotice=cn;coordinatorDefaults=cd;root.replaceChildren();const intro=node('header','sim-intro');const title=node('h2');title.dataset.v2Title='';const lead=node('p');lead.dataset.v2Lead='';intro.append(title,lead);root.append(intro);
    const lessons=node('div','v2-lessons');for(const id of ['lessonFirst','lessonGraphics','lessonCoordinator','lessonStorage','lessonDiagnosis']){const b=btn('',()=>{lesson=id;if(id==='lessonFirst'){state=newState();state.ready=false;state.setup=0;surface='launcher';}else if(id==='lessonDiagnosis'){go('diagnostics');return;}else{surface='mac';view='steam';workspace=id==='lessonStorage'?'storage':'launch';if(id==='lessonCoordinator')state.coordinatorPrefs.details=true;}render();if(id==='lessonCoordinator')root.querySelector('#v2-coordinator-toggle')?.scrollIntoView({block:'center'});});b.dataset.v2Lesson=id;lessons.append(b);}const reset=btn('',()=>{if(dialog.open)dialog.close();state=newState();vrDemo.reset();surface='launcher';workspace='launch';view='steam';lesson='free';render();});reset.dataset.v2Reset='';lessons.append(reset);root.append(lessons);
    const expand=btn('',()=>{expandedWindow=!expandedWindow;applyWindowSize();if(expandedWindow)root.scrollTop=0;},'','window');expand.dataset.v2Expand='';lessons.append(expand);document.addEventListener('keydown',event=>{if(!expandedWindow||root.querySelector('dialog[open],:popover-open'))return;if(event.key==='Escape'){expandedWindow=false;applyWindowSize();expand.focus({preventScroll:true});}if(event.key==='Tab'){const focusable=[...root.querySelectorAll('button,a[href],input,select,textarea,[tabindex]')].filter(n=>!n.disabled&&n.tabIndex>=0&&n.getClientRects().length);const first=focusable[0],last=focusable.at(-1);if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}}});
    document.addEventListener('visibilitychange',()=>{root.classList.toggle('v2-document-hidden',document.hidden);if(document.hidden)mascotAnimation?.cancel();});
    document.addEventListener('forgeplay:themechange',()=>{if(state.theme==='system')render();});
    const visible=new IntersectionObserver(entries=>{const offscreen=!entries[0].isIntersecting;root.classList.toggle('v2-guide-offscreen',offscreen);if(offscreen)mascotAnimation?.cancel();});visible.observe(root);
    root.addEventListener('click',event=>{if(surface==='mac')swingMascot(event.clientX<innerWidth/2?-1:1);});
    matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change',event=>{if(event.matches)mascotAnimation?.cancel();});
    const notice=node('p','v2-safety');notice.dataset.v2Notice='';coach=node('p','v2-coach');coach.setAttribute('role','status');root.append(notice,coach);shell=node('div');root.append(shell);
    dialog=node('dialog','sim-dialog v2-dialog');dialog.setAttribute('aria-labelledby','v2-dialog-title');dialog.addEventListener('close',()=>{preferencesOpen=false;dialog.classList.remove('v2-preferences');if(focusBeforeDialog?.isConnected)focusBeforeDialog.focus();else (root.querySelector('[data-v2-reset]'))?.focus({preventScroll:true});});root.append(dialog);
    vrDemo=window.ForgePlayVRDemo.create({copy:vrCopy,locale,apps:()=>appCatalog?.apps||[],exit:target=>{surface=target==='desktop'?'mac':'launcher';if(target==='desktop'){view='steam';workspace='launch';}render(true);if(surface==='launcher')root.querySelector('[data-v2-tile="vr"]')?.focus({preventScroll:true});}});
    const hash=()=>{if(location.hash==='#app-vr'){surface='launcher';render(true);activateLauncherTile('vr');}else if(location.hash==='#app-awdl'){surface='mac';view='steam';render();openPreferences('input');}else render();};window.addEventListener('hashchange',hash);document.addEventListener('forgeplay:localechange',()=>{if(dialog.open&&!preferencesOpen)dialog.close();render();});hash();
    // Each optional public feed settles independently. Never delay the usable UI for it.
    void refreshCatalog();
    fetchJSON('site-data/developer-apps.json').then(data=>{appCatalog=data;if(surface==='utility'&&view==='apps')render();}).catch(()=>{});
    fetchJSON('site-data/announcements.json').then(data=>{notices=data;const news=shell.querySelector('.v2-launcher-news');if(news)renderNews(news);}).catch(()=>{});
    fetchJSON('site-data/supporters.json').then(data=>{if(data.schemaVersion!==1||!Array.isArray(data.names)||data.names.length>200||data.names.some(n=>typeof n!=='string'||!n.trim()||[...n].length>80))return;supporters=data.names;if(surface==='launcher')render();}).catch(()=>{});
    void loadLauncherBanners();
    window.addEventListener('pagehide',()=>{for(const url of remoteBanners.values())URL.revokeObjectURL(url);},{once:true});
  }).catch(()=>{root.replaceChildren(node('p','guide-error','Guide could not be loaded. Please reload.'));});
})();

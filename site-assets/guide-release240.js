(() => {
  'use strict';
  const rgb=h=>[1,3,5].map(i=>parseInt(h.slice(i,i+2),16));
  const hex=c=>'#'+c.map(v=>Math.round(v).toString(16).padStart(2,'0')).join('');
  const mix=(a,b,n)=>hex(rgb(a).map((v,i)=>v+(rgb(b)[i]-v)*n));
  const luminance=h=>rgb(h).map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
  const contrast=(a,b)=>(Math.max(luminance(a),luminance(b))+.05)/(Math.min(luminance(a),luminance(b))+.05);
  const readable=(value,surfaces,end,min)=>{for(let i=0;i<=100;i++){const c=mix(value,end,i/100);if(surfaces.every(s=>contrast(c,s)>=min))return c;}return end;};
  const colors=(style,dark)=>{
    const values=style.colors,seed=values.reduce((a,b)=>Math.max(...rgb(a))-Math.min(...rgb(a))>=Math.max(...rgb(b))-Math.min(...rgb(b))?a:b),sorted=[...values].sort((a,b)=>luminance(a)-luminance(b));
    const bg=dark?mix(seed,'#000000',.94):mix(sorted[3],'#ffffff',.6),surface=dark?mix(seed,'#000000',.87):mix(sorted[3],'#ffffff',.83),control=dark?mix(seed,'#000000',.79):mix(seed,'#ffffff',.91),end=dark?'#ffffff':'#000000',surfaces=[bg,surface,control];
    const accent=readable(seed,surfaces,end,4.5),ink=readable(dark?sorted[3]:sorted[0],surfaces,end,7);
    return {bg,surface,control,accent,ink,muted:readable(mix(ink,bg,.28),surfaces,end,4.5),border:readable(mix(accent,bg,.65),surfaces,end,3),onAccent:contrast('#000000',accent)>=contrast('#ffffff',accent)?'#000000':'#ffffff'};
  };
  const create=({root,dialog,data,locale,show,refresh,light,notice,example})=>{
    let palette=null,fopl=null,lupain=false,logging=true,logSize=64,modding='none';const urls=new Set();
    const t=k=>data.strings[k]?.[Math.max(0,data.locales.indexOf(locale()))]||k;
    const n=(tag,cls='',text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const button=(text,action,cls='')=>{const b=n('button',cls,text);b.type='button';b.addEventListener('click',action);return b;};
    const title=kind=>({styles:t('styles'),fopl:t('replaceFopl'),lupain:'Lupain 루팡',logs:t('logs'),modding:t('modding'),rdr2:t('rdr2'),components:t('manual')})[kind];
    const body=kind=>{for(const text of data.sections[kind]?.[locale()]||data.sections[kind]?.en||[])dialog.append(n('p','sim-note r240-copy',text.replaceAll('**','')));};
    const applyLook=()=>{
      if(palette){root.dataset.guidePalette=String(palette.id);for(const[k,v]of Object.entries(colors(palette,light()===false)))root.style.setProperty('--r240-'+k,v);}else delete root.dataset.guidePalette;
      const url=fopl?.url||(lupain?'site-assets/guide/lupain-240.png':null);
      if(url){root.dataset.guideFopl='true';root.style.setProperty('--r240-fopl','url("'+url+'")');root.style.setProperty('--r240-fopl-scale',String(fopl?.scale||1));root.style.setProperty('--r240-fopl-x',(fopl?.x||0)+'%');root.style.setProperty('--r240-fopl-y',(fopl?.y||0)+'%');}else delete root.dataset.guideFopl;
    };
    const reset=()=>{for(const u of urls)URL.revokeObjectURL(u);urls.clear();palette=fopl=null;lupain=false;logging=true;logSize=64;modding='none';applyLook();};
    const toggleLupain=()=>{lupain=!lupain;applyLook();refresh();};
    const styles=()=>{
      let selected=palette;const previews=n('div','r240-palette-previews'),search=n('input'),grid=n('div','r240-palette-grid');search.type='search';search.placeholder=t('search');search.setAttribute('aria-label',t('search'));
      const caption=n('p','sim-note');caption.setAttribute('role','status');
      const redraw=()=>{
        previews.replaceChildren();for(const dark of [false,true]){const s=selected||data.palettes[dark?92:10],c=colors(s,dark),card=n('div','r240-palette-card');card.style.background=c.bg;card.style.color=c.ink;card.style.borderColor=c.border;card.append(n('strong','',dark?'◐ '+t('dark'):'☀ '+t('light')));const row=n('div','r240-palette-sample');row.style.background=c.surface;row.append(n('strong','','ForgePlay · Steam'));const action=n('span','',t('apply'));action.style.background=c.accent;action.style.color=c.onAccent;row.append(action);card.append(row);previews.append(card);}
        caption.textContent=selected?selected.id+' · '+(locale()==='ko'?selected.ko:selected.name):t('resetColors');grid.replaceChildren();
        const query=search.value.trim().normalize('NFKC').toLowerCase();for(const s of data.palettes.filter(s=>[s.id,s.name,s.ko].join(' ').normalize('NFKC').toLowerCase().includes(query))){const b=button('',()=>{selected=s;redraw();grid.querySelector('[data-palette-id="'+s.id+'"]')?.focus({preventScroll:true});},'r240-palette-choice');b.dataset.paletteId=s.id;b.setAttribute('aria-pressed',String(selected?.id===s.id));b.setAttribute('aria-label',s.id+' · '+(locale()==='ko'?s.ko:s.name));const swatches=n('span','r240-swatches');for(const color of s.colors){const swatch=n('i');swatch.style.background=color;swatches.append(swatch);}b.append(swatches,n('strong','',s.id+' · '+(locale()==='ko'?s.ko:s.name)),n('small','',s.name));grid.append(b);}
      };search.addEventListener('input',redraw);dialog.append(previews,caption,search,grid);const actions=n('div','sim-actions');actions.append(button(t('resetColors'),()=>{selected=null;redraw();}),button(t('cancel'),()=>dialog.close()),button(t('apply'),()=>{palette=selected;applyLook();dialog.close();refresh();},'sim-primary'));dialog.append(actions);redraw();
    };
    const replaceFopl=()=>{
      let candidate=fopl?{...fopl}:null,img=null,generation=0;const preview=n('div','r240-fopl-editor'),picture=n('img');picture.alt=t('replaceFopl');preview.append(picture);const input=n('input');input.type='file';input.accept='image/png';input.setAttribute('aria-label','PNG · '+t('choose'));const error=n('p','sim-note');error.setAttribute('role','status');const apply=button(t('apply'),()=>{if(!visible()){error.textContent=t('invalidPNG');return;}if(fopl&&fopl.url!==candidate.url){URL.revokeObjectURL(fopl.url);urls.delete(fopl.url);}fopl={...candidate};applyLook();dialog.close();refresh();},'sim-primary');
      const visible=()=>{if(!candidate||!img||!img.complete||!img.naturalWidth)return false;const c=document.createElement('canvas');c.width=c.height=128;const x=c.getContext('2d'),scale=Math.min(128/img.naturalWidth,128/img.naturalHeight)*candidate.scale,w=img.naturalWidth*scale,h=img.naturalHeight*scale;x.drawImage(img,(128-w)/2+candidate.x*1.28,(128-h)/2+candidate.y*1.28,w,h);const pixels=x.getImageData(0,0,128,128).data;for(let i=3;i<pixels.length;i+=4)if(pixels[i]>0)return true;return false;};
      const update=()=>{picture.hidden=!candidate;if(candidate){picture.src=candidate.url;picture.style.transform=`translate(${candidate.x}%,${candidate.y}%) scale(${candidate.scale})`;}apply.disabled=!visible();};
      const load=url=>{const next=new Image();img=next;next.onload=()=>{if(img!==next||!dialog.open)return;error.textContent=visible()?'':t('invalidPNG');update();};next.onerror=()=>{if(img!==next||!dialog.open)return;error.textContent=t('invalidPNG');apply.disabled=true;};next.src=url;};
      input.addEventListener('change',async()=>{const file=input.files?.[0];if(!file)return;const request=++generation;const head=new Uint8Array(await file.slice(0,24).arrayBuffer()),sig=[137,80,78,71,13,10,26,10],view=new DataView(head.buffer);if(request!==generation||!dialog.open)return;if(file.size>16*1024*1024||head.length<24||sig.some((v,i)=>head[i]!==v)||view.getUint32(16)>2048||view.getUint32(20)>2048){error.textContent=t('invalidPNG');apply.disabled=true;return;}if(candidate&&candidate.url!==fopl?.url){URL.revokeObjectURL(candidate.url);urls.delete(candidate.url);}const url=URL.createObjectURL(file);urls.add(url);candidate={url,scale:1,x:0,y:0};load(url);});
      dialog.append(preview,input,error);for(const[key,min,max,step]of [['scale',.25,2,.05],['x',-75,75,1],['y',-75,75,1]]){const label=n('label','sim-field'),range=n('input');range.type='range';range.min=min;range.max=max;range.step=step;range.value=candidate?.[key]??(key==='scale'?1:0);range.setAttribute('aria-label',t(key));range.addEventListener('input',()=>{if(candidate){candidate[key]=Number(range.value);update();}});label.append(n('span','',t(key)),range);dialog.append(label);}
      const actions=n('div','sim-actions');actions.append(button(t('resetFopl'),()=>{if(fopl){URL.revokeObjectURL(fopl.url);urls.delete(fopl.url);}fopl=null;applyLook();dialog.close();refresh();}),button(t('cancel'),()=>dialog.close()),apply);dialog.append(actions);dialog.addEventListener('close',()=>{generation++;if(candidate&&candidate.url!==fopl?.url){URL.revokeObjectURL(candidate.url);urls.delete(candidate.url);}},{once:true});if(candidate)load(candidate.url);update();
    };
    const open=kind=>{
      show(title(kind),notice());dialog.classList.add('r240-dialog');body(kind);
      if(kind==='styles'){styles();return;}if(kind==='fopl'){replaceFopl();return;}
      if(kind==='lupain'){
        const img=n('img','r240-lupain');img.src='site-assets/guide/lupain-240.png';img.alt='Lupain';dialog.append(img);const control=button('',()=>{toggleLupain();sync();},'r240-toggle');const sync=()=>{control.textContent=t(lupain?'lupainOn':'lupainOff');control.setAttribute('aria-checked',String(lupain));};control.setAttribute('role','switch');control.setAttribute('aria-label',t('lupainToggle'));sync();dialog.append(control,n('p','sim-note',example()+' · '+notice()));
      }else if(kind==='logs'){
        const control=button(t('logging'),()=>{logging=!logging;control.setAttribute('aria-checked',String(logging));},'r240-toggle');control.setAttribute('role','switch');control.setAttribute('aria-checked',String(logging));dialog.append(control);const size=n('p','sim-note',example()+' · '+logSize+' MiB');dialog.append(size,button(t('cleanup'),()=>{logSize=24;size.textContent=example()+' · '+logSize+' MiB';}));
      }else if(kind==='modding'){
        const status=n('p','sim-note');const update=()=>{status.textContent=modding==='applied'?t('applied'):example()+' · '+(modding==='selected'?t('prepared'):t('unapplied'));apply.disabled=modding!=='selected';restore.disabled=modding!=='applied';};
        const choose=button('dinput8.dll · '+t('choose'),()=>{modding='selected';update();}),apply=button(t('apply'),()=>{modding='applied';update();}),restore=button(t('restore'),()=>{modding='none';update();});dialog.append(status,choose,apply,restore);update();
      }else if(kind==='rdr2'){
        const img=n('img','r240-screen');img.src='site-assets/announcements/forgeplay-2-4-0-rdr2-profile.png';img.alt=t('rdr2');dialog.append(img);
      }else if(kind==='components'){
        const state=n('p','sim-note',t('unverified'));dialog.append(state);for(const name of ['DirectX','VC++','.NET','OpenAL','XNA','PhysX'])dialog.append(button(name,()=>{state.textContent=example()+' · '+name+' · '+t('unverified');}));
      }
    };
    window.addEventListener('pagehide',reset,{once:true});
    return {t,open,applyLook,reset,toggleLupain,get lupain(){return lupain;},get foplURL(){return fopl?.url||null;}};
  };
  window.ForgePlayRelease240Demo=Object.freeze({create,colors});
})();

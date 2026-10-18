(() => {
  'use strict';
  // A presentation-only editor. It never captures or remaps real keyboard input.
  const initial = () => ({bindings:{},keyNameMode:'english'});
  const bind = (value,source,destination) => {
    const next={...value,bindings:{...value.bindings}};
    if(destination==='original'||destination===source)delete next.bindings[source];
    else if(destination!==63)next.bindings[source]=destination;
    return next;
  };
  const reset = value => ({bindings:{},keyNameMode:value.keyNameMode});
  const output = (value,source) => Object.hasOwn(value.bindings,source)?value.bindings[source]:source;
  const mount = ({parent,data,t,value,onSave,onCancel,onReset,notice}) => {
    let draft={...value,bindings:{...value.bindings}},selected=63,expanded=false;
    const all=[...data.rows.flat(),...data.additional],keys=new Map(all.map(k=>[k.code,k]));
    const sides={54:'Right ⌘',55:'Left ⌘',56:'Left ⇧',60:'Right ⇧',58:'Left ⌥',61:'Right ⌥',59:'Left ⌃',62:'Right ⌃'};
    const label=code=>sides[code]||keys.get(code)?.label||String(code);
    const n=(tag,cls='',text)=>{const e=document.createElement(tag);e.className=cls;if(text!==undefined)e.textContent=text;return e;};
    const button=(text,action,cls='')=>{const b=n('button',cls,text);b.type='button';b.addEventListener('click',action);return b;};
    const host=n('section','guide-keyboard');parent.append(host);
    const render=focus=>{
      const scroll=host.querySelector('.guide-keyboard-scroll')?.scrollLeft||0;
      host.replaceChildren();host.append(n('p','sim-note','Magic Keyboard · ANSI'),n('p','sim-note',t('summary')));if(notice)host.append(n('p','sim-note',notice));
      const viewport=n('div','guide-keyboard-scroll');viewport.tabIndex=0;viewport.setAttribute('role','region');viewport.setAttribute('aria-label',t('title'));
      const board=n('div','guide-keyboard-board');
      const keycap=k=>{
        const b=button('',()=>{selected=k.code;render('guide-key-'+selected);},'guide-key');b.id='guide-key-'+k.code;b.dataset.keyCode=k.code;b.style.setProperty('--key-width',k.width);
        b.setAttribute('aria-pressed',String(selected===k.code));b.setAttribute('aria-label',label(k.code));
        const destination=output(draft,k.code),changed=Object.hasOwn(draft.bindings,k.code);
        b.dataset.changed=String(changed);b.append(n('span','',k.label),n('small','',changed?(destination===null?'⊘':'→ '+label(destination)):'\u00a0'));
        b.setAttribute('aria-description',changed?(destination===null?t('disabled'):label(destination)):t('original'));
        return b;
      };
      for(const row of data.rows){const line=n('div','guide-keyboard-row');for(const k of row)line.append(keycap(k));board.append(line);}viewport.append(board);host.append(viewport);
      const extra=n('details','v2-disclosure');extra.open=expanded;extra.addEventListener('toggle',()=>{expanded=extra.open;});extra.append(n('summary','',t('extra')));
      const grid=n('div','guide-keyboard-extra');for(const k of data.additional)grid.append(keycap(k));extra.append(grid);host.append(extra);
      const fields=n('div','guide-keyboard-fields');
      const select=(title,id,options,current,change)=>{
        const row=n('label','sim-field'),s=n('select');s.id=id;s.setAttribute('aria-label',title);
        for(const[v,text]of options){const o=n('option','',text);o.value=v;o.selected=String(v)===String(current);s.append(o);}
        s.addEventListener('change',()=>{change(s.value);render(id);});row.append(n('span','',title),s);fields.append(row);
      };
      const current=Object.hasOwn(draft.bindings,selected)?(draft.bindings[selected]===null?'disabled':draft.bindings[selected]):'original';
      select(t('action')+' · '+label(selected),'guide-key-action',[
        ['original',t('original')],['disabled',t('disabled')],...all.filter(k=>k.code!==63&&k.code!==selected).map(k=>[k.code,label(k.code)])
      ],current,v=>{draft=bind(draft,selected,v==='original'?v:v==='disabled'?null:Number(v));});
      select(t('keyNames'),'guide-key-names',[['english',t('english')],['layout',t('inputLanguage')]],draft.keyNameMode,v=>{draft.keyNameMode=v;});
      host.append(fields);
      const destination=output(draft,selected),result=n('output','guide-keyboard-result');result.setAttribute('aria-live','polite');result.textContent=t('output')+': '+label(selected)+' → '+(destination===null?t('disabled'):label(destination));host.append(result);
      host.append(n('p','sim-note',t('count').replace('%d',Object.keys(draft.bindings).length)),n('p','sim-note',t('actionHelp')),n('p','sim-note',t('restart')));
      const help=n('details','v2-disclosure');help.append(n('summary','',t('keyNames')+' · '+t('extra')));for(const key of ['namesHelp','fnHelp','scope','resetHelp'])help.append(n('p','sim-note',t(key)));host.append(help);
      const actions=n('div','sim-actions');actions.append(button(t('reset'),()=>{draft=reset(draft);onReset({...draft,bindings:{}});render('guide-key-reset');}),button(t('cancel'),onCancel),button(t('save'),()=>onSave({...draft,bindings:{...draft.bindings}}),'sim-primary'));
      actions.firstChild.id='guide-key-reset';host.append(actions);
      viewport.scrollLeft=scroll;if(focus)host.querySelector('#'+focus)?.focus({preventScroll:true});
    };
    render();return host;
  };
  window.ForgePlayKeyboardDemo=Object.freeze({initial,bind,reset,output,mount});
})();

(() => {
  'use strict';
  // First-party, code-native web icons. No Apple symbol/font files are shipped.
  const ns='http://www.w3.org/2000/svg';
  const s=(name,attrs={},...children)=>{const e=document.createElementNS(ns,name);for(const[k,v]of Object.entries(attrs))e.setAttribute(k,String(v));e.append(...children);return e;};
  const path=(d,attrs={})=>s('path',{d,...attrs});
  const rect=(x,y,width,height,rx=2,attrs={})=>s('rect',{x,y,width,height,rx,...attrs});
  const circle=(cx,cy,r,attrs={})=>s('circle',{cx,cy,r,...attrs});
  const line=d=>path(d);
  const solid={fill:'currentColor',stroke:'none'};
  const drawings={
    bulb:()=>[path('M8 16c0-3-3-3-3-7a7 7 0 0 1 14 0c0 4-3 4-3 7Z',solid),line('M8 19h8m-6 3h4')],
    thumb:()=>[path('M3 11h4v10H3Zm6 10V10l3-7h3v7h5c2 0 1 4 0 7l-1 4Z',solid)],
    pulse:()=>[line('M2 12h5l3-9 4 18 3-9h5')],
    vision:()=>[path('M4 7c3-3 13-3 16 0 3 3 2 10-1 10-2 0-4-3-7-3s-5 3-7 3C2 17 1 10 4 7Z')],
    visionFill:()=>[path('M4 7c3-3 13-3 16 0 3 3 2 10-1 10-2 0-4-3-7-3s-5 3-7 3C2 17 1 10 4 7Z',solid)],
    layers:()=>[path('m3 7 9-5 9 5-9 5Z'),line('m3 12 9 5 9-5M3 17l9 5 9-5')],
    hand:()=>[path('M8 12V5a1.5 1.5 0 0 1 3 0v6-8a1.5 1.5 0 0 1 3 0v8-6a1.5 1.5 0 0 1 3 0v7-4a1.5 1.5 0 0 1 3 0v7c0 5-3 7-6 7h-2c-3 0-4-2-6-5l-3-4c-1-2 1-3 2-2l3 3')],
    power:()=>[line('M12 2v10'),path('M7 5a9 9 0 1 0 10 0')],
    play:()=>[path('M8 5.5 19 12 8 18.5Z',solid)],
    playCircle:()=>[circle(12,12,9,solid),path('M10 7.5 16.5 12 10 16.5Z',{fill:'var(--sim-bg, #211710)',stroke:'none'})],
    controller:()=>[path('M7 6.5h10c3 0 4.2 3 4.5 7.5.3 4.3-1.1 5-3.2 3l-2-2H7.7l-2 2c-2.1 2-3.5 1.3-3.2-3C2.8 9.5 4 6.5 7 6.5Z'),line('M6 9v5m-2.5-2.5h5'),circle(16,10.3,.85,solid),circle(19,12.9,.85,solid)],
    terminal:()=>[rect(2,4,20,16,3),line('m6 8 4 4-4 4m7 0h5')],
    grid:()=>[rect(3,3,7,7,1.6),rect(14,3,7,7,1.6),rect(3,14,7,7,1.6),rect(14,14,7,7,1.6)],
    launcher:()=>Array.from({length:9},(_,i)=>rect(3+(i%3)*7,3+Math.floor(i/3)*7,4,4,1,solid)),
    book:()=>[path('M5 3h14v18H6a3 3 0 0 1-3-3V6a3 3 0 0 1 2-3Z'),line('M6 3v14h13M6 17a2 2 0 0 0 0 4m3-13h7m-7 4h5')],
    gear:()=>[path('m10 2-.7 3-2 .9-2.8-1.3L2 8l2.3 2v3L2 15l2.5 3.5 2.8-1.3 2 .9.7 3.9h4l.7-3.9 2-.9 2.8 1.3L22 15l-2.3-2v-3L22 8l-2.5-3.4L16.7 6l-2-.9-.7-3.1Z'),circle(12,12,3.1)],
    sliders:()=>[line('M4 5h16M4 12h16M4 19h16'),circle(8,5,2.2,{fill:'var(--sim-panel, #25211d)'}),circle(16,12,2.2,{fill:'var(--sim-panel, #25211d)'}),circle(10,19,2.2,{fill:'var(--sim-panel, #25211d)'})],
    display:()=>[rect(2,3,20,14,2.2),line('M9 17v4m6-4v4m-8 0h10')],
    drive:()=>[rect(3,4,18,16,3),line('M3 14h18'),circle(17,17,1,solid),line('M6 17h6')],
    folder:()=>[path('M3 6h7l2 2h9v11H3Z'),line('M3 10h18')],
    folderPlus:()=>[path('M3 6h7l2 2h9v11H3Z'),line('M12 11v6m-3-3h6')],
    download:()=>[line('M12 3v12m-4-4 4 4 4-4M3 16v5h18v-5')],
    save:()=>[path('M4 3h13l4 4v14H3V3Z'),rect(7,3,9,6,0),rect(7,14,10,7,0)],
    stop:()=>[circle(12,12,9),rect(8,8,8,8,1,solid)],
    info:()=>[circle(12,12,9),circle(12,7,1,solid),line('M11 11h1v6m-2 0h4')],
    help:()=>[circle(12,12,9),path('M9 8a3 3 0 0 1 6 0c0 2.2-3 2.2-3 4.6'),circle(12,17,.85,solid)],
    check:()=>[line('m5 12 4.5 4.5L20 6')],
    checkCircle:()=>[circle(12,12,9),line('m7.5 12 3 3 6-6')],
    warning:()=>[path('M12 3 22 21H2Z'),line('M12 9v5'),circle(12,17,.8,solid)],
    close:()=>[line('m6 6 12 12M18 6 6 18')],
    chevron:()=>[line('m9 5 7 7-7 7')],
    refresh:()=>[path('M20 9a8 8 0 1 0 0 6'),line('M20 3v6h-6')],
    puzzle:()=>[path('M4 4h5V2a3 3 0 0 1 6 0v2h5v5h-2a3 3 0 0 0 0 6h2v5h-5v-2a3 3 0 0 0-6 0v2H4v-5h2a3 3 0 0 0 0-6H4Z')],
    chip:()=>[rect(6,6,12,12,2),rect(9,9,6,6,1),line('M8 2v4m4-4v4m4-4v4M8 18v4m4-4v4m4-4v4M2 8h4m-4 4h4m-4 4h4m12-8h4m-4 4h4m-4 4h4')],
    frames:()=>[rect(3,3,13,13,2),rect(8,8,13,13,2,{fill:'var(--sim-panel, #25211d)'}),line('m12 12 5 3-5 3Z')],
    sparkle:()=>[path('m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5Z')],
    network:()=>[rect(9,2,6,5,1),rect(2,17,6,5,1),rect(16,17,6,5,1),line('M12 7v5M5 17v-5h14v5')],
    wifi:()=>[path('M3 8a14 14 0 0 1 18 0M6 12a9 9 0 0 1 12 0m-9 4a4.5 4.5 0 0 1 6 0'),circle(12,20,.9,solid)],
    mic:()=>[rect(9,2,6,13,3),path('M5 10v2a7 7 0 0 0 14 0v-2'),line('M12 19v3m-4 0h8')],
    memory:()=>[rect(2,6,20,12,1),rect(5,9,5,5,0),rect(14,9,5,5,0),line('M5 18v3m4-3v3m6-3v3m4-3v3')],
    keyboard:()=>[rect(2,5,20,14,2),...[[5,8],[9,8],[13,8],[17,8],[5,12],[9,12],[13,12],[17,12]].map(([x,y])=>line(`M${x} ${y}h1`)),line('M7 16h10')],
    shield:()=>[path('M12 2 21 6v6c0 5-5 8-9 10-4-2-9-5-9-10V6Z'),line('m7 12 3 3 7-7')],
    pointer:()=>[path('M5 2v18l5-5 4 7 4-2-4-7 7-1Z')],
    chart:()=>[rect(2,3,20,18,2),line('M6 17v-4m4 4V7m4 10v-7m4 7V5')],
    diagnostics:()=>[rect(2,4,20,16,2),line('M4 12h4l2-5 4 10 2-5h4')],
    logs:()=>[path('M5 2h10l4 4v16H5Z'),line('M14 2v5h5M8 11h8m-8 4h8m-8 4h5')],
    trash:()=>[line('M3 5h18M9 2h6m-8 3 1 17h8l1-17M10 9v9m4-9v9')],
    chat:()=>[path('M3 3h18v14H9l-6 5Z'),line('M7 7h10M7 11h7')],
    send:()=>[path('M2 3 22 12 2 21l4-9Z'),line('M6 12h16')],
    lock:()=>[rect(5,10,14,12,2),path('M8 10V6a4 4 0 0 1 8 0v4'),circle(12,16,1,solid)],
    key:()=>[circle(7.5,8,4.5),line('m11 11 10 10m-4-4 2-2m-5-1 2-2')],
    checklist:()=>[line('m3 5 1.5 1.5L7 3m-4 9 1.5 1.5L7 10m-4 9 1.5 1.5L7 17M11 5h10m-10 7h10m-10 7h10')],
    list:()=>[rect(2,3,20,18,2),line('M5 7h1m3 0h10M5 12h1m3 0h10M5 17h1m3 0h10')],
    person:()=>[circle(12,7,4),path('M4 22v-3a8 8 0 0 1 16 0v3')],
    heart:()=>[path('M12 21 3 12C-3 4 7-2 12 5c5-7 15-1 9 7Z')],
    pause:()=>[rect(6,4,4,16,1,solid),rect(14,4,4,16,1,solid)],
    search:()=>[circle(10,10,7),line('m15 15 7 7')],
    link:()=>[path('m10 7 3-3a5 5 0 0 1 7 7l-3 3m-3 3-3 3a5 5 0 0 1-7-7l3-3'),line('m8 16 8-8')],
    arrow:()=>[line('M3 12h18m-6-6 6 6-6 6')],
    eye:()=>[path('M1 12Q12-3 23 12 12 27 1 12Z'),circle(12,12,3)],
    circle:()=>[circle(12,12,9)],
    window:()=>[rect(2,3,20,18,2),line('M2 8h20M6 5.5h.1m3 0h.1')],
    globe:()=>[circle(12,12,9),path('M12 3c-7 5-7 13 0 18 7-5 7-13 0-18Z'),line('M3 12h18')],
    palette:()=>[path('M12 2a10 10 0 1 0 1 20c2 0 2-2 .5-3.5-1-1-.5-2.5 1-2.5H18c6-4 3-14-6-14Z'),circle(7,7,1,solid),circle(12,5,1,solid),circle(17,8,1,solid),circle(5,12,1,solid)],
    checkCircleFill:()=>[circle(12,12,9,solid),path('m7.5 12 3 3 6-6',{stroke:'var(--sim-panel, #212326)',fill:'none','stroke-width':2})],
    terminalFill:()=>[rect(2,4,20,16,3,solid),path('m6 8 4 4-4 4m7 0h5',{stroke:'var(--sim-sidebar, #1a1c1f)',fill:'none'})],
    bookFill:()=>[path('M6 2h14v20H6a3 3 0 0 1-3-3V5a3 3 0 0 1 3-3Z',solid),path('M7 3v15h12M7 18a2 2 0 0 0 0 4',{stroke:'var(--sim-sidebar, #1a1c1f)',fill:'none','stroke-width':1.4})],
    controllerFill:()=>[path('M7 6h10c3 0 4.2 3 4.5 7.5.3 4.3-1.1 5-3.2 3l-2-2H7.7l-2 2c-2.1 2-3.5 1.3-3.2-3C2.8 9 4 6 7 6Z',solid),path('M6.5 8.5v5m-2.5-2.5h5',{stroke:'var(--sim-sidebar, #1a1c1f)',fill:'none'}),circle(16,9.8,.9,{fill:'var(--sim-sidebar, #1a1c1f)',stroke:'none'}),circle(19,12.4,.9,{fill:'var(--sim-sidebar, #1a1c1f)',stroke:'none'})]
  };
  const icon=(name,size=20)=>{if(!drawings[name])throw Error('Unknown guide icon: '+name);return s('svg',{viewBox:'0 0 24 24',width:size,height:size,fill:'none',stroke:'currentColor','stroke-width':1.65,'stroke-linecap':'round','stroke-linejoin':'round','aria-hidden':'true',focusable:'false',class:'v2-symbol','data-icon':name},...drawings[name]());};
  let sequence=0;
  // These contours are a direct SVG port of the author's LauncherTileArtwork.swift,
  // not approximations of the previous demo's Unicode glyphs or SF Symbols.
  const launcher=tile=>{
    const colors={mac:'#c74d2b',vr:'#2e82b8',retro:'#82593d',catalog:'#c2781f',like:'#d9632e',sponsor:'#bf4a3b',updates:'#4d8c70',diagnostics:'#705fa8',apps:'#527da1'};
    const ink=colors[tile];if(!ink)throw Error('Unknown launcher tile');
    const id='guide-metal-'+(++sequence),screen=id+'-screen';
    const gradient=(name,stops)=>s('linearGradient',{id:name,x1:'20%',y1:'15%',x2:'75%',y2:'95%'},...stops.map(([offset,color])=>s('stop',{offset,'stop-color':color})));
    const svg=s('svg',{viewBox:'0 0 100 100',width:82,height:82,'aria-hidden':'true',focusable:'false',class:'v2-launcher-symbol','data-tile-art':tile});
    svg.append(s('defs',{},gradient(id,[['0%','#ffffff'],['45%','#ffebc7'],['100%',ink]]),gradient(screen,[['0%',ink],['100%','#101011']])));
    const metal=(tag,attrs)=>s(tag,{...attrs,fill:`url(#${id})`,stroke:'#ffffffcc','stroke-width':1.2,class:'v2-metal-contour'});
    const panel=(x,y,w,h,r=6)=>metal('rect',{x,y,width:w,height:h,rx:r});
    const p=d=>metal('path',{d});
    const l=(d,color=ink,width=3)=>path(d,{fill:'none',stroke:color,'stroke-width':width,'stroke-linecap':'round','stroke-linejoin':'round'});
    const dot=(x,y,r,color=ink)=>circle(x,y,r,{fill:color});
    if(tile==='mac')svg.append(p('M43 63H57L60 84 72 89H28L40 84Z'),panel(9,14,82,57),rect(14,19,72,43,3,{fill:`url(#${screen})`}),l('M19 23H77','#ffffff88',2),dot(50,66.5,1.8));
    if(tile==='vr')svg.append(p('M16 30C29 16 70 16 84 30C96 40 94 71 83 75C75 84 67 83 60 70Q50 60 40 70C31 82 22 83 17 75C5 73 4 42 16 30Z'),rect(18,32,64,34,13,{fill:`url(#${screen})`}),l('M27 38 65 35','#61d9f2',3),l('M7 41 4 48 5 61','#ffebc7',4),l('M93 41 96 48 95 61','#ffebc7',4));
    if(tile==='retro')svg.append(p('M25 30Q50 19 75 30C91 31 95 60 96 72C95 98 77 87 72 72H28C21 91 4 96 4 72C6 50 9 31 25 30Z'),l('M21 49H39M30 40V58',ink,7),...[ [72,41],[82,51],[62,51],[72,61] ].map(([x,y])=>dot(x,y,3)),l('M45 40H55',ink,2));
    if(tile==='catalog')svg.append(p('M15 21 43 17 50 22 57 17 85 21V81L57 77 50 82 43 77 15 81Z'),l('M50 25V73',ink,2),...[33,43,53,63].map(y=>l(`M23 ${y} 39 ${y-2}`,ink,2)),dot(74,58,19),l('M63 58 71 65 85 49','white',4));
    if(tile==='like')svg.append(panel(10,48,18,37,3),p('M33 48 43 39 48 14 57 12 63 20 61 42H82L91 49 82 82 70 87 33 82Z'),l('M39 74 70 79 78 77','#ffffff99',2));
    if(tile==='sponsor')svg.append(p('M50 85C37 70 6 56 12 35C14 9 41 10 50 28C59 10 86 9 88 35C94 56 63 70 50 85Z'),l('M21 35 27 26 34 24','#ffffffb3',3));
    if(tile==='updates')svg.append(l('M75.1 64.5A29 29 0 0 1 22.1 58M24.9 35.5A29 29 0 0 1 77.9 42',`url(#${id})`,9),p('M10 48 16 68 35 59Z'),p('M90 52 84 32 65 41Z'));
    if(tile==='diagnostics')svg.append(panel(11,19,78,63),rect(16,25,68,49,3,{fill:ink}),l('M20 54H33L40 36 50 66 59 44 66 54H80','white',3),dot(72.5,31.5,2.5,'cyan'));
    if(tile==='apps')for(const[x,y]of [[13,14],[54,14],[13,55],[54,55]])svg.append(panel(x,y,31,31,7),l(`M${x+6} ${y+7}H${x+23}`,'#ffffffcc',2));
    svg.style.setProperty('--tile-ink',ink);return svg;
  };
  // Normalized, static counterpart of the first-party LauncherFoplBackdrop Canvas.
  const backdrop=scene=>{
    const svg=s('svg',{viewBox:'0 0 100 100',preserveAspectRatio:'none','aria-hidden':'true',class:'v2-launcher-scene'});
    const floor=scene==='portal'?73:['journey','arcade'].includes(scene)?77:56;
    const panel=(x,y,w,h,kind='wall')=>svg.append(rect(x,y,w,h,2,{class:'v2-scene-'+kind}));
    const stroke=(d,kind='edge')=>svg.append(path(d,{class:'v2-scene-'+kind,fill:'none','stroke-width':.6}));
    const poly=(d,kind='wall')=>svg.append(path(d,{class:'v2-scene-'+kind}));
    panel(28,7,68,floor-7,'wash');panel(0,floor,100,100-floor,'wash');
    for(const x of [0,25,50,75,100])stroke('M'+(58+(x-50)*.28)+' '+floor+'L'+x+' 100');
    for(const t of [.12,.36,.72])stroke('M0 '+(floor+(100-floor)*t)+'H100');
    const cabinets=(start,count,step,height)=>{for(let i=0;i<count;i++){const x=start+i*step,top=floor-height-(i%2?0:3);panel(x,top,step*.8,floor-top);panel(x+step*.09,top+3.5,step*.62,height*.43,'lit');stroke('M'+x+' '+(top+height*.62)+'h'+step*.8);}};
    if(['mac','diagnostics','updates'].includes(scene)){panel(36,15,24,23);panel(39,18,18,13,'lit');panel(78,12,18,25);panel(32,46,64,3.5,'lit');stroke('M42 39h6v7M86 40v6M37 50v6');}
    else if(['retro','console','arcade'].includes(scene))cabinets(scene==='arcade'?42:34,scene==='arcade'?4:3,scene==='arcade'?16:22,scene==='arcade'?50:32);
    else if(['catalog','license'].includes(scene)){for(let r=0;r<2;r++){const y=13+r*20;for(let b=0;b<7;b++){const h=b%3?14:10;panel(36+b*7.8,y+15-h,4.5,h,b%2?'lit':'wall');}panel(33,y+15,62,1.8,'edge-fill');}}
    else if(['like','sponsor'].includes(scene)){stroke('M30 15 49 22 73 18 98 10');for(const[x,y]of [[39,18],[57,20.5],[83,14.5]])poly('M'+x+' '+y+'l7 -1.4 -2.5 8.9Z','lit');panel(38,43,52,10);panel(45,40,40,4,'lit');}
    else if(scene==='vr'){svg.append(s('ellipse',{cx:66,cy:29,rx:28,ry:20,class:'v2-scene-lit-stroke',fill:'none'}));stroke('M32 42 50 35 70 39 95 26M34 48 58 41 95 47');}
    else if(scene==='portal'){for(const n of [6,16,26])stroke('M'+n+' 73V'+(9+n*.22+18)+'Q'+n+' '+(9+n*.22)+' 50 '+(9+n*.22)+'Q'+(100-n)+' '+(9+n*.22)+' '+(100-n)+' '+(27+n*.22)+'V73');stroke('M10 73V18h7M90 73V18h-7','lit-stroke');}
    else if(scene==='journey'){poly('M25 77 42 32 56 58 74 18 100 52V77Z');poly('M35 77 60 47 70 64 88 40 100 65V77Z','lit');stroke('M35 87 57 71 52 65 66 54');}
    svg.append(s('ellipse',{cx:scene==='portal'?50:70,cy:scene==='portal'?73:['arcade','journey'].includes(scene)?90:59,rx:scene==='portal'?44:28,ry:2.8,class:'v2-scene-lit'}));
    return svg;
  };
  window.ForgePlayGuideIcons=Object.freeze({icon,launcher,backdrop});
})();

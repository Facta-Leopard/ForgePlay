(() => {
  "use strict";
  const chapters = [
    {id:"setup", points:[{pin:[23,76],rect:[1.5,73.8,22,5.5]},{pin:[94,29],rect:[27.2,23.5,68.6,21]},{pin:[94,69],rect:[27.2,47.5,68.6,44]}]},
    {id:"steam", points:[{pin:[94,55.7],rect:[28.8,51.8,65.4,7.8]},{pin:[94,71.7],rect:[28.8,60.7,65.4,14.8]},{pin:[44,35.8],rect:[28.8,32.5,30.3,7]}]},
    {id:"profiles", points:[{pin:[23,23],rect:[1.5,20.5,22,5.3]},{pin:[94,61.5],rect:[28.5,58,65.5,9]},{pin:[94,73],rect:[28.5,69.5,65.5,13.5]}]}
  ];
  const page = document.body.dataset.page === "guide";
  let dictionary;
  let currentChapter = 0;
  let currentPoint = 0;
  let lastFocus;
  const locale = () => window.ForgePlaySite?.getLocale() || document.documentElement.lang || "en";
  const copy = () => dictionary[locale()] || dictionary.en;
  const create = (tag, className, text) => {
    const node=document.createElement(tag);
    if(className) node.className=className;
    if(text!==undefined) node.textContent=text;
    return node;
  };
  const image = document.querySelector("#guide-screen");
  const dialog = document.querySelector("[data-guide-dialog]");
  const updatePoint = (index) => {
    currentPoint=index;
    document.querySelectorAll(".guide-pin").forEach((button,i)=>button.setAttribute("aria-pressed",String(i===index)));
    document.querySelectorAll(".guide-point").forEach((button,i)=>button.setAttribute("aria-expanded",String(i===index)));
    document.querySelectorAll(".guide-point-copy").forEach((body,i)=>{body.hidden=i!==index;});
    const rect=chapters[currentChapter].points[index].rect;
    const highlight=document.querySelector(".guide-highlight");
    ["left","top","width","height"].forEach((key,i)=>{highlight.style[key]=`${rect[i]}%`;});
  };
  const renderChapter = () => {
    const c=copy().chapters[currentChapter];
    const model=chapters[currentChapter];
    document.querySelectorAll("[role=tab][data-chapter]").forEach((button,i)=>{
      button.setAttribute("aria-selected",String(i===currentChapter));
      button.tabIndex=i===currentChapter?0:-1;
    });
    const panel=document.querySelector("#guide-panel");
    panel.setAttribute("aria-labelledby",`guide-tab-${model.id}`);
    image.src=`site-assets/guide/screens/${locale()}/${model.id}.jpg`;
    image.alt=`ForgePlay — ${c.name}`;
    document.querySelector("[data-guide-count]").textContent=String(currentChapter+1).padStart(2,"0");
    document.querySelector("[data-guide-chapter-title]").textContent=c.title;
    const list=document.querySelector("[data-guide-points]");
    const pins=document.querySelector("[data-guide-pins]");
    list.replaceChildren(); pins.replaceChildren();
    c.points.forEach(([title,body],i)=>{
      const item=create("li");
      const button=create("button","guide-point");button.type="button";
      button.append(create("span","",String(i+1)),create("span","",title));
      button.setAttribute("aria-controls",`guide-point-${i}`);
      button.addEventListener("click",()=>updatePoint(i));
      const paragraph=create("p","guide-point-copy",body); paragraph.id=`guide-point-${i}`;
      item.append(button,paragraph);list.append(item);
      const pin=create("button","guide-pin",String(i+1));pin.type="button";
      pin.style.left=`${model.points[i].pin[0]}%`;pin.style.top=`${model.points[i].pin[1]}%`;
      pin.setAttribute("aria-label",`${i+1}. ${title}`);pin.setAttribute("aria-controls",paragraph.id);
      pin.addEventListener("click",()=>updatePoint(i));pins.append(pin);
    });
    document.querySelector("[data-guide-prev]").disabled=currentChapter===0;
    document.querySelector("[data-guide-next]").disabled=currentChapter===chapters.length-1;
    updatePoint(currentPoint);
  };
  const changeChapter = (index,focus=false) => {
    currentChapter=index;currentPoint=0;renderChapter();
    if(focus) document.querySelectorAll("[role=tab][data-chapter]")[index].focus();
  };
  const render = () => {
    if(!dictionary)return;
    const text=copy();
    document.querySelectorAll("[data-guide-text]").forEach(node=>{const value=text[node.dataset.guideText];if(typeof value==="string")node.textContent=value;});
    document.querySelectorAll("[data-guide-image-link]").forEach(node=>node.setAttribute("aria-label",text.teaserLink));
    document.querySelectorAll("[data-guide-teaser-image]").forEach(node=>{node.alt=`ForgePlay — ${text.chapters[1].name}`;node.src=`site-assets/guide/screens/${locale()}/steam.jpg`;});
    if(!page)return;
    document.title=`ForgePlay — ${text.nav}`;
    document.querySelector('meta[name="description"]').content=text.intro;
    document.querySelector("[data-guide-nav]").setAttribute("aria-current","page");
    document.querySelector("[data-guide-tabs]").setAttribute("aria-label",text.walkthrough);
    const tabs=document.querySelector("[data-guide-tabs]");tabs.replaceChildren();
    text.chapters.forEach((c,i)=>{
      const tab=create("button");tab.type="button";tab.id=`guide-tab-${chapters[i].id}`;tab.dataset.chapter=chapters[i].id;
      tab.setAttribute("role","tab");tab.setAttribute("aria-controls","guide-panel");
      tab.append(create("span","",String(i+1).padStart(2,"0")),create("span","",c.name));
      tab.addEventListener("click",()=>changeChapter(i));
      tab.addEventListener("keydown",event=>{
        let target;
        if(event.key==="ArrowRight")target=(i+1)%chapters.length;
        if(event.key==="ArrowLeft")target=(i+chapters.length-1)%chapters.length;
        if(event.key==="Home")target=0;
        if(event.key==="End")target=chapters.length-1;
        if(target!==undefined){event.preventDefault();changeChapter(target,true);}
      });tabs.append(tab);
    });
    const faq=document.querySelector("[data-guide-faq]");
    const openStates=[...faq.children].map(item=>item.open);faq.replaceChildren();
    text.faq.forEach(([question,answer],i)=>{const item=create("details");item.open=Boolean(openStates[i]);item.append(create("summary","",question),create("p","",answer));faq.append(item);});
    renderChapter();
    if(dialog.open){document.querySelector("[data-guide-dialog-title]").textContent=text.chapters[currentChapter].name;document.querySelector("[data-guide-dialog-image]").alt=image.alt;}
  };
  if(page){
    document.querySelector("[data-guide-prev]").addEventListener("click",()=>changeChapter(Math.max(0,currentChapter-1)));
    document.querySelector("[data-guide-next]").addEventListener("click",()=>changeChapter(Math.min(chapters.length-1,currentChapter+1)));
    document.querySelector("[data-guide-zoom]").addEventListener("click",()=>{
      if(!dictionary)return;
      lastFocus=document.activeElement;
      document.querySelector("[data-guide-dialog-title]").textContent=copy().chapters[currentChapter].name;
      const target=document.querySelector("[data-guide-dialog-image]");target.src=image.src;target.alt=image.alt;
      dialog.showModal();
    });
    document.querySelector("[data-guide-close]").addEventListener("click",()=>dialog.close());
    dialog.addEventListener("click",event=>{if(event.target===dialog){const r=dialog.getBoundingClientRect();if(event.clientX<r.left||event.clientX>r.right||event.clientY<r.top||event.clientY>r.bottom)dialog.close();}});
    dialog.addEventListener("close",()=>lastFocus?.focus());
  }
  document.addEventListener("forgeplay:localechange",render);
  fetch("site-data/guide.json",{cache:"no-store"}).then(response=>{if(!response.ok)throw Error(response.status);return response.json();}).then(data=>{dictionary=data;render();}).catch(()=>{
    const error=document.querySelector("[data-guide-error]");
    if(error){
      const errors={ko:"사용 가이드를 불러오지 못했습니다. 페이지를 새로고침해 주세요.",en:"Could not load the guide. Please reload the page.",de:"Die Anleitung konnte nicht geladen werden. Bitte laden Sie die Seite neu.",es:"No se pudo cargar la guía. Vuelve a cargar la página.",fr:"Impossible de charger le guide. Rechargez la page.",ja:"ガイドを読み込めませんでした。ページを再読み込みしてください。","zh-Hans":"无法加载指南，请刷新页面。","zh-Hant":"無法載入指南，請重新整理頁面。"};
      error.hidden=false;error.textContent=errors[locale()]||errors.en;
    }
  });
})();

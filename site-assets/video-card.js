(() => {
  'use strict';
  // Only a click creates the third-party player. No video files or remote thumbnails are hosted.
  const locales=['ko','en','de','es','fr','ja','zh-Hans','zh-Hant'];
  const copy={
    play:['시연 영상 재생','Play demo','Demo abspielen','Reproducir demostración','Lire la démonstration','デモ動画を再生','播放演示','播放示範'],
    youtube:['YouTube에서 보기','Watch on YouTube','Auf YouTube ansehen','Ver en YouTube','Voir sur YouTube','YouTubeで見る','在 YouTube 观看','在 YouTube 觀看'],
    privacy:['재생을 누르면 YouTube 플레이어가 로드됩니다.','The YouTube player loads only when you press play.','Der YouTube-Player wird erst beim Abspielen geladen.','El reproductor de YouTube se carga al pulsar reproducir.','Le lecteur YouTube ne se charge que lorsque vous lancez la lecture.','再生を押すとYouTubeプレーヤーを読み込みます。','点击播放后才会加载 YouTube 播放器。','按下播放後才會載入 YouTube 播放器。']
  };
  const localeIndex=()=>Math.max(0,locales.indexOf(document.documentElement.lang));
  const element=(tag,className,text)=>{const node=document.createElement(tag);node.className=className;if(text)node.textContent=text;return node;};
  const label=(tag,key)=>{const node=element(tag,'',copy[key][localeIndex()]);node.dataset.videoText=key;return node;};
  const create=({youtubeId,title,poster})=>{
    if(!/^[A-Za-z0-9_-]{11}$/.test(youtubeId)||typeof title!=='string'||!title.trim()||!/^site-assets\/announcements\/[a-z0-9-]+\.(?:jpg|png)$/.test(poster))return null;
    const figure=element('figure','fp-video-card'),stage=element('div','fp-video-stage'),button=element('button','fp-video-play');
    button.type='button';
    const image=element('img','');image.src=poster;image.alt='';image.width=1280;image.height=720;image.loading='lazy';image.decoding='async';
    const overlay=element('span','fp-video-overlay'),icon=element('span','fp-video-play-icon','▶');icon.setAttribute('aria-hidden','true');
    overlay.append(icon,label('strong','play'),element('span','fp-video-title',title));button.append(image,overlay);
    button.addEventListener('click',()=>{
      const player=element('iframe','');player.title=title;player.allow='autoplay; encrypted-media; picture-in-picture; fullscreen';player.allowFullscreen=true;
      player.referrerPolicy='strict-origin-when-cross-origin';
      player.src='https://www.youtube-nocookie.com/embed/'+youtubeId+'?autoplay=1&rel=0';
      stage.replaceChildren(player);player.focus();
    },{once:true});
    stage.append(button);
    const caption=element('figcaption',''),link=label('a','youtube');link.href='https://www.youtube.com/watch?v='+youtubeId;link.target='_blank';link.rel='noopener noreferrer';
    caption.append(label('span','privacy'),link);figure.append(stage,caption);return figure;
  };
  window.ForgePlayVideo=Object.freeze({create});
  for(const host of document.querySelectorAll('[data-youtube-id]')){
    const card=create({youtubeId:host.dataset.youtubeId,title:host.dataset.videoTitle,poster:host.dataset.videoPoster});if(card)host.replaceChildren(card);
  }
  document.addEventListener('forgeplay:localechange',()=>{
    for(const node of document.querySelectorAll('[data-video-text]'))node.textContent=copy[node.dataset.videoText][localeIndex()];
  });
})();

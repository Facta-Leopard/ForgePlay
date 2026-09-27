(() => {
  "use strict";
  const copy = window.ForgePlaySupporterCopy;
  const state = { names: [], loading: true, failed: false, paused: false };
  const tracks = [...document.querySelectorAll('.ticker-track')];
  const pause = document.querySelector('#pause-ticker');
  const reduce = matchMedia('(prefers-reduced-motion: reduce)');
  const locale = () => window.ForgePlaySite?.getLocale() || document.documentElement.lang || 'en';
  const t = key => (copy[locale()] || copy.en)[key];
  const namesContainer = document.querySelector('#static-supporters');

  function motionState() {
    document.body.classList.toggle('is-paused', state.paused || reduce.matches);
    pause.setAttribute('aria-pressed', String(state.paused || reduce.matches));
    pause.querySelector('[data-pause-label]').textContent = t(reduce.matches ? 'reduced' : state.paused ? 'play' : 'pause');
    pause.querySelector('[data-pause-icon]').textContent = state.paused || reduce.matches ? '▷' : 'Ⅱ';
    pause.disabled = reduce.matches;
    if (reduce.matches) document.querySelector('.all-supporters').open = true;
  }
  function sizeTracks() {
    tracks.forEach(track => {
      [...track.children].forEach(group => { group.style.minWidth = `${track.parentElement.clientWidth}px`; });
      const width = track.firstElementChild?.getBoundingClientRect().width || 0;
      track.style.setProperty('--ticker-duration', `${Math.max(25, width / (track.classList.contains('launcher-track') ? 26 : 34))}s`);
    });
  }
  function render() {
    document.querySelectorAll('[data-credit]').forEach(el => { el.textContent = t(el.dataset.credit); });
    document.title = t('pageTitle');
    ['description','og:description','twitter:description'].forEach(key => {
      document.querySelector(`meta[name="${key}"],meta[property="${key}"]`)?.setAttribute('content', t('meta'));
    });
    ['og:title','twitter:title'].forEach(key => {
      document.querySelector(`meta[name="${key}"],meta[property="${key}"]`)?.setAttribute('content', t('pageTitle'));
    });
    document.querySelector('#data-status').textContent = t(state.loading ? 'loading' : state.failed ? 'failed' : state.names.length ? 'count' : 'empty').replace('{count}', String(state.names.length));
    document.querySelector('#ticker-accessible').textContent = `${t('thanks')}. ${state.names.join(', ')}`;
    namesContainer.replaceChildren();
    if (state.names.length) {
      const list = document.createElement('ul');
      state.names.forEach(name => { const li = document.createElement('li'); li.textContent = name; list.append(li); });
      namesContainer.append(list);
    } else {
      const note = document.createElement('p'); note.textContent = t(state.failed ? 'failed' : 'empty'); namesContainer.append(note);
    }
    tracks.forEach(track => {
      track.replaceChildren();
      const group = document.createElement('div'); group.className = 'ticker-group';
      [...state.names, t('thanks')].forEach((text,index) => {
        const item = document.createElement('span'); item.className = 'ticker-item' + (index === state.names.length ? ' thanks' : ''); item.textContent = text; group.append(item);
      });
      const duplicate = group.cloneNode(true); duplicate.setAttribute('aria-hidden','true');
      track.append(group,duplicate);
      track.getAnimations().forEach(animation => { animation.currentTime = 0; });
    });
    sizeTracks(); motionState();
  }
  pause.addEventListener('click', () => { state.paused = !state.paused; motionState(); });
  reduce.addEventListener('change', motionState);
  document.addEventListener('visibilitychange', () => document.body.classList.toggle('page-inactive', document.hidden));
  document.addEventListener('forgeplay:localechange', render);
  new ResizeObserver(sizeTracks).observe(document.querySelector('.recognition-board'));
  // Each ticker starts with the first CSV name when it first becomes visible.
  const observer = new IntersectionObserver(entries => entries.forEach(entry => {
    const track = entry.target.querySelector('.ticker-track');
    track.classList.toggle('offscreen', !entry.isIntersecting);
  }));
  document.querySelectorAll('.ticker-window').forEach(window => { window.querySelector('.ticker-track').classList.add('offscreen'); observer.observe(window); });
  render();
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  const url = new URL('site-data/supporters.json', document.baseURI);
  url.searchParams.set('refresh', String(Date.now()));
  fetch(url, { cache:'no-store', credentials:'omit', redirect:'error', signal:controller.signal })
    .then(async response => {
      if (!response.ok) throw new Error('Unavailable');
      const raw = await response.text();
      if (new TextEncoder().encode(raw).length > 128000) throw new Error('Too large');
      const data = JSON.parse(raw);
      if (data.schemaVersion !== 1 || Object.keys(data).sort().join(',') !== 'names,schemaVersion' || !Array.isArray(data.names) || data.names.length > 200 || data.names.some(name => typeof name !== 'string' || !name || name !== name.trim() || [...name].length > 80 || /[\p{Cc}\p{Cf}]/u.test(name)) || new Set(data.names.map(n => n.normalize('NFC'))).size !== data.names.length) throw new Error('Invalid names');
      state.names = data.names;
    })
    .catch(() => { state.failed = true; })
    .finally(() => { clearTimeout(timeout); state.loading = false; render(); });
})();

/* The Current Canvas — live news aggregator (no keys, no backend).
   Pulls public RSS feeds via the free rss2json API, falling back to a CORS proxy + XML parsing. */
(() => {
  'use strict';

  // OWN_ONLY: publish only content that stands on its own page here (original articles + data briefs
  // with plain-text credits). Stories that link out to another website as their source are hidden.
  const OWN_ONLY = true;
  const isOwn = (i) => i.kind === 'written' || (!!i.original && !i.creditUrl);
  const REFRESH_MS = 5 * 60 * 1000;
  const CACHE_KEY = 'tcc-cache-v1';
  const CACHE_MAX_AGE = 30 * 60 * 1000;

  // Section -> feeds. Add/replace URLs freely; any public RSS/Atom feed works.
  const SECTIONS = [
    { id: 'pakistan', label: 'Pakistan', feeds: [
      ['Dawn', 'https://www.dawn.com/feeds/home'],
      ['Google News', 'https://news.google.com/rss/headlines/section/geo/Pakistan?hl=en-PK&gl=PK&ceid=PK:en'] ] },
    { id: 'world', label: 'World', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/world/rss.xml'],
      ['Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'] ] },
    { id: 'politics', label: 'Politics', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/politics/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/politics/rss'] ] },
    { id: 'business', label: 'Business', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/business/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/business/rss'] ] },
    { id: 'technology', label: 'Technology', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/technology/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/technology/rss'] ] },
    { id: 'climate', label: 'Climate & Environment', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/science_and_environment/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/environment/rss'] ] },
    { id: 'sports', label: 'Sports', feeds: [
      ['BBC Sport', 'https://feeds.bbci.co.uk/sport/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/sport/rss'] ] },
    { id: 'culture', label: 'Culture', feeds: [
      ['BBC News', 'https://feeds.bbci.co.uk/news/entertainment_and_arts/rss.xml'],
      ['Guardian', 'https://www.theguardian.com/culture/rss'] ] },
    { id: 'current-affairs', label: 'Current Affairs', feeds: [
      ['Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'],
      ['BBC News', 'https://feeds.bbci.co.uk/news/rss.xml'] ] },
    { id: 'opinion', label: 'Opinion', feeds: [
      ['Guardian', 'https://www.theguardian.com/commentisfree/rss'],
      ['Dawn', 'https://www.dawn.com/feeds/opinion'] ] },
    { id: 'fact-check', label: 'Fact Check', feeds: [
      ['Google News', 'https://news.google.com/rss/search?q=fact+check&hl=en-PK&gl=PK&ceid=PK:en'] ] },
  ];

  const $ = (s) => document.querySelector(s);
  const app = $('#main');
  let data = {};        // section id -> items[]
  let lastUpdate = null;

  /* ---------- helpers ---------- */
  const esc = (s = '') => String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const strip = (html = '') => {
    const d = new DOMParser().parseFromString(html, 'text/html');
    return (d.body.textContent || '').replace(/\s+/g, ' ').trim();
  };
  const safeUrl = (u) => /^https?:\/\//i.test(u || '') ? u : '';
  const ago = (t) => {
    const m = Math.round((Date.now() - t) / 60000);
    if (isNaN(m)) return '';
    if (m < 1) return 'just now';
    if (m < 60) return m + ' min ago';
    if (m < 1440) return Math.round(m / 60) + ' h ago';
    return Math.round(m / 1440) + ' d ago';
  };
  const parseDate = (s) => {
    if (!s) return 0;
    // rss2json returns "YYYY-MM-DD HH:MM:SS" in UTC
    const iso = /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/.test(s) ? s.replace(' ', 'T') + 'Z' : s;
    const t = Date.parse(iso);
    return isNaN(t) ? 0 : t;
  };
  const sectionLabel = (id) => (SECTIONS.find(s => s.id === id) || {}).label || id;

  /* ---------- fetching ---------- */
  async function viaRss2Json(url) {
    const r = await fetch('https://api.rss2json.com/v1/api.json?rss_url=' + encodeURIComponent(url));
    if (!r.ok) throw new Error('rss2json ' + r.status);
    const j = await r.json();
    if (j.status !== 'ok') throw new Error('rss2json status');
    return j.items.map(i => ({
      title: strip(i.title),
      link: i.link,
      summary: strip(i.description || i.content || '').slice(0, 240),
      time: parseDate(i.pubDate),
      img: i.thumbnail || (i.enclosure && /image/.test(i.enclosure.type || '') ? i.enclosure.link : '') || firstImg(i.content || i.description),
    }));
  }
  function firstImg(html = '') {
    const m = /<img[^>]+src=["']([^"']+)/i.exec(html);
    return m ? m[1] : '';
  }
  async function viaProxy(url) {
    const r = await fetch('https://api.allorigins.win/raw?url=' + encodeURIComponent(url));
    if (!r.ok) throw new Error('proxy ' + r.status);
    const xml = new DOMParser().parseFromString(await r.text(), 'text/xml');
    const txt = (el, tag) => { const n = el.getElementsByTagName(tag)[0]; return n ? n.textContent : ''; };
    return [...xml.querySelectorAll('item, entry')].slice(0, 15).map(el => {
      const linkEl = el.getElementsByTagName('link')[0];
      const desc = txt(el, 'description') || txt(el, 'summary') || txt(el, 'content');
      const media = el.getElementsByTagName('media:thumbnail')[0] || el.getElementsByTagName('media:content')[0];
      return {
        title: strip(txt(el, 'title')),
        link: (linkEl && (linkEl.getAttribute('href') || linkEl.textContent)) || '',
        summary: strip(desc).slice(0, 240),
        time: Date.parse(txt(el, 'pubDate') || txt(el, 'updated') || txt(el, 'published')) || 0,
        img: (media && media.getAttribute('url')) || firstImg(desc),
      };
    });
  }
  async function fetchFeed([source, url]) {
    let items;
    try { items = await viaRss2Json(url); }
    catch { try { items = await viaProxy(url); } catch { return []; } }
    return items.map(i => ({ ...i, source }));
  }

  async function loadSection(sec) {
    const lists = await Promise.all(sec.feeds.map(fetchFeed));
    const seen = new Set();
    return lists.flat()
      .filter(i => i.title && safeUrl(i.link) && !seen.has(i.title) && seen.add(i.title))
      .sort((a, b) => b.time - a.time)
      .slice(0, 18);
  }

  // Pre-built snapshot written by scripts/fetch-news.ps1 (avoids third-party API limits).
  const STATIC_MAX_AGE = 3 * 60 * 60 * 1000;
  async function loadStatic() {
    let n = null;
    if (/^https?:$/.test(location.protocol)) {
      try { const r = await fetch('news.json?t=' + Date.now(), { cache: 'no-store' }); if (r.ok) n = await r.json(); } catch {}
    }
    if (!n && location.protocol === 'file:') {      // opened from disk: re-load news.js to pick up fresh data
      await new Promise(res => {
        const s = document.createElement('script');
        s.src = 'news.js?t=' + Date.now(); s.onload = s.onerror = () => { s.remove(); res(); };
        document.head.appendChild(s);
      });
    }
    if (!n) n = window.TCC_NEWS || null;
    return n && n.sections && Date.now() - n.updated < STATIC_MAX_AGE ? n : null;
  }

  async function loadAll() {
    setStatus('Updating…', false);
    await reloadScript('generated.js');
    const snap = await loadStatic();
    const results = await Promise.all(SECTIONS.map(s =>
      (snap && snap.sections[s.id] && snap.sections[s.id].length
        ? Promise.resolve(snap.sections[s.id])
        : OWN_ONLY ? Promise.resolve([]) : loadSection(s)).then(r => [s.id, r])));
    let got = 0;
    results.forEach(([id, items]) => { if (items.length) { data[id] = items; got++; } });
    if (got) {
      lastUpdate = Date.now();
      try { localStorage.setItem(CACHE_KEY, JSON.stringify({ t: lastUpdate, data })); } catch {}
      setStatus('Live · updated ' + new Date(lastUpdate).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), true);
    } else {
      setStatus(Object.keys(data).length ? 'Offline · showing saved headlines' : 'Could not reach news feeds', false);
    }
    render();
  }

  function setStatus(msg, ok) {
    $('#status').textContent = msg;
    $('#dot').classList.toggle('off', !ok);
  }

  /* ---------- rendering ---------- */
  const DESC = {
    'pakistan': 'Politics, economy, society and daily life across Pakistan.',
    'world': 'International news and developments from every region.',
    'politics': 'Governments, elections, policy and power.',
    'business': 'Markets, companies, trade and the economy.',
    'technology': 'Technology, science and the digital world.',
    'climate': 'Climate, environment and the natural world.',
    'sports': 'Results, reports and analysis from the world of sport.',
    'culture': 'Arts, entertainment, film, music and ideas.',
    'current-affairs': 'The stories shaping the day.',
    'opinion': 'Commentary and perspectives from leading columnists.',
    'fact-check': 'Claims, rumours and what the evidence says.',
    'latest': 'The newest headlines across every section.',
    'originals': 'Articles written by The Current Canvas desk with AI assistance, each with its reporting basis stated.',
  };
  const abs = (t) => new Date(t).toLocaleString('en-GB', { timeZone: 'Asia/Karachi', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit', hour12: true });
  const dt = (i) => `<time datetime="${i.time ? new Date(i.time).toISOString() : ''}">${esc(ago(i.time))}</time>`;
  // Every story opens on this site. Feed items get an in-site page (picture + the feed's summary, or the
  // full text for openly licensed sources) with a credit and a "read the full story" link to the publisher.
  const hashId = (s) => { let h = 5381; for (let k = 0; k < s.length; k++) h = ((h << 5) + h + s.charCodeAt(k)) | 0; return 'a' + (h >>> 0).toString(16); };
  const storyId = (i) => i.id || hashId(i.link || i.title || '');
  const ext = (i) => `href="#/story/${encodeURIComponent(storyId(i))}"`;
  const ORIG_LABEL = 'The Current Canvas Original';
  // hand-written pieces (originals.js) + pieces the auto-writer publishes (generated.js), oldest first
  const allOriginals = () => [...(window.TCC_ORIGINALS || []), ...(window.TCC_GENERATED || [])].sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
  const reloadScript = (src) => new Promise(res => {
    const s = document.createElement('script');
    s.src = src + '?t=' + Date.now(); s.onload = s.onerror = () => { s.remove(); res(); };
    document.head.appendChild(s);
  });
  function normalize() {
    // articles written for this site (originals.js) are merged into their sections
    allOriginals().forEach(o => {
      const arr = (data[o.section] = data[o.section] || []);
      if (!arr.some(i => i.id === o.id)) arr.unshift({ id: o.id, title: o.title, summary: o.summary, body: o.body, time: Date.parse(o.time), source: ORIG_LABEL, kind: 'written', basis: o.basis, asOf: o.asOf, img: o.img ? o.img.file : '', imgMeta: o.img || null });
    });
    if (OWN_ONLY) Object.keys(data).forEach(k => { data[k] = data[k].filter(isOwn); });
    Object.values(data).forEach(arr => arr.forEach(i => { if (!i.id) i.id = storyId(i); }));
  }
  function updateNav() {
    const has = (id) => (data[id] || []).length > 0;
    $('#nav').innerHTML = [['originals', 'Originals'], ...SECTIONS.filter(s => has(s.id)).map(s => [s.id, s.label]), ['latest', 'Latest']]
      .map(([id, l]) => `<a data-id="${id}" href="#/${id}">${esc(l)}</a>`).join('');
  }
  const writtenItems = () => allOriginals().map(o => ({ id: o.id, sec: o.section, title: o.title, summary: o.summary, body: o.body, time: Date.parse(o.time), source: ORIG_LABEL, kind: 'written', basis: o.basis, asOf: o.asOf, img: o.img ? o.img.file : '', imgMeta: o.img || null })).sort((a, b) => b.time - a.time);

  // Photos for original articles come from Wikimedia Commons under open licences; show the required credit.
  function photoCaption(m) {
    const lic = m.licenseUrl ? `<a href="${esc(safeUrl(m.licenseUrl))}" target="_blank" rel="noopener noreferrer">${esc(m.license)}</a>` : esc(m.license);
    return `<figcaption>${esc(m.caption)} Photo: ${esc(m.artist)} via <a href="${esc(safeUrl(m.page))}" target="_blank" rel="noopener noreferrer">Wikimedia Commons</a>, ${lic}.</figcaption>`;
  }

  function storyView(id) {
    let item = null, sec = '';
    for (const s of SECTIONS) { const f = (data[s.id] || []).find(i => i.id === id); if (f) { item = f; sec = s.id; break; } }
    if (!item) return '<div class="topic-empty"><h2>Story not found</h2><p>This story has been updated or removed. <a href="#/">Back to the front page</a>.</p></div>';
    const label = sectionLabel(sec);
    const isData = !!item.original, isFull = item.kind === 'licensed', isWritten = item.kind === 'written';
    const paras = (isData || isFull || isWritten) ? [].concat(item.body || []) : [item.summary].filter(Boolean);
    const body = paras.map(p => `<p>${esc(p)}</p>`).join('');
    const tag = isData ? 'Data brief' : isWritten ? 'Original' : isFull ? item.source : 'News summary';
    const byline = isData ? 'By The Current Canvas Data Desk' : isWritten ? 'By The Current Canvas Desk · AI-assisted' : 'Source: ' + esc(item.source);
    const hero = item.img
      ? `<figure class="article-figure"><img alt="" src="${esc(item.img)}" onerror="this.closest('figure').remove()">${isData ? '' : isWritten && item.imgMeta ? photoCaption(item.imgMeta) : `<figcaption>Image: ${esc(item.source)}</figcaption>`}</figure>`
      : `<figure class="article-figure">${fallback(item, label)}</figure>`;
    let note;
    if (isWritten) {
      note = `<h2>Reporting basis</h2><p>Written by The Current Canvas with the help of an AI assistant, using facts published by ${esc((item.basis || []).join(' and '))} as of ${esc(item.asOf || '')}. We have not independently verified these facts and have not added quotes or details beyond what those outlets reported. See our <a href="#/ai-usage-policy">AI Usage Policy</a> and <a href="#/corrections-policy">Corrections Policy</a>.</p>`;
    } else if (isData) {
      const credit = item.creditUrl
        ? `<a href="${esc(safeUrl(item.creditUrl))}" target="_blank" rel="noopener noreferrer">${esc(item.credit)}</a>` : esc(item.credit);
      note = `<h2>How this brief was made</h2><p>Written automatically from public data and refreshed with every update. Data: ${credit}.</p>`;
    } else {
      const go = `<a href="${esc(safeUrl(item.link))}" target="_blank" rel="noopener noreferrer">Read the full story at ${esc(item.source)} ↗</a>`;
      note = isFull
        ? `<h2>About this story</h2><p>Published by ${esc(item.source)} and reproduced with credit. ${go}</p>`
        : `<h2>Continue reading</h2><p>This is a short summary of a story reported by ${esc(item.source)}. ${go}</p>`;
    }
    return `<nav class="breadcrumb"><a href="#/">Home</a><span>/</span><a href="#/${sec}">${esc(label)}</a><span>/</span><span aria-current="page">${esc(tag)}</span></nav>
      <article class="article-wrap">
        <header class="article-heading"><span class="eyebrow accent">${esc(label)} <span class="dot">•</span> ${esc(tag)}</span>
          <h1>${esc(item.title)}</h1>
          <div class="article-byline"><span>${byline}</span><span>${esc(abs(item.time))} PKT</span></div></header>
        ${hero}
        <div class="article-body">${body}
          <aside class="reporting-basis">${note}</aside>
          <p><a href="#/${sec}">← More from ${esc(label)}</a></p></div>
      </article>`;
  }

  const fallback = (i, kicker) => `<div class="image-fallback"><span class="fallback-brand">The Current Canvas</span>
      <div><span class="fallback-category">${esc(kicker)}</span><br><strong>${esc(i.title)}</strong></div></div>`;
  const thumb = (i, kicker) => i.img
    ? `<img loading="lazy" alt="" src="${esc(i.img)}" onerror="this.outerHTML=this.dataset.fb" data-fb="${esc(fallback(i, kicker))}">`
    : fallback(i, kicker);

  const card = (i, kicker, cls = '') => `
    <article class="story-card ${cls}">
      <a class="card-image" ${ext(i)} tabindex="-1" aria-hidden="true">${thumb(i, kicker)}</a>
      <div class="card-copy">
        <div class="story-meta"><span>${esc(kicker)}</span><span class="sep">•</span><span>${esc(i.source)}</span><span class="sep">•</span>${dt(i)}</div>
        <h3><a ${ext(i)}>${esc(i.title)}</a></h3>
        ${i.summary ? `<p>${esc(i.summary)}</p>` : ''}
      </div>
    </article>`;

  const allItems = () => {
    const seen = new Set(), all = [];
    SECTIONS.forEach(s => (data[s.id] || []).forEach(i => {
      if (!seen.has(i.title)) { seen.add(i.title); all.push({ ...i, sec: s.id }); }
    }));
    return all.sort((a, b) => b.time - a.time);
  };

  function homeView() {
    const all = allItems();
    if (!all.length) return '<div class="topic-empty"><h2>No headlines yet</h2><p>Check your connection and press Refresh in the footer.</p></div>';

    const used = new Set();
    const take = (arr, n) => arr.filter(i => !used.has(i.title)).slice(0, n).map(i => (used.add(i.title), i));
    const orig = take(all.filter(i => i.kind === 'written'), 4);
    const lead = orig.shift() || take(all.filter(i => i.summary), 1)[0] || take(all, 1)[0];
    const visual = take(all.filter(i => i.img), 1)[0] || take(all, 1)[0];
    const latest = take(all, 8);
    const ranked = take(all, 5);
    const picks = take(all.filter(i => i.img && i.summary), 3);
    const k = (i) => sectionLabel(i.sec);

    let h = `<div class="edition-line"><span>Today's front page</span><time>${esc(new Date().toLocaleDateString('en-GB', { timeZone: 'Asia/Karachi', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' }))}</time></div>
    <section class="lead-grid">
      <article class="lead-story">
        <div><span class="eyebrow accent">${esc(k(lead))}</span><h1><a ${ext(lead)}>${esc(lead.title)}</a></h1>
        <p>${esc(lead.summary)}</p></div>
        <div class="lead-bottom"><span>${esc(lead.source)} <span class="dot">•</span> ${dt(lead)}</span><a ${ext(lead)}>Read full story →</a></div>
      </article>
      <article class="visual-story"><a ${ext(visual)}>
        ${visual.img ? `<figure><img alt="" src="${esc(visual.img)}" onerror="this.parentNode.outerHTML=this.dataset.fb" data-fb="${esc(fallback(visual, k(visual)))}"></figure>` : fallback(visual, k(visual))}
        <div class="visual-story-copy"><span class="eyebrow">In focus <span class="dot">•</span> ${esc(k(visual))}</span><h2>${esc(visual.title)}</h2></div>
      </a></article>
    </section>

    <div class="front-columns">
      <section class="front-latest"><div class="section-heading"><div><span class="eyebrow accent">Just in</span><h2>Latest news</h2></div><a href="#/latest">All latest →</a></div>
        <ol>${latest.map(i => `<li><span>${esc(k(i))}</span><h3><a ${ext(i)}>${esc(i.title)}</a></h3>${dt(i)} <time> · ${esc(i.source)}</time></li>`).join('')}</ol></section>
      <aside class="front-rail">
        <section class="rail-block"><span class="eyebrow accent">Right now</span><h2>Top headlines</h2>
          <ol class="ranked-list">${ranked.map((i, n) => `<li><b>${n + 1}</b><a ${ext(i)}>${esc(i.title)}</a></li>`).join('')}</ol></section>
        <div class="ad-space ad-compact"><span>Advertisement</span><p>Reach readers across Pakistan and beyond.</p><a href="#/advertise">Advertise with us</a></div>
        <section class="rail-block newsletter-box"><span class="eyebrow">Newsletter</span><h2>The Canvas Briefing</h2>
          <p>A daily digest of the stories that matter.</p>
          <label for="nl">Email address</label><input id="nl" type="email" placeholder="you@example.com" disabled>
          <small>We are not sending newsletters yet.</small></section>
      </aside>
    </div>

    ${orig.length ? `<section class="editors-section"><div class="section-heading"><div><span class="eyebrow accent">Written by our desk</span><h2>The Current Canvas Original</h2></div><a href="#/originals">All originals →</a></div>
      <div class="picks-grid">${orig.map(i => card(i, k(i))).join('')}</div></section>` : ''}

    <section class="editors-section"><div class="section-heading"><div><span class="eyebrow accent">Selected for you</span><h2>Editor's picks</h2></div></div>
      <div class="picks-grid">${picks.map(i => card(i, k(i))).join('')}</div></section>`;

    SECTIONS.forEach(s => {
      const items = (data[s.id] || []).filter(i => !used.has(i.title)).slice(0, 3);
      if (!items.length) return;
      h += `<section class="topic-section"><div class="section-heading"><div><span class="eyebrow accent">Section</span><h2>${esc(s.label)}</h2></div><a href="#/${s.id}">View all →</a></div>
        <div class="topic-grid">${items.map(i => card(i, s.label)).join('')}</div></section>`;
    });
    return h;
  }

  function listView(title, id, items) {
    const rail = `<aside class="category-rail"><section class="rail-block"><span class="eyebrow accent">Browse</span><h2>Sections</h2>
      <div class="rail-links">${SECTIONS.map(s => `<a href="#/${s.id}">${esc(s.label)}</a>`).join('')}<a href="#/latest">Latest</a></div></section>
      <div class="ad-space ad-compact"><span>Advertisement</span><p>Your message here.</p><a href="#/advertise">Advertise with us</a></div></aside>`;
    const kicker = (i) => i.sec ? sectionLabel(i.sec) : title;
    return `<nav class="breadcrumb"><a href="#/">Home</a><span>/</span><span aria-current="page">${esc(title)}</span></nav>
      <div class="category-title"><span class="eyebrow accent">Section</span><h1>${esc(title)}</h1><p>${esc(DESC[id] || '')}</p></div>
      ${items.length ? `<div class="category-lead">${card(items[0], kicker(items[0]), 'large-card')}</div>
      <div class="category-main"><div class="category-list">${items.slice(1).map(i => card(i, kicker(i), 'list-card')).join('')}</div>${rail}</div>`
      : '<div class="topic-empty"><h2>No stories right now</h2><p>Please check back shortly.</p></div>'}`;
  }

  function searchView(q = '') {
    return `<nav class="breadcrumb"><a href="#/">Home</a><span>/</span><span aria-current="page">Search</span></nav>
      <div class="category-title"><span class="eyebrow accent">Search</span><h1>Search headlines</h1></div>
      <div class="search-form"><label for="q">Search all current headlines</label><input id="q" type="search" value="${esc(q)}" placeholder="e.g. budget, cricket, climate" autocomplete="off"></div>
      <div class="search-results" id="results"></div>`;
  }
  function runSearch(q) {
    const el = $('#results'); if (!el) return;
    const t = q.trim().toLowerCase();
    if (!t) { el.innerHTML = ''; return; }
    const hits = allItems().filter(i => (i.title + ' ' + i.summary).toLowerCase().includes(t)).slice(0, 40);
    el.innerHTML = `<h2>${hits.length} result${hits.length === 1 ? '' : 's'} for “${esc(q)}”</h2>` +
      hits.map(i => card(i, sectionLabel(i.sec), 'list-card')).join('');
  }

  function aboutView() {
    const src = [...new Set(SECTIONS.flatMap(s => s.feeds.map(f => f[0])))].join(', ');
    return `<div class="info-layout"><div class="info-heading"><span class="eyebrow accent">About</span><h1>About The Current Canvas</h1>
      <p>Independent journalism, wider perspective.</p></div>
      <div class="info-content">
        <section><h2>Who we are</h2><p>The Current Canvas is a news front page covering Pakistan, the world and beyond. Headlines and summaries are collected automatically from public RSS feeds of established publishers and refreshed every few minutes.</p></section>
        <section><h2>Source &amp; verification policy</h2><p>Every item shows its original publisher and links to the full story on that publisher's site. We display only headlines, short excerpts and publisher-supplied thumbnails. Current sources: ${esc(src)}.</p></section>
        <section><h2>Corrections</h2><p>Because stories are written by third-party publishers, corrections must be requested from the original source.</p></section>
        <section><h2>Advertising, privacy &amp; terms</h2><p>Placeholder page. Replace this text with your own advertising, privacy, cookie and terms-of-use policies before publishing.</p></section>
      </div></div>`;
  }

  function route() {
    const id = (location.hash.replace(/^#\/?/, '') || 'home').split('?')[0];
    document.querySelectorAll('.nav-inner a').forEach(a =>
      a.dataset.id === id ? a.setAttribute('aria-current', 'page') : a.removeAttribute('aria-current'));
    return id;
  }

  function render() {
    normalize();
    updateNav();
    const id = route();
    const PAGES = window.TCC_PAGES || {};
    if (PAGES[id]) {
      // static, first-party content copied into pages.js (not user input)
      app.innerHTML = `<nav class="breadcrumb"><a href="#/">Home</a><span>/</span><span aria-current="page">${PAGES[id].title}</span></nav><div class="info-layout">${PAGES[id].html}</div>`;
      document.title = PAGES[id].title.replace(/&amp;/g, '&') + ' — The Current Canvas';
    }
    else if (id.startsWith('story/')) app.innerHTML = storyView(decodeURIComponent(id.slice(6)));
    else if (id === 'about') app.innerHTML = aboutView();
    else if (id === 'search') {
      const q = (location.hash.split('?q=')[1] || '');
      app.innerHTML = searchView(decodeURIComponent(q));
      const inp = $('#q'); runSearch(inp.value);
      inp.addEventListener('input', () => runSearch(inp.value));
      inp.focus();
    }
    else if (id === 'latest') app.innerHTML = listView('Latest', 'latest', allItems().slice(0, 30));
    else if (id === 'originals') app.innerHTML = listView(ORIG_LABEL, 'originals', writtenItems());
    else if (SECTIONS.some(s => s.id === id)) app.innerHTML = listView(sectionLabel(id), id, (data[id] || []).map(i => ({ ...i, sec: id })));
    else app.innerHTML = homeView();
    if (!PAGES[id]) document.title = 'The Current Canvas';
    renderTicker();
    if (id !== 'search') window.scrollTo({ top: 0 });
  }

  function renderTicker() {
    const items = allItems().slice(0, 20);
    const group = items.map(i => `<a ${ext(i)}>${esc(i.title)}</a><span aria-hidden="true">◆</span>`).join('');
    $('#ticker').innerHTML = items.length
      ? `<div class="ticker-group">${group}</div><div class="ticker-group" aria-hidden="true">${group}</div>`
      : '<div class="ticker-group">Loading headlines…</div>';
  }

  /* ---------- chrome ---------- */
  function buildChrome() {
    $('#nav').innerHTML = [['originals', 'Originals'], ...SECTIONS.map(s => [s.id, s.label]), ['latest', 'Latest']]
      .map(([id, l]) => `<a data-id="${id}" href="#/${id}">${esc(l)}</a>`).join('');
    $('#foot-nav').innerHTML = [['home', 'Home', '#/'], ...SECTIONS.map(s => [s.id, s.label, '#/' + s.id]), ['latest', 'Latest', '#/latest']]
      .map(([, l, h]) => `<a href="${h}">${esc(l)}</a>`).join('');
    $('#yr').textContent = new Date().getFullYear();
    const tick = () => $('#clock').textContent = new Date().toLocaleString('en-GB', {
      timeZone: 'Asia/Karachi', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric', hour: 'numeric', minute: '2-digit', hour12: true }).replace(/ (\d{4}),/, ' $1 at') + ' PKT';
    tick(); setInterval(tick, 30000);
    $('#refresh').addEventListener('click', loadAll);
  }

  /* ---------- boot ---------- */
  buildChrome();
  try {
    const c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
    if (c && Date.now() - c.t < CACHE_MAX_AGE) { data = c.data; render(); setStatus('Showing saved headlines…', false); }
  } catch {}
  window.addEventListener('hashchange', render);
  loadAll();
  setInterval(loadAll, REFRESH_MS);
  document.addEventListener('visibilitychange', () => { if (!document.hidden && Date.now() - (lastUpdate || 0) > REFRESH_MS) loadAll(); });
})();

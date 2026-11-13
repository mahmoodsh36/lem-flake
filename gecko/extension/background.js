'use strict';

// the profile is only used for lem, so any page on these hosts is the editor
const isLem = (url) => {
  try {
    const u = new URL(url);
    return u.protocol === 'http:' && (u.hostname === '127.0.0.1' || u.hostname === 'localhost');
  } catch (_) {
    return false;
  }
};

const underLem = (details) => {
  const ancestors = details.frameAncestors || [];
  return ancestors.length > 0 && isLem(ancestors[ancestors.length - 1].url);
};

// cross-site frames do not get SameSite=Lax/Strict cookies, so logins would not stick
const sameSiteNone = (cookies) => cookies.split('\n').map((cookie) => {
  const parts = cookie.split(';').filter((p) => !/^\s*samesite\s*=/i.test(p));
  if (!parts.some((p) => /^\s*secure\s*$/i.test(p))) parts.push(' Secure');
  parts.push(' SameSite=None');
  return parts.join(';');
}).join('\n');

// firefox joins repeated csp headers with commas, one policy each
const withoutFrameAncestors = (csp) => csp.split(',')
  .map((policy) => policy.split(';').filter((d) => !/^\s*frame-ancestors\b/i.test(d)).join(';'))
  .filter((policy) => policy.replace(/;/g, '').trim()).join(',');

browser.webRequest.onHeadersReceived.addListener((details) => {
  if (!underLem(details)) return {};
  const https = details.url.startsWith('https:');
  const headers = [];
  for (const header of details.responseHeaders) {
    const name = header.name.toLowerCase();
    if (name === 'x-frame-options') continue;
    if (name === 'content-security-policy') {
      const value = withoutFrameAncestors(header.value);
      if (value) headers.push({ name: header.name, value });
      continue;
    }
    if (name === 'set-cookie' && https) {
      headers.push({ name: header.name, value: sameSiteNone(header.value) });
      continue;
    }
    headers.push(header);
  }
  return { responseHeaders: headers };
}, { urls: ['<all_urls>'] }, ['blocking', 'responseHeaders']);

// send frame loads as top level ones, some sites (google sign in) refuse to load in a frame
browser.webRequest.onBeforeSendHeaders.addListener((details) => {
  const ancestors = details.frameAncestors || [];
  if (details.type !== 'sub_frame' || ancestors.length !== 1 || !isLem(ancestors[0].url)) return {};
  const fromLem = isLem(details.originUrl || '');
  const headers = [];
  for (const header of details.requestHeaders) {
    const name = header.name.toLowerCase();
    if (name === 'sec-fetch-dest') headers.push({ name: header.name, value: 'document' });
    else if (name === 'sec-fetch-site' && fromLem) headers.push({ name: header.name, value: 'none' });
    else if (name === 'referer' && fromLem) continue;
    else headers.push(header);
  }
  return { requestHeaders: headers };
}, { urls: ['<all_urls>'], types: ['sub_frame'] }, ['blocking', 'requestHeaders']);

const toTop = (tabId, message) =>
  browser.tabs.sendMessage(tabId, message, { frameId: 0 }).catch(() => {});

// lem's own html buffers are srcdoc frames
const isPageFrame = (sender) =>
  sender.tab && sender.frameId !== 0 && isLem(sender.tab.url) && sender.url !== 'about:srcdoc';

// lem knows a page by its frame directly under the editor
const rootOf = async (tabId, frameId) => {
  for (let i = 0; i < 32; i++) {
    const frame = await browser.webNavigation.getFrame({ tabId, frameId });
    if (!frame || frame.parentFrameId <= 0) return frameId;
    frameId = frame.parentFrameId;
  }
  return frameId;
};

// "tabId:root" of pages that have the keyboard
const passing = new Set();

// page scripts: lem's code run as `function (lem)` in pages matching its url globs. null until lem
// sends them.
let scripts = null;
let scriptsWanted = false;
let scriptsQueue = Promise.resolve();

const globRe = (glob) => new RegExp('^' + [...glob].map((c) =>
  (c === '*' ? '.*' : c === '?' ? '.' : c.replace(/[.+^${}()|[\]\\]/, '\\$&'))).join('') + '$');

// world MAIN is the only way past a strict csp. it runs in every matching frame, so it waits for
// frame.js to start it under lem.
const wrap = (name, code) => `(() => {
  if (window === window.top) return;
  const name = ${JSON.stringify(name)};
  const handlers = [];
  let started = false;
  const lem = {
    send: (value) => window.postMessage({ lemScript: name, dir: 'up', data: JSON.stringify(value) }, '*'),
    on: (handler) => { handlers.push(handler); },
  };
  const run = () => { (function (lem) {
${code}
  }).call(window, lem); };
  window.addEventListener('message', (e) => {
    const d = e.data;
    if (e.source !== window || !d || d.lemScript !== name || d.dir !== 'down') return;
    if (d.start) { if (!started) { started = true; run(); } return; }
    if (!started) return;
    let value;
    try { value = JSON.parse(d.data); } catch (_) { return; }
    for (const h of handlers) try { h(value); } catch (err) { console.error(err); }
  });
})();`;

const sameScript = (a, b) => a.code === b.code && a.allFrames === b.allFrames && a.matches.join('\n') === b.matches.join('\n');

const register = (s) => browser.contentScripts.register({
  matches: ['<all_urls>'], includeGlobs: s.matches, js: [{ code: wrap(s.name, s.code) }],
  runAt: 'document_start', allFrames: true, world: 'MAIN',
}).catch((e) => { console.error(`page script ${s.name}:`, e); return null; });

const unregister = (s) => s.registered && s.registered.unregister().catch(() => {});

const matches = (s, url, direct) => (s.allFrames || direct) && s.res.some((re) => re.test(url));

const setScripts = async (tabId, list) => {
  const old = new Map((scripts || []).map((s) => [s.name, s]));
  const next = (Array.isArray(list) ? list : []).filter((s) => s && typeof s.name === 'string'
    && typeof s.code === 'string' && Array.isArray(s.matches)).map((s) => {
    const globs = s.matches.filter((m) => typeof m === 'string');
    return { name: s.name, code: s.code, allFrames: Boolean(s.allFrames), matches: globs, res: globs.map(globRe) };
  });
  const changed = [];
  scripts = await Promise.all(next.map(async (s) => {
    const prev = old.get(s.name);
    old.delete(s.name);
    if (prev && sameScript(prev, s)) return prev;
    if (prev) {
      changed.push(prev);
      await unregister(prev);
    }
    changed.push(s);
    return { ...s, registered: await register(s) };
  }));
  for (const s of old.values()) {
    changed.push(s);
    await unregister(s);
  }
  // registration only reaches documents loaded after it
  if (changed.length === 0) return;
  for (const f of await browser.webNavigation.getAllFrames({ tabId })) {
    if (f.frameId === 0) continue;
    const direct = (await rootOf(tabId, f.frameId)) === f.frameId;
    if (!changed.some((s) => matches(s, f.url, direct))) continue;
    browser.tabs.executeScript(tabId, { frameId: f.frameId, code: 'location.reload()' }).catch(() => {});
  }
};

const scriptsFor = async (sender) => {
  if (!isPageFrame(sender)) return [];
  if (scripts === null) {
    if (!scriptsWanted) {
      scriptsWanted = true;
      toTop(sender.tab.id, { type: 'scripts-wanted' });
      setTimeout(() => { scriptsWanted = false; }, 5000);  // in case lem missed it
    }
    return [];
  }
  const root = await rootOf(sender.tab.id, sender.frameId);
  return scripts.filter((s) => s.registered && matches(s, sender.url, root === sender.frameId))
    .map((s) => ({ name: s.name, root }));
};

browser.runtime.onMessage.addListener((message, sender) => {
  switch (message.type) {
    case 'hello': {
      if (!isPageFrame(sender)) return Promise.resolve({ underLem: false });
      return rootOf(sender.tab.id, sender.frameId).then((root) =>
        ({ underLem: true, root, pass: passing.has(`${sender.tab.id}:${root}`) }));
    }
    case 'key':
    case 'unfocus':
      if (isPageFrame(sender)) toTop(sender.tab.id, message);
      return;
    case 'to-page': {
      // sent to every frame, each keeps what matches its root
      if (sender.frameId !== 0 || !sender.tab || !isLem(sender.tab.url)) return;
      const m = { ...message.message, root: message.frameId };
      const key = `${sender.tab.id}:${message.frameId}`;
      if (m.type === 'pass') { if (m.on) passing.add(key); else passing.delete(key); }
      return browser.tabs.sendMessage(sender.tab.id, m).catch(() => {});
    }
    case 'scripts':
      if (sender.frameId !== 0 || !sender.tab || !isLem(sender.tab.url)) return;
      scriptsQueue = scriptsQueue.then(() => setScripts(sender.tab.id, message.scripts)).catch((e) => console.error(e));
      return;
    case 'page-scripts':
      return scriptsFor(sender).then((list) => list.map((s) => s.name));
    case 'script-send':
      return scriptsFor(sender).then((list) => {
        const s = list.find((x) => x.name === message.name);
        if (s) toTop(sender.tab.id, { type: 'script', frameId: s.root, name: s.name, data: message.data });
      });
    case 'title':
      if (isPageFrame(sender)) toTop(sender.tab.id, { type: 'nav', frameId: sender.frameId, title: message.title });
      return;
    case 'clipboard-read':
      if (sender.frameId !== 0 || !sender.tab || !isLem(sender.tab.url)) return;
      return navigator.clipboard.readText();
    case 'history':
      return browser.tabs.executeScript(sender.tab.id, {
        frameId: message.frameId,
        code: { back: 'history.back()', forward: 'history.forward()', reload: 'location.reload()' }[message.action],
      }).catch(() => {});
  }
});

const onNavigation = (details) => {
  if (details.frameId === 0 || details.parentFrameId !== 0 || details.url.startsWith('about:')) return;
  browser.tabs.get(details.tabId).then((tab) => {
    if (isLem(tab.url)) toTop(details.tabId, { type: 'nav', frameId: details.frameId, url: details.url });
  }, () => {});
};
browser.webNavigation.onCommitted.addListener(onNavigation);
browser.webNavigation.onHistoryStateUpdated.addListener(onNavigation);
browser.webNavigation.onReferenceFragmentUpdated.addListener(onNavigation);

// a link or window.open from a page becomes a new web buffer. about:blank opens are left alone:
// they are usually sign in popups that need their opener.
browser.webNavigation.onCreatedNavigationTarget.addListener((details) => {
  if (details.url === 'about:blank') return;
  browser.tabs.get(details.sourceTabId).then((tab) => {
    if (!isLem(tab.url) || details.sourceFrameId === 0) return;
    browser.tabs.remove(details.tabId).catch(() => {});
    toTop(details.sourceTabId, { type: 'open', url: details.url });
  }, () => {});
});

// with the tab bar hidden, a new tab (say from the file menu) would cover lem with no way back.
// cmd+t is unbound in the flake. tabs a page opens have an opener and are handled above.
browser.tabs.onCreated.addListener((tab) => {
  if (tab.openerTabId !== undefined) return;
  browser.tabs.query({ windowId: tab.windowId }).then((tabs) => {
    const lem = tabs.find((t) => t.id !== tab.id && isLem(t.url));
    if (!lem) return;
    browser.tabs.remove(tab.id).catch(() => {});
    browser.tabs.update(lem.id, { active: true }).catch(() => {});
  }, () => {});
});

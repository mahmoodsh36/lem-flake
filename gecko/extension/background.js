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

browser.webRequest.onHeadersReceived.addListener((details) => {
  if (!underLem(details)) return {};
  const https = details.url.startsWith('https:');
  const headers = [];
  for (const header of details.responseHeaders) {
    const name = header.name.toLowerCase();
    if (name === 'x-frame-options') continue;
    if (name === 'content-security-policy') {
      const value = header.value.split(';').filter((d) => !/^\s*frame-ancestors\b/i.test(d)).join(';');
      if (value.trim()) headers.push({ name: header.name, value });
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
    case 'title':
      if (isPageFrame(sender)) toTop(sender.tab.id, { type: 'nav', frameId: sender.frameId, title: message.title });
      return;
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

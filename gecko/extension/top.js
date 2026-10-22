'use strict';

// the editor page. lem shows a web buffer as a frame whose srcdoc is only "<!--lem-web ID URL-->".
// the page goes in our own frame on top of it, so it stays loaded when lem removes the marker.

// lem's page forwards any 'invoke-lem' message to the editor without checking the sender
window.addEventListener('message', (e) => {
  if (e.data && e.data.type === 'invoke-lem' && e.origin !== location.origin) e.stopImmediatePropagation();
}, true);

const SANDBOX = 'allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox '
  + 'allow-modals allow-downloads allow-pointer-lock allow-presentation allow-storage-access-by-user-activation';
const ALLOW = 'fullscreen; autoplay; clipboard-read; clipboard-write; encrypted-media; picture-in-picture; '
  + 'geolocation; microphone; camera; web-share';

const frames = new Map();   // id -> { frame, slot, frameId }
const MARKER = /^<!--lem-web (\S+) ([\s\S]*)-->$/;

const style = document.createElement('style');
style.textContent = 'iframe[data-lem-web-slot] { visibility: hidden !important; }'
  + 'iframe[data-lem-web] { border: none; }';

const invokeLem = (method, args) =>
  window.postMessage({ type: 'invoke-lem', method, args }, location.origin);

// null until firefox knows the frame
const frameIdOf = (entry) => {
  if (entry.frameId === null) {
    try { entry.frameId = browser.runtime.getFrameId(entry.frame); } catch (_) {}
  }
  return entry.frameId;
};

const place = (entry) => {
  const { frame, slot } = entry;
  if (slot && slot.isConnected) {
    frame.style.cssText = slot.style.cssText;
    frame.style.visibility = 'visible';
  } else {
    // visibility instead of display:none, so the page keeps its layout and media keeps playing
    frame.style.visibility = 'hidden';
    frame.style.pointerEvents = 'none';
  }
};

const slotObserver = new MutationObserver((records) => {
  for (const r of records) {
    const entry = frames.get(r.target.dataset.lemWebSlot);
    if (entry && entry.slot === r.target) place(entry);
  }
});

const adopt = (slot) => {
  const m = MARKER.exec(slot.getAttribute('srcdoc') || '');
  if (!m) return;
  const [, id, url] = m;
  slot.dataset.lemWebSlot = id;
  let entry = frames.get(id);
  if (!entry) {
    const frame = document.createElement('iframe');
    frame.dataset.lemWeb = id;
    frame.setAttribute('sandbox', SANDBOX);
    frame.setAttribute('allow', ALLOW);
    frame.setAttribute('allowfullscreen', '');
    entry = { frame, slot, frameId: null };
    frames.set(id, entry);
    slot.after(frame);
    frame.src = url;
    frame.addEventListener('load', () => frameIdOf(entry));
  } else if (entry.frame.parentNode !== slot.parentNode) {
    // moving a frame reloads it, so only move it when the marker has a new parent (a float)
    slot.after(entry.frame);
  }
  entry.slot = slot;
  slotObserver.observe(slot, { attributes: true, attributeFilter: ['style'] });
  place(entry);
  entry.frame.style.pointerEvents = '';
};

const scan = (node) => {
  if (node.nodeType !== 1) return;
  if (node.tagName === 'IFRAME') adopt(node);
  else for (const f of node.querySelectorAll('iframe[srcdoc]')) adopt(f);
};

const unplace = (node) => {
  if (node.nodeType !== 1) return;
  const slots = node.dataset && node.dataset.lemWebSlot ? [node] : node.querySelectorAll('iframe[data-lem-web-slot]');
  for (const slot of slots) {
    const entry = frames.get(slot.dataset.lemWebSlot);
    if (entry && entry.slot === slot) place(entry);
  }
};

new MutationObserver((records) => {
  for (const r of records) {
    if (r.type === 'attributes') { if (r.target.tagName === 'IFRAME') adopt(r.target); continue; }
    r.removedNodes.forEach(unplace);
    r.addedNodes.forEach(scan);
  }
}).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['srcdoc'] });

document.addEventListener('DOMContentLoaded', () => document.head.appendChild(style));

const lemInput = () => [...document.body.children].find((el) => el.tagName === 'INPUT');

// lem's hidden input refocuses itself on blur, which would stop clicks from focusing a page
window.addEventListener('blur', (e) => {
  if (e.target !== lemInput() || frames.size === 0) return;
  e.stopImmediatePropagation();
  setTimeout(() => {
    const active = document.activeElement;
    if (!(active && active.dataset && active.dataset.lemWeb)) e.target.focus();
  }, 0);
}, true);

const idOfFrame = (frameId) => {
  for (const [id, entry] of frames) if (frameIdOf(entry) === frameId) return id;
  return null;
};

const isMac = navigator.userAgent.includes('Mac OS X');
let grantedAt = -Infinity;

const webFrameFocused = () => {
  const active = document.activeElement;
  return Boolean(active && active.dataset && active.dataset.lemWeb);
};

browser.runtime.onMessage.addListener((message) => {
  switch (message.type) {
    case 'key': {
      const input = lemInput();
      if (!input) return;
      input.focus();
      const k = message.key;
      // off macos lem's client reads plain characters from input events, not keydown
      if (!isMac && !k.ctrlKey && !k.altKey && k.key.length === 1) {
        input.dispatchEvent(new InputEvent('input', { data: k.key, inputType: 'insertText', bubbles: true }));
      } else {
        input.dispatchEvent(new KeyboardEvent('keydown', { ...k, bubbles: true, cancelable: true }));
      }
      return;
    }
    case 'unfocus': {
      // unless lem just handed the page the focus itself
      const input = lemInput();
      if (input && webFrameFocused() && performance.now() - grantedAt > 1500) input.focus();
      return;
    }
    case 'nav': {
      const id = idOfFrame(message.frameId);
      if (id) invokeLem('lem-gecko-nav', { id, url: message.url || null, title: message.title || null });
      return;
    }
    case 'open':
      invokeLem('lem-gecko-open', { url: message.url });
      return;
  }
});

// commands from lem, posted through js-eval
window.addEventListener('message', (e) => {
  const d = e.data;
  if (e.origin !== location.origin || !d || typeof d.type !== 'string' || !d.type.startsWith('lem-web-')) return;
  const entry = frames.get(d.id);
  if (!entry) return;
  const action = d.type.slice('lem-web-'.length);
  const toPage = (message) => {
    const frameId = frameIdOf(entry);
    if (frameId !== null) browser.runtime.sendMessage({ type: 'to-page', frameId, message });
  };
  if (action === 'close') {
    entry.frame.remove();
    frames.delete(d.id);
  } else if (['back', 'forward', 'reload'].includes(action)) {
    browser.runtime.sendMessage({ type: 'history', frameId: frameIdOf(entry), action });
  } else if (action === 'pass') {
    toPage({ type: 'pass', on: Boolean(d.on) });
    if (d.on) {
      grantedAt = performance.now();
      entry.frame.focus();
    } else if (webFrameFocused()) {
      const input = lemInput();
      if (input) input.focus();
    }
  } else if (action === 'scroll') {
    toPage({ type: 'scroll', how: String(d.how), count: Number(d.count) || 1 });
  }
});

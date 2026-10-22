'use strict';

// runs in every frame; only frames inside a lem window hand keys back to the editor. outside a text
// field every key goes to lem (vi normal mode), unless lem passed the keyboard to the page (insert)
if (window !== window.top) {
  let underLem = false;
  let root = null;
  let pass = false;
  let gestureAt = -Infinity;
  let focusedEarly = false;
  // a page loaded into a frame the user is in (a search, then Enter) may focus its own fields
  let hadFocus = document.hasFocus();

  // a page focusing itself (autofocus, a script) would take every key from lem
  const giveBackFocus = () => {
    if (pass || hadFocus || performance.now() - gestureAt < 1000) return;
    browser.runtime.sendMessage({ type: 'unfocus' });
  };

  browser.runtime.sendMessage({ type: 'hello' }).then((r) => {
    underLem = Boolean(r && r.underLem);
    root = r && r.root;
    pass = Boolean(r && r.pass);
    if (!underLem) return;
    watchTitle();
    if (focusedEarly && document.hasFocus()) giveBackFocus();
  }, () => {});

  for (const type of ['pointerdown', 'mousedown', 'touchstart', 'keydown']) {
    window.addEventListener(type, () => { gestureAt = performance.now(); }, true);
  }
  window.addEventListener('focus', (e) => {
    if (e.target !== window) return;
    if (underLem) giveBackFocus();
    else focusedEarly = true;
  });
  window.addEventListener('blur', (e) => { if (e.target === window) hadFocus = false; });

  browser.runtime.onMessage.addListener((m) => {
    if (m.root !== root) return;
    if (m.type === 'pass') pass = m.on;
    // only the page's own document scrolls, not its subframes
    else if (m.type === 'scroll' && window.parent === window.top) scroll(m.how, m.count || 1);
  });

  // keys sent to lem even from a text field. other chords like C-a and C-k stay with the field
  const ALWAYS = new Set(['Escape', 'C-g', 'C-x', 'M-x', "C-'"]);

  const keyName = (e) => {
    let key = e.key;
    if (/^Key[A-Z]$/.test(e.code)) key = e.code.slice(3).toLowerCase();
    else if (/^Digit\d$/.test(e.code)) key = e.code.slice(5);
    return (e.ctrlKey ? 'C-' : '') + (e.altKey ? 'M-' : '') + key;
  };

  const editable = (el) => el && (el.isContentEditable
    || el.tagName === 'TEXTAREA'
    || (el.tagName === 'INPUT' && !/^(button|checkbox|radio|submit|reset|range|color|file|image)$/.test(el.type)));

  window.addEventListener('keydown', (e) => {
    if (!underLem || e.isComposing || e.metaKey) return;
    if (['Control', 'Alt', 'Shift', 'Meta', 'CapsLock', 'Dead', 'Process'].includes(e.key)) return;
    if (editable(document.activeElement)) {
      if (!ALWAYS.has(keyName(e))) return;
    } else if (pass && !e.ctrlKey && !e.altKey && e.key !== 'Escape') {
      return;
    }
    e.preventDefault();
    e.stopImmediatePropagation();
    browser.runtime.sendMessage({
      type: 'key',
      key: { key: e.key, code: e.code, ctrlKey: e.ctrlKey, altKey: e.altKey, shiftKey: e.shiftKey, metaKey: e.metaKey },
    });
  }, true);

  let scroller = null;
  // app-like pages scroll an inner box rather than the document
  const findScroller = () => {
    const doc = document.scrollingElement || document.documentElement;
    if (doc.scrollHeight > doc.clientHeight + 1) return doc;
    if (scroller && scroller.isConnected && scroller.scrollHeight > scroller.clientHeight + 1) return scroller;
    let best = doc, area = 0;
    for (const el of document.body ? document.body.querySelectorAll('*') : []) {
      if (el.scrollHeight <= el.clientHeight + 1 || !/(auto|scroll|overlay)/.test(getComputedStyle(el).overflowY)) continue;
      const r = el.getBoundingClientRect();
      const a = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0))
        * Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
      if (a > area) { area = a; best = el; }
    }
    return (scroller = best);
  };

  const scroll = (how, count) => {
    const el = findScroller();
    const h = el === document.scrollingElement ? innerHeight : el.clientHeight;
    const by = { line: 60, half: h / 2, page: h * 0.9 };
    if (how === 'top') el.scrollTop = 0;
    else if (how === 'bottom') el.scrollTop = el.scrollHeight;
    else if (how === 'left' || how === 'right') el.scrollLeft += (how === 'left' ? -60 : 60) * count;
    else {
      const [unit, dir] = how.split('-');
      el.scrollTop += (dir === 'up' ? -1 : 1) * by[unit] * count;
    }
  };

  const watchTitle = () => {
    if (window.parent !== window.top) return;
    let last = null;
    const send = () => {
      if (document.title !== last) {
        last = document.title;
        browser.runtime.sendMessage({ type: 'title', title: last });
      }
    };
    const start = () => {
      send();
      new MutationObserver(send).observe(document.head || document.documentElement, { subtree: true, childList: true, characterData: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
  };
}

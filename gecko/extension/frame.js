'use strict';

// runs in every frame; only frames inside a lem window hand keys back to the editor
if (window !== window.top) {
  let underLem = false;
  browser.runtime.sendMessage({ type: 'hello' }).then((r) => {
    underLem = Boolean(r && r.underLem);
    if (underLem) watchTitle();
  }, () => {});

  // keys sent to lem even from a text field. other chords like C-a and C-k stay with the field
  const ALWAYS = new Set(['Escape', 'C-g', 'C-x', 'M-x']);

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
    if (!e.ctrlKey && !e.altKey && e.key !== 'Escape') return;
    if (['Control', 'Alt', 'Shift'].includes(e.key)) return;
    if (editable(document.activeElement) && !ALWAYS.has(keyName(e))) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    browser.runtime.sendMessage({
      type: 'key',
      key: { key: e.key, code: e.code, ctrlKey: e.ctrlKey, altKey: e.altKey, shiftKey: e.shiftKey, metaKey: e.metaKey },
    });
  }, true);

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

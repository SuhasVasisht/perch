import Foundation

/// Compact X chrome with native scrolling and bounded reading restoration.
/// Home fits natural post heights and coordinates keyboard scrolling with resizing.
enum CropScript {
    static let source = #"""
    (() => {
      if (window.__perch) return;
      window.__perch = true;
      const send = window.__perchPost;
      const documentId = crypto.randomUUID();
      let intentRevision = 0;
      let snapshotRevision = 0;
      let suspended = false;
      const owner = () => ({ documentId, entryKey: entryKey(), intentRevision, url: location.href, suspended });
      const owns = saved => !!saved && saved.documentId === documentId && saved.intentRevision === intentRevision
        && saved.entryKey === entryKey() && saved.url === location.href;
      const post = body => send({ ...body, ...owner() });
      window.__tfOwner = owner;

      const rows = () => document.querySelectorAll('[data-testid="cellInnerDiv"] article[data-testid="tweet"]');
      let lastMode = '';

      // X's router restores offsets using its uncropped header geometry.
      // Remember visible posts per history entry to correct only Back/Forward.
      // Normal wheel scrolling never goes through this code.
      const positions = new Map();
      const entryKey = () => String(history.state?.key || location.href);
      let restoring = null;
      let interruptedRestore = null;
      let suspendCheckpoint = null;
      let userRead = false;
      let alignmentTimer = null;
      let scrollIntent = null;
      let alignmentTarget = null;
      let fitTimer = null;
      let activeCell = null;
      let lastFit = null;
      let pendingFit = null;
      let fitSerial = 0;
      let keyMotion = null;
      let keyFrame = 0;
      let firstUpAt = 0;
      let keyEdge = null;
      let saveTimer = null;
      let browserMotion = null;
      let keyBasis = null;
      let wheelBasis = null;
      let lastOwnedScroll = null;
      let initialAlignment = true;
      const scrollToOwned = (token, top, allowSuspended = false) => {
        if (!owns(token) || (suspended && !allowSuspended)) return false;
        window.scrollTo({ top, behavior: 'instant' });
        lastOwnedScroll = { ...token, y: scrollY, fitSerial };
        return true;
      };
      const cancelKeyEdge = () => { keyEdge = null; };
      const cancelKeyMotion = () => {
        cancelAnimationFrame(keyFrame);
        keyMotion = null;
      };
      const cancelAlignment = () => {
        clearTimeout(alignmentTimer);
        scrollIntent = null;
        alignmentTarget = null;
        pendingFit = null;
      };
      const invalidate = (reason, suspend = false) => {
        intentRevision += 1;
        if (['input', 'navigation', 'refresh', 'resize'].includes(reason)) {
          interruptedRestore = null;
          suspendCheckpoint = null;
          initialAlignment = false;
        }
        restoring = null;
        cancelAlignment();
        cancelKeyMotion();
        cancelKeyEdge();
        clearTimeout(fitTimer);
        clearTimeout(saveTimer);
        if (browserMotion || suspend) {
          browserMotion = null;
          window.scrollTo({ top: scrollY, behavior: 'instant' });
        }
        if (suspend) suspended = true;
        lastFit = null;
        lastOwnedScroll = null;
        post({ type: 'intent', reason });
        return owner();
      };
      const postLinks = article => Array.from(article.querySelectorAll('a[href]')).flatMap(link => {
        if (link.closest('[data-testid="tweetText"], [data-testid="card.wrapper"], [data-testid="quoteTweet"]')) return [];
        let url;
        try { url = new URL(link.getAttribute('href'), location.href); } catch { return []; }
        if (url.origin !== location.origin && !/^(?:www\.)?(?:x\.com|twitter\.com)$/.test(url.hostname)) return [];
        const match = url.pathname.match(/^\/[^/]+\/status\/(\d+)(?:\/(analytics|photo\/\d+|video\/\d+))?\/?$/);
        return match ? [{ link, url, id: match[1], canonical: !match[2] }] : [];
      });
      const postIdentity = article => {
        const links = postLinks(article);
        return links.find(item => item.link.querySelector('time')) || links.find(item => item.canonical) || links[0];
      };
      const postID = article => postIdentity(article)?.id || null;
      const postURL = article => {
        const identity = postIdentity(article);
        return identity ? `${identity.url.origin}${identity.url.pathname.match(/^\/[^/]+\/status\/\d+/)[0]}` : '';
      };
      const remember = (checkpoint = false) => {
        if (restoring || (suspended && !checkpoint)) return;
        const anchors = Array.from(document.querySelectorAll('article[data-testid="tweet"]'))
          .map(article => {
            const cell = isHome() ? article.closest('[data-testid="cellInnerDiv"]') : null;
            return { id: postID(article), rect: (cell || article).getBoundingClientRect(),
              box: cell ? 'cell' : 'article', url: postURL(article) };
          })
          .filter(a => a.id && a.rect.bottom > 1 && a.rect.top < innerHeight - 1)
          .slice(0, 3).map(a => ({ id: a.id, top: a.rect.top, url: a.url, box: a.box }));
        if (!anchors.length) return;
        const position = { ...owner(), anchors, y: scrollY, userRead, restoring: !!restoring, snapshotRevision: ++snapshotRevision };
        positions.set(entryKey(), position);
        if (positions.size > 40) positions.delete(positions.keys().next().value);
        return position;
      };
      const cancelRestore = () => { restoring = null; scheduleFit(); };
      const restoreFrame = pending => {
        if (restoring !== pending || !owns(pending.owner)) return;
        // This bounded restore uses tasks, not animation frames: WebKit can
        // suspend frames in a background widget even after its DOM is ready.
        if (!pending.deadline) {
          pending.deadline = performance.now() + (pending.initial ? 15000 : 1200);
        }
        if (performance.now() > pending.deadline) { finishMissingRestore(); return; }
        // Wait for the destination DOM, not the previous comments page.
        const statusID = location.pathname.match(/\/status\/(\d+)/)?.[1];
        const ready = location.pathname === '/home' || location.pathname === '/'
          ? !!document.querySelector('[aria-label="Timeline: Your Home Timeline"]')
          : statusID
            ? postID(document.querySelector('article[data-testid="tweet"]') || document.createElement('div')) === statusID
            : !!document.querySelector('[data-testid="primaryColumn"]');
        if (ready) {
          if (pending.initial && !pending.triedOffset && document.documentElement.scrollHeight >= pending.saved.y + innerHeight) {
            // React may render after WebKit has attempted its initial restore.
            // One offset restore also lets virtualized rows near that point render.
            pending.triedOffset = true;
            scrollToOwned(pending.owner, pending.saved.y, true);
          }
          const articles = Array.from(document.querySelectorAll('article[data-testid="tweet"]'));
          let matched = false;
          for (const anchor of pending.saved.anchors) {
            const article = articles.find(a => postID(a) === anchor.id);
            if (!article) continue;
            matched = true;
            // Home remembers the page boundary, independent of the
            // post changing height. Comments remember the article position.
            const box = anchor.box === 'cell' ? article.closest('[data-testid="cellInnerDiv"]') || article : article;
            const delta = box.getBoundingClientRect().top - anchor.top;
            if (Math.abs(delta) > 1) scrollToOwned(pending.owner, scrollY + delta, true);
            // Hydration may outlast the settling interval. Start that interval
            // when the anchor appears, and restart it after a router correction.
            if (pending.anchorID !== anchor.id || Math.abs(delta) > 1) {
              pending.anchorID = anchor.id;
              pending.settleAt = performance.now() + (pending.initial ? 180 : 160);
            }
            if (performance.now() > pending.settleAt && Math.abs(box.getBoundingClientRect().top - anchor.top) <= 1) {
              cancelRestore(); publishPosition(); return;
            }
            break;
          }
          // A ranked Home feed can replace every saved post on restart.
          // Once its new rows have settled, open a whole available post.
          if (!matched && isHome() && articles.length) {
            pending.missingSince ||= performance.now();
            if (performance.now() - pending.missingSince > 1500) { finishMissingRestore(); return; }
          }
        }
        setTimeout(() => restoreFrame(pending), ready ? 16 : 100);
      };
      const finishMissingRestore = () => {
        cancelRestore();
        if (isHome()) {
          alignmentTarget = postID(visibleCell()?.querySelector('article[data-testid="tweet"]') || document.createElement('div'));
          lastFit = null;
        }
        remember();
      };
      const beginRestore = (saved, initial = false) => {
        const token = invalidate('restore');
        initialAlignment = false;
        interruptedRestore = null;
        suspendCheckpoint = null;
        const pending = { saved, initial, owner: token };
        restoring = pending;
        setTimeout(() => restoreFrame(pending), 0);
      };
      const restoreEntry = () => {
        const saved = positions.get(entryKey());
        if (!saved || saved.url !== location.href) return;
        beginRestore(saved);
      };
      const interruptedSnapshot = pending => ({ ...pending.saved, ...owner(), restoring: true,
        snapshotRevision: ++snapshotRevision, historyPositions: Array.from(positions.entries()) });
      const readingSnapshot = (checkpoint = false) => {
        if (interruptedRestore) return interruptedSnapshot(interruptedRestore);
        const current = remember(checkpoint);
        return current ? { ...current, historyPositions: Array.from(positions.entries()) } : null;
      };
      const publishPosition = () => {
        suspendCheckpoint = null;
        const position = readingSnapshot(true);
        if (suspended) suspendCheckpoint = position;
        if (position) post({ type: 'saveSession', position });
      };
      window.__tfReadingPosition = readingSnapshot;
      window.__tfRestorePosition = (saved, expected) => {
        if (!owns(expected)) return false;
        if (!saved || saved.url !== location.href || !Array.isArray(saved.anchors) || !Number.isFinite(saved.y)) return;
        if (Array.isArray(saved.historyPositions)) {
          for (const [key, position] of saved.historyPositions.slice(-40)) positions.set(key, position);
        }
        const current = { url: saved.url, anchors: saved.anchors, y: saved.y };
        positions.set(entryKey(), current);
        beginRestore(current, true);
        return true;
      };
      window.__tfCheckpoint = ({ suspend = false } = {}) => {
        const interrupted = restoring || interruptedRestore;
        invalidate('checkpoint', suspend);
        firstUpAt = 0;
        if (interrupted) { interruptedRestore = interrupted; return interruptedSnapshot(interrupted); }
        if (suspendCheckpoint) return { ...suspendCheckpoint, ...owner(), snapshotRevision: ++snapshotRevision };
        const snapshot = readingSnapshot(true);
        if (suspend && snapshot) suspendCheckpoint = snapshot;
        return snapshot;
      };
      window.__tfActivate = () => {
        const saved = suspendCheckpoint;
        invalidate('activate');
        suspended = false;
        firstUpAt = 0;
        suspendCheckpoint = null;
        if (saved && saved.documentId === documentId && saved.entryKey === entryKey() && saved.url === location.href) {
          let destination = saved.y;
          for (const anchor of saved.anchors) {
            const article = Array.from(document.querySelectorAll('article[data-testid="tweet"]')).find(a => postID(a) === anchor.id);
            if (!article) continue;
            const box = anchor.box === 'cell' ? article.closest('[data-testid="cellInnerDiv"]') || article : article;
            destination = scrollY + box.getBoundingClientRect().top - anchor.top;
            break;
          }
          if (Number.isFinite(destination) && Math.abs(scrollY - destination) > 1) scrollToOwned(owner(), destination);
        }
        scheduleFit();
        return owner();
      };
      for (const type of ['wheel', 'pointerdown', 'touchstart', 'keydown']) {
        window.addEventListener(type, event => {
          wheelBasis = type === 'wheel' && scrollIntent ? { event, distance: scrollIntent.distance, target: scrollIntent.target } : null;
          keyBasis = type === 'keydown' && keyMotion ? { event, id: keyMotion.id, offset: keyMotion.offset } : null;
          invalidate('input');
          if (type !== 'keydown' || event.key !== 'ArrowUp' || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) firstUpAt = 0;
          userRead = true;
        }, { capture: true, passive: true });
      }
      document.addEventListener('click', () => { remember(); invalidate('click'); }, true);
      let readingFrame = false;
      window.addEventListener('scroll', () => {
        if (suspended) return;
        if (!restoring && !keyMotion && !scrollIntent && !browserMotion
            && pendingFit && Math.abs(scrollY - pendingFit.y) > 1
            && !(lastOwnedScroll && owns(lastOwnedScroll) && Math.abs(scrollY - lastOwnedScroll.y) <= 1)) {
          invalidate('scroll');
        }
        if (browserMotion && owns(browserMotion)) {
          const target = cellFor(browserMotion.id);
          if (!target || Math.abs(target.getBoundingClientRect().top) <= 1) browserMotion = null;
        }
        if (readingFrame) return;
        readingFrame = true;
        const token = owner();
        requestAnimationFrame(() => { readingFrame = false; if (owns(token)) remember(); });
      }, { passive: true });

      const isHome = () => {
        const path = location.pathname || '';
        return path === '/home' || path === '/' || path === '';
      };

      const modeOf = () => {
        const path = location.pathname || '';
        if (path.includes('/login') || path.includes('/i/flow') || path.includes('/logout')) return 'login';
        if (/\/status\/\d+/.test(path)) return 'detail';
        if (isHome()) {
          if (document.querySelector('[data-testid="loginButton"], [data-testid="signupButton"]')) return 'login';
          return rows().length ? 'timeline' : 'wait';
        }
        if (!document.querySelector('[data-testid="primaryColumn"]')) return 'login';
        return 'page';
      };

      window.__tfMode = modeOf;

      // Glass: X renders its dark theme, and opaque black fills become clear so
      // the window's glass shows through. Dark and Light are X's own themes,
      // left untouched.
      const isBlackFill = (value) => {
        const m = value && value.match(/rgba?\(([^)]+)\)/);
        if (!m) return false;
        const parts = m[1].split(',').map((p) => parseFloat(p));
        const alpha = parts.length > 3 ? parts[3] : 1;
        return alpha > 0.9 && parts[0] < 24 && parts[1] < 24 && parts[2] < 24;
      };

      const clearFills = () => {
        const root = document.querySelector('main') || document.body;
        if (!root) return;
        const chain = [];
        for (let el = root; el; el = el.parentElement) chain.push(el);
        for (const el of chain.concat(Array.from(root.querySelectorAll('div, section, main, header, article')))) {
          if (el.hasAttribute('data-tf-fill')) continue;
          if (el.closest('[data-testid="tweetPhoto"], [data-testid="videoPlayer"], [data-testid="videoComponent"], [data-testid="card.wrapper"] img')) continue;
          const style = el.style && el.style.backgroundImage;
          if (style && style !== 'none') continue;
          if (isBlackFill(getComputedStyle(el).backgroundColor)) el.setAttribute('data-tf-fill', '');
        }
      };

      const applyChrome = () => {
        const mode = modeOf();
        let tag = document.getElementById('__tf');
        if (mode === 'login') {
          if (tag) tag.remove();
          return;
        }
        if (!tag) {
          tag = document.createElement('style');
          tag.id = '__tf';
          document.documentElement.appendChild(tag);
        }
        const theme = window.__tfTheme || 'glass';
        const css = [
          '[data-testid="sidebarColumn"], header[role="banner"], [data-testid="BottomBar"], [data-testid="AppTabBar"], [data-testid="DMDrawer"], [data-testid="GrokDrawer"] { display: none !important; }',
          'a[href="/compose/post"], [data-testid="SideNav_NewTweet_Button"], [data-testid="FloatingActionButtons_Tweet_Button"] { display: none !important; }',
          'main[role="main"] { align-items: stretch !important; }',
          '[data-testid="primaryColumn"] { max-width: 100% !important; width: 100% !important; margin: 0 !important; border: 0 !important; }',
          'main[role="main"] > div, main[role="main"] > div > div, main[role="main"] > div > div > div { max-width: 100% !important; width: 100% !important; margin: 0 !important; padding: 0 !important; }',
          // clip, not hidden: hidden on body would make body its own scroller
          // and leave the window (which X and this script scroll) stuck at 0.
          'html, body { overflow-x: clip !important; }',
          // Hide scroll indicators without changing the page's scrolling boxes.
          '* { scrollbar-width: none !important; }',
          '::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }',
          '[data-tf-new-posts] { display: none !important; }',
        ];
        if (mode === 'timeline') {
          css.push(
            '[data-testid="primaryColumn"] div:has([data-testid="tweetTextarea_0"]):not(:has(article[data-testid="tweet"])) { display: none !important; }',
            '[data-testid="cellInnerDiv"]:has(article[data-testid="tweet"]) { min-height: 88px !important; }',
            '[data-testid="cellInnerDiv"] article[data-testid="tweet"] { width: 100% !important; border-bottom: 0 !important; }'
          );
        }
        if (theme === 'glass') {
          css.push(
            'html, body, #react-root, [data-tf-fill] { background-color: transparent !important; }',
            'html { color-scheme: dark !important; }'
          );
          if (window.__tfClearGlass) css.push('article [data-testid="tweetText"], article [data-testid="User-Name"] { text-shadow: 0 1px 2px rgba(0, 0, 0, 0.5); }');
        }
        const text = css.join('\n');
        if (tag.textContent !== text) tag.textContent = text;
        if (theme === 'glass') clearFills();

        // Refresh pills can hydrate outside the primary column and can use
        // translated text. Identify chrome by its position and post exclusion.
        document.querySelectorAll('[data-tf-new-posts]').forEach(el => {
          if (mode !== 'timeline') el.removeAttribute('data-tf-new-posts');
        });
        if (mode === 'timeline') {
          document.querySelectorAll('[data-testid], button, [role="button"]').forEach(el => {
            if (el.closest('article, [data-testid="cellInnerDiv"], [role="dialog"], [role="menu"]')) return;
            const marker = el.getAttribute('data-testid') || '';
            const marked = /(?:new.*(?:tweet|post)|(?:tweet|post).*new|pillLabel)/i.test(marker)
              || /^(?:show|see)(?:\s+\d+)?\s+new\s+(?:posts|tweets)$/i.test(el.getAttribute('aria-label') || '');
            const floating = el.matches('button, [role="button"]') && (() => {
              for (let parent = el; parent && parent !== document.body; parent = parent.parentElement) {
                if (/fixed|sticky/.test(getComputedStyle(parent).position)) return true;
              }
              return false;
            })();
            if (marked || floating) {
              let pill = el.closest('button, [role="button"]') || el;
              for (let parent = pill; parent && parent !== document.body; parent = parent.parentElement) {
                if (parent.querySelector('article, [data-testid="cellInnerDiv"]')) break;
                if (/fixed|sticky/.test(getComputedStyle(parent).position)) { pill = parent; break; }
              }
              pill.setAttribute('data-tf-new-posts', '');
            }
          });
        }

        // The home feed's sticky tabs and "new posts" pill sit over the post.
        // Elsewhere X's sticky header is the back button, so it stays.
        const column = document.querySelector('[data-testid="primaryColumn"]');
        if (column) {
          column.querySelectorAll('[data-tf-hidden]').forEach((el) => {
            if (mode !== 'timeline') { el.style.removeProperty('display'); el.removeAttribute('data-tf-hidden'); }
          });
          if (mode === 'timeline') {
            let seen = 0;
            const walker = document.createTreeWalker(column, NodeFilter.SHOW_ELEMENT);
            let el = walker.nextNode();
            while (el && seen < 400) {
              seen += 1;
              if (!el.hasAttribute('data-tf-hidden') && !el.closest('[data-testid="cellInnerDiv"]')) {
                const pos = getComputedStyle(el).position;
                if (pos === 'sticky' || pos === 'fixed') {
                  el.style.setProperty('display', 'none', 'important');
                  el.setAttribute('data-tf-hidden', '');
                }
              }
              el = walker.nextNode();
            }
          }
        }
      };

      const feedCells = () => Array.from(rows(), article => article.closest('[data-testid="cellInnerDiv"]'));
      const cellFor = id => feedCells().find(cell => postID(cell.querySelector('article[data-testid="tweet"]')) === id);
      const visibleCell = () => feedCells().find(cell => {
        const rect = cell.getBoundingClientRect();
        return rect.top <= 1 && rect.bottom > 1;
      }) || feedCells().find(cell => cell.getBoundingClientRect().bottom > 1);
      // Observe only the selected post. Its natural height is independent of
      // the viewport, so fitting the window cannot grow every other feed cell.
      const postSize = new ResizeObserver(() => scheduleFit());
      const fitPost = (keyboard = false, keyboardTop = 0) => {
        if ((!keyboard && (keyMotion || keyEdge)) || restoring || scrollIntent || modeOf() !== 'timeline' || document.querySelector('[role=dialog], [role=menu], [role=listbox]')) return;
        const cell = alignmentTarget ? cellFor(alignmentTarget) : visibleCell();
        if (!cell) return;
        if (activeCell !== cell) {
          postSize.disconnect();
          activeCell = cell;
          postSize.observe(cell);
        }
        const rect = cell.getBoundingClientRect();
        const id = postID(cell.querySelector('article[data-testid="tweet"]'));
        const height = Math.ceil(rect.height);
        const key = `${id}:${height}:${innerWidth}`;
        const preserveOffset = !keyboard && !alignmentTarget && !initialAlignment;
        const top = keyboard ? keyboardTop : preserveOffset ? rect.top : 0;
        alignmentTarget = null;
        if (!id || height < 40 || key === lastFit) return;
        lastFit = key;
        pendingFit = { ...owner(), serial: ++fitSerial, id, top, y: scrollY, keyboard, preserveOffset, geometryOnly: suspended, initialAlignment };
        post({ type: 'fitPost', ...pendingFit, height, width: innerWidth });
      };
      const scheduleFit = () => {
        clearTimeout(fitTimer);
        fitTimer = setTimeout(fitPost, 200);
      };
      window.__tfBeginResize = () => invalidate('resize');
      window.__tfRefit = () => { lastFit = null; scheduleFit(); };
      window.__tfDidFit = (envelope, height) => {
        if (!pendingFit || pendingFit.serial !== envelope?.serial || !owns(envelope) || (suspended && !pendingFit.geometryOnly)) return;
        const saved = pendingFit;
        pendingFit = null;
        if (restoring || scrollIntent || (saved.keyboard && keyMotion)) return;
        const expectedY = lastOwnedScroll && owns(lastOwnedScroll) && lastOwnedScroll.fitSerial === saved.serial ? lastOwnedScroll.y : saved.y;
        // Compositor movement can precede passive wheel/scroll delivery.
        // An old resize is never permission to return to its former post.
        if (Math.abs(scrollY - expectedY) > 1) return;
        const cell = cellFor(saved.id);
        if (!cell) return;
        const rect = cell.getBoundingClientRect();
        const top = saved.preserveOffset ? saved.top : rect.height <= height + 1 ? 0 : saved.top;
        const delta = rect.top - top;
        if (Math.abs(delta) > 1) scrollToOwned(saved, scrollY + delta, saved.geometryOnly);
        if (saved.initialAlignment || (saved.geometryOnly && !saved.preserveOffset)) {
          initialAlignment = false;
          // Replace provisional or missing-anchor state after owned alignment;
          // activation must not replay the unfinished startup destination.
          publishPosition();
        }
        remember();
        saveAfterReading();
      };
      window.addEventListener('resize', scheduleFit);
      window.addEventListener('scroll', scheduleFit, { passive: true });

      // Keep native wheel movement and momentum. Once that gesture ends, ask
      // the browser to align one post. CSS scroll-snap retains stale targets
      // across X's virtualized Back navigation, so it cannot own this step.
      const alignAfterScroll = () => {
        if (!scrollIntent || suspended) return;
        const intent = scrollIntent;
        clearTimeout(alignmentTimer);
        alignmentTimer = setTimeout(() => {
          if (scrollIntent !== intent || !owns(intent)) return;
          scrollIntent = null;
          if (!intent || restoring || modeOf() !== 'timeline' || intent.distance < 8) return;
          const cells = Array.from(document.querySelectorAll('[data-testid="cellInnerDiv"]:has(article[data-testid="tweet"])'))
            .map(cell => ({ cell, rect: cell.getBoundingClientRect() }));
          // A tall post may stop anywhere while it still fills the viewport.
          if (cells.some(({rect}) => rect.top <= 1 && rect.bottom >= innerHeight - 1)) return;
          const target = intent.direction > 0
            ? cells.find(({rect}) => rect.top > 1)
            : cells.filter(({rect}) => rect.top < -1).at(-1);
          if (target) {
            alignmentTarget = postID(target.cell.querySelector('article[data-testid="tweet"]'));
            browserMotion = { ...owner(), id: alignmentTarget };
            target.cell.scrollIntoView({ block: 'start', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
          }
          scheduleFit();
        }, 150);
      };
      window.addEventListener('wheel', (event) => {
        if (suspended || modeOf() !== 'timeline' || event.defaultPrevented || event.ctrlKey || !event.deltaY || Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
        const target = event.target instanceof Element ? event.target : null;
        if (target?.closest('[role="dialog"], [role="menu"], [role="listbox"]')) { cancelAlignment(); return; }
        if (scrollIntent?.target !== target) {
          for (let el = target; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
            if (el.scrollHeight > el.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(el).overflowY)) { cancelAlignment(); return; }
          }
        }
        // The compositor may scroll before this passive event reaches JS.
        // Measure intent from the wheel input, not an already-updated offset.
        if (!scrollIntent) scrollIntent = { ...owner(), distance: wheelBasis?.event === event && wheelBasis.target === target ? wheelBasis.distance : 0 };
        scrollIntent.target = target;
        scrollIntent.direction = Math.sign(event.deltaY);
        scrollIntent.distance += Math.abs(event.deltaY) * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? innerHeight : 1);
        alignAfterScroll();
      }, { passive: true });
      window.addEventListener('scroll', alignAfterScroll, { passive: true });
      

      const update = () => {
        applyChrome();
        const mode = modeOf();
        if (mode !== lastMode) {
          lastMode = mode;
          lastFit = null;
          pendingFit = null;
          activeCell = null;
          postSize.disconnect();
          post({ type: 'mode', mode });
        }
        scheduleFit();
      };
      let scheduled = false;
      const scheduleUpdate = () => {
        if (scheduled) return;
        scheduled = true;
        setTimeout(() => { scheduled = false; update(); }, 0);
      };
      const observer = new MutationObserver((records) => {
        // Text-only changes such as video clocks do not require a style pass.
        // Hydration can attach post markers to nodes that are already present.
        if (records.some(r => r.type === 'attributes'
          ? r.attributeName === 'data-testid' || !r.target.closest('article, [data-testid=cellInnerDiv]')
          : Array.from(r.addedNodes).some(n => n.nodeType === Node.ELEMENT_NODE))) scheduleUpdate();
      });
      observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-testid', 'role', 'style', 'aria-label'] });

      const saveAfterReading = () => {
        clearTimeout(saveTimer);
        if (suspended) return;
        const token = owner();
        saveTimer = setTimeout(() => { if (owns(token) && !suspended) post({ type: 'saveSession', position: readingSnapshot() }); }, 500);
      };
      window.addEventListener('scroll', saveAfterReading, { passive: true });
      const routeChanged = () => {
        invalidate('navigation');
        firstUpAt = 0;
        userRead = false;
        lastFit = null;
        scheduleUpdate();
      };
      for (const name of ['pushState', 'replaceState']) {
        const original = history[name];
        history[name] = function(...args) {
          const before = `${entryKey()}:${location.href}`;
          remember();
          const result = original.apply(this, args);
          if (name === 'pushState' || before !== `${entryKey()}:${location.href}`) routeChanged();
          return result;
        };
      }
      window.addEventListener('popstate', () => { routeChanged(); restoreEntry(); saveAfterReading(); });
      window.addEventListener('pagehide', () => post({ type: 'saveSession', position: window.__tfCheckpoint({ suspend: true }) }));
      document.addEventListener('visibilitychange', () => {
        if (document.hidden) post({ type: 'saveSession', position: window.__tfCheckpoint({ suspend: true }) });
        else post({ type: 'activity', visible: true });
      });

      // Keyboard movement selects the destination before either animation
      // starts. Repeated keys replace the current animation, never queue it.
      const moveWithKeys = (cell, offset = 0) => {
        cancelKeyMotion();
        clearTimeout(fitTimer);
        const id = postID(cell.querySelector('article[data-testid="tweet"]'));
        if (!id || suspended) return;
        alignmentTarget = id;
        const start = scrollY;
        const motion = { ...owner(), id, offset, started: performance.now() };
        keyMotion = motion;
        lastFit = null;
        fitPost(true, -offset);
        const duration = matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 200;
        const step = now => {
          if (keyMotion !== motion || !owns(motion) || suspended) return;
          const target = cellFor(id);
          if (!target || modeOf() !== 'timeline') { invalidate('target-lost'); scheduleFit(); return; }
          const progress = duration ? Math.min(1, (now - motion.started) / duration) : 1;
          const eased = progress * progress * (3 - 2 * progress);
          const destination = Math.max(0, scrollY + target.getBoundingClientRect().top + offset);
          scrollToOwned(motion, start + (destination - start) * eased);
          if (progress < 1) keyFrame = requestAnimationFrame(step);
          else {
            keyMotion = null;
            remember();
            saveAfterReading();
          }
        };
        keyFrame = requestAnimationFrame(step);
      };
      // Virtualized feeds may not have inserted the adjacent row yet. One
      // edge scroll lets the site render it; only this bounded wait follows.
      const waitForAdjacentRow = (cell, direction) => {
        const pending = { ...owner(), id: postID(cell.querySelector('article[data-testid="tweet"]')), deadline: performance.now() + 1000 };
        keyEdge = pending;
        browserMotion = { ...pending };
        window.scrollBy({ top: direction * Math.max(80, innerHeight * 0.8), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
        const check = () => {
          if (keyEdge !== pending || !owns(pending) || suspended) return;
          if (performance.now() >= pending.deadline || modeOf() !== 'timeline' || document.hidden || document.querySelector('[role="dialog"], [role="menu"]')) { cancelKeyEdge(); scheduleFit(); return; }
          const cells = feedCells();
          const current = cells.findIndex(c => postID(c.querySelector('article[data-testid="tweet"]')) === pending.id);
          const next = current >= 0 ? cells[current + direction] : null;
          if (next) { cancelKeyEdge(); moveWithKeys(next); return; }
          setTimeout(check, 100);
        };
        setTimeout(check, 100);
      };
      window.addEventListener('keydown', (event) => {
        if (!['ArrowLeft', 'ArrowUp', 'ArrowDown', 'Enter'].includes(event.key) || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || event.isComposing || event.defaultPrevented) return;
        const active = document.activeElement;
        const target = event.target instanceof Element ? event.target : active;
        const controls = 'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], button, [role="button"], [role="slider"], [role="tab"], [role="menuitem"], [role="dialog"], video, audio';
        if (active?.closest(controls) || target?.closest(controls) || document.querySelector('[role="dialog"], [role="menu"], [role="listbox"]')) { firstUpAt = 0; return; }
        if (event.key === 'Enter' && active?.closest('a[href]')) return;
        if (!window.getSelection()?.isCollapsed) { firstUpAt = 0; return; }
        for (let el = target; el && el !== document.body && el !== document.documentElement; el = el.parentElement) {
          if (el.scrollHeight > el.clientHeight + 1 && /auto|scroll/.test(getComputedStyle(el).overflowY)) return;
        }
        const mode = modeOf();
        if (event.key === 'ArrowLeft') {
          if (mode !== 'detail' && mode !== 'page') return;
          event.preventDefault(); event.stopImmediatePropagation();
          if (event.repeat) return;
          post({ type: 'back' });
          return;
        }
        if (mode !== 'timeline' || suspended) return;
        const cells = feedCells();
        const basis = keyBasis?.event === event ? keyBasis : null;
        const cell = (basis && cellFor(basis.id)) || visibleCell();
        if (!cell) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        if (event.key !== 'Enter' && active?.closest('a[href]')) active.blur();
        if (event.key === 'ArrowUp' && !event.repeat) {
          const now = performance.now();
          if (firstUpAt && now - firstUpAt <= 350) {
            firstUpAt = 0;
            invalidate('refresh');
            post({ type: 'refreshHome' });
            return;
          }
          firstUpAt = now;
        }
        if (event.key === 'Enter') {
          firstUpAt = 0;
          if (basis) { scrollToOwned(owner(), scrollY + cell.getBoundingClientRect().top); remember(); }
          const article = cell.querySelector('article[data-testid="tweet"]');
          const id = postID(article);
          const link = postLinks(article).find(item => item.canonical && item.id === id)?.link;
          if (link) link.click();
          // Ads may expose only analytics as an identity. Let X's existing
          // article handler open its post, without activating an action/card.
          else if (id) article.click();
          return;
        }
        const direction = event.key === 'ArrowDown' ? 1 : -1;
        const rect = cell.getBoundingClientRect();
        const cellY = scrollY + rect.top;
        const readingY = basis ? cellY + basis.offset : scrollY;
        const fittedHeight = Math.max(88, Math.min(rect.height, window.__tfPostHeightLimit || innerHeight));
        const bottomOffset = Math.max(0, rect.height - fittedHeight);
        const offset = Math.max(0, Math.min(bottomOffset, readingY - cellY));
        const atEdge = direction > 0 ? offset >= bottomOffset - 1 : offset <= 1;
        if (!atEdge) {
          moveWithKeys(cell, Math.max(0, Math.min(bottomOffset, offset + direction * fittedHeight * 0.8)));
          return;
        }
        const index = cells.indexOf(cell);
        const next = cells[index + direction];
        if (next) {
          moveWithKeys(next);
        } else if (direction < 0 && index === 0 && cellY > 1) {
          waitForAdjacentRow(cell, -1);
        } else if (direction > 0) { waitForAdjacentRow(cell, 1); }
      }, true);
      window.__tfMode = modeOf;
      window.__tfPaint = update;
      post({ type: 'ready' });
      update();
    })();
    """#
}

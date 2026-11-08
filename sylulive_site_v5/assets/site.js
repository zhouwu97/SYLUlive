/* Shared progressive enhancement. The document stays readable without JavaScript. */
(() => {
  const nav = document.getElementById('nav');
  const menu = document.getElementById('menu');
  function closeMenu(returnFocus = false) {
    nav?.classList.remove('open');
    menu?.setAttribute('aria-expanded', 'false');
    menu?.setAttribute('aria-label', '打开导航');
    if (returnFocus) menu?.focus();
  }
  menu?.addEventListener('click', () => {
    const open = nav.classList.toggle('open');
    menu.setAttribute('aria-expanded', String(open));
    menu.setAttribute('aria-label', open ? '关闭导航' : '打开导航');
  });
  document.querySelectorAll('.nav-links a').forEach(link => link.addEventListener('click', () => closeMenu()));
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && nav?.classList.contains('open')) closeMenu(true);
  });
  document.addEventListener('click', event => {
    if (nav && !nav.contains(event.target)) closeMenu();
  });
  nav?.addEventListener('focusout', event => {
    if (!nav.contains(event.relatedTarget)) closeMenu();
  });
  const mobile = matchMedia('(max-width: 800px)');
  mobile.addEventListener('change', () => closeMenu());
  function paintNav() { nav?.classList.toggle('scrolled', scrollY > 20); }
  paintNav();
  addEventListener('scroll', paintNav, {passive: true});

  const tabs = [...document.querySelectorAll('.life-tab')];
  const panels = [...document.querySelectorAll('.life-content')];
  function selectLife(next) {
    tabs.forEach((tab, i) => {
      const active = i === next;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      tab.classList.toggle('active', active);
      panels[i].hidden = !active;
      panels[i].setAttribute('aria-hidden', String(!active));
      panels[i].classList.toggle('active', active);
    });
  }
  tabs.forEach((tab, i) => {
    tab.addEventListener('click', () => selectLife(i));
    tab.addEventListener('keydown', event => {
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 :
        ['ArrowRight', 'ArrowDown'].includes(event.key) ? (i + 1) % tabs.length :
        ['ArrowLeft', 'ArrowUp'].includes(event.key) ? (i - 1 + tabs.length) % tabs.length : null;
      if (next === null) return;
      event.preventDefault();
      selectLife(next);
      tabs[next].focus();
    });
  });
  // Treat missing screenshots as a recoverable presentation issue; keep their description.
  document.querySelectorAll('img').forEach(img => {
    function imageFailed() {
      if (img.dataset.fallback) return;
      img.dataset.fallback = 'true';
      img.classList.add('image-error');
      if (!img.alt) { img.hidden = true; return; }
      const note = document.createElement('p');
      note.className = 'image-error-note';
      note.textContent = `${img.alt}暂时未能加载，请刷新页面重试。`;
      img.insertAdjacentElement('afterend', note);
    }
    img.addEventListener('error', imageFailed);
    if (img.complete && img.naturalWidth === 0) imageFailed();
  });
  const sectionLinks = [...document.querySelectorAll('.nav-links a[href^="#"]')];
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (!entry.isIntersecting) return;
        sectionLinks.forEach(link => {
          if (link.hash === `#${entry.target.id}`) link.setAttribute('aria-current', 'location');
          else link.removeAttribute('aria-current');
        });
      });
    }, {rootMargin: '-15% 0px -55% 0px'});
    ['top', 'product', 'life', 'ai', 'open', 'faq'].forEach(id => {
      const section = document.getElementById(id);
      if (section) observer.observe(section);
    });
  }
})();

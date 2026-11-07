// Applies the brand Den pushed into the realm (rendered by footer.ftl as
// #cs-brand) to the login page: name, tagline, logo, colours, favicon and
// the background picture.
// Without it the neutral defaults from css/conservices.css stay.
(function () {
  function hexToHsl(v) {
    if (typeof v !== 'string') return null;
    var h = v.trim().replace(/^#/, '');
    if (h.length === 3) h = h.replace(/./g, '$&$&');
    if (!/^[0-9a-f]{6}$/i.test(h)) return null;
    var r = parseInt(h.slice(0, 2), 16) / 255;
    var g = parseInt(h.slice(2, 4), 16) / 255;
    var b = parseInt(h.slice(4, 6), 16) / 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var l = (max + min) / 2, s = 0, hue = 0;
    if (max !== min) {
      var d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      hue = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
      hue *= 60;
    }
    return [Math.round(hue), Math.round(s * 100), Math.round(l * 100)];
  }
  function hsl(c) { return 'hsl(' + c[0] + ' ' + c[1] + '% ' + c[2] + '%)'; }
  function clamp(n, lo, hi) { return Math.min(hi, Math.max(lo, n)); }

  /** Readable text colour on top of an HSL colour. */
  function onColor(c) {
    var h = c[0], s = c[1] / 100, l = c[2] / 100;
    var a = s * Math.min(l, 1 - l);
    function f(n) {
      var k = (n + h / 30) % 12;
      return l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    }
    function lin(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    var lum = 0.2126 * lin(f(0)) + 0.7152 * lin(f(8)) + 0.0722 * lin(f(4));
    return lum > 0.45 ? '#18181b' : '#ffffff';
  }

  var THEME_KEYS = ['primary', 'primary_hover', 'accent', 'background', 'muted', 'foreground', 'border'];

  // Same as darkTheme in Den (lib/brand.ts) and the modules (lib/moduleBrand.ts):
  // theme.dark overrides win, the rest is derived from the light palette.
  function darkTheme(theme) {
    if (!THEME_KEYS.some(function (k) { return hexToHsl(theme[k]); })) return null;
    var over = theme.dark && typeof theme.dark === 'object' ? theme.dark : {};
    var primary = hexToHsl(theme.primary) || [243, 75, 59];
    var bg = hexToHsl(theme.background);
    var tint = bg && bg[1] >= 10 ? bg : primary;
    var th = tint[0], ts = clamp(Math.round(tint[1] * 0.12), 3, 9);
    var accent = hexToHsl(theme.accent) || primary;
    var pl = clamp(primary[2], 58, 72);
    var d = {
      primary: [primary[0], primary[1], pl],
      primary_hover: [primary[0], primary[1], pl + 6],
      accent: [accent[0], Math.min(accent[1], 35), 22],
      background: [th, ts, 13],
      page: [th, ts, 10],
      muted: [th, ts + 1, 18],
      foreground: [th, 10, 96],
      border: [th, ts, 22]
    };
    THEME_KEYS.forEach(function (k) {
      var c = hexToHsl(over[k]);
      if (c) d[k] = c;
    });
    var page = hexToHsl(over.page);
    if (page) d.page = page;
    else if (hexToHsl(over.background)) d.page = [d.background[0], d.background[1], clamp(d.background[2] - 3, 0, 100)];
    if (hexToHsl(over.primary) && !hexToHsl(over.primary_hover)) {
      d.primary_hover = [d.primary[0], d.primary[1], clamp(d.primary[2] + 6, 0, 90)];
    }
    return d;
  }

  function block(sel, vars) {
    var lines = Object.keys(vars).map(function (k) { return '  ' + k + ': ' + vars[k] + ';'; });
    return lines.length ? sel + ' {\n' + lines.join('\n') + '\n}\n' : '';
  }

  function applyColours(theme) {
    var light = {}, dark = {};
    var p = hexToHsl(theme.primary);
    if (p) {
      light['--cs-primary'] = hsl(p);
      light['--cs-primary-fg'] = onColor(p);
      light['--cs-primary-hover'] = hsl(hexToHsl(theme.primary_hover) || [p[0], p[1], clamp(p[2] - 7, 5, 95)]);
    }
    // Den's light `muted` is the page behind the cards, `background` the cards.
    [['muted', '--cs-bg'], ['background', '--cs-surface'], ['foreground', '--cs-fg'], ['border', '--cs-border']].forEach(function (m) {
      var c = hexToHsl(theme[m[0]]);
      if (c) light[m[1]] = hsl(c);
    });
    var d = darkTheme(theme);
    if (d) {
      dark['--cs-bg'] = hsl(d.page);
      dark['--cs-surface'] = hsl(d.background);
      dark['--cs-fg'] = hsl(d.foreground);
      dark['--cs-border'] = hsl(d.border);
      dark['--cs-primary-dark'] = hsl(d.primary);
      dark['--cs-primary-dark-hover'] = hsl(d.primary_hover);
      dark['--cs-primary-dark-fg'] = onColor(d.primary);
    }
    var el = document.getElementById('cs-brand-style');
    if (!el) {
      el = document.createElement('style');
      el.id = 'cs-brand-style';
      document.head.appendChild(el);
    }
    el.textContent = block(':root', light) + block('html.pf-v5-theme-dark', dark);
  }

  function applyHeader(b) {
    var header = document.getElementById('kc-header-wrapper');
    if (!header) return;
    var name = (b.organization_name || '').trim();
    var tagline = (b.tagline || '').trim();
    if (!name && !b.logo_url) return;
    header.textContent = '';
    if (b.logo_url) {
      var img = document.createElement('img');
      img.className = 'cs-logo';
      img.alt = name;
      img.src = b.logo_url;
      header.appendChild(img);
    }
    if (name) {
      var title = document.createElement('span');
      title.textContent = name;
      header.appendChild(title);
    }
    if (tagline) {
      var sub = document.createElement('span');
      sub.className = 'cs-tagline';
      sub.textContent = tagline;
      header.appendChild(sub);
    }
  }

  function applyFavicon(b) {
    if (!b.favicon_url) return;
    var link = document.querySelector('link[rel="icon"]') || document.createElement('link');
    link.rel = 'icon';
    link.href = b.favicon_url;
    document.head.appendChild(link);
  }

  // Picture behind the form: "panel" docks the form on the right (centred
  // card on narrow screens), "centered" keeps the card over a dimmed picture.
  function applyBackground(b) {
    if (typeof b.background_url !== 'string' || !b.background_url) return;
    var root = document.documentElement;
    root.style.setProperty('--cs-login-image', 'url(' + JSON.stringify(b.background_url) + ')');
    root.classList.add('cs-has-bg', b.login_layout === 'centered' ? 'cs-layout-centered' : 'cs-layout-panel');
    var caption = (b.login_caption || '').trim();
    var login = document.querySelector('.pf-v5-c-login');
    if (caption && login) {
      var el = document.createElement('p');
      el.className = 'cs-caption';
      el.textContent = caption;
      login.appendChild(el);
    }
  }

  function apply() {
    var el = document.getElementById('cs-brand');
    if (!el) return;
    var b;
    try {
      b = JSON.parse(el.getAttribute('data-brand') || '');
    } catch (e) {
      return;
    }
    if (!b || typeof b !== 'object') return;
    applyColours(b.theme || {});
    applyHeader(b);
    applyFavicon(b);
    applyBackground(b);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply);
  else apply();
})();

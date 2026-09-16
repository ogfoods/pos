// PWA service worker + super admin sign-in alerts.
// Loaded on every page; the alert half only starts for super admins
// (common.js calls App.loginAlerts.start after requireAdmin).
(function () {
  const App = window.App;

  // -------------------------------------------------------------------
  // Service worker
  // -------------------------------------------------------------------
  // Registered relative to the page so the app works at a domain root and
  // under a GitHub Pages project path alike.
  let swReady = Promise.resolve(null);
  if ("serviceWorker" in navigator && location.protocol.startsWith("http")) {
    swReady = navigator.serviceWorker
      .register("sw.js")
      .then((reg) => {
        // A new shell is picked up on the next load; activate it right away.
        reg.addEventListener("updatefound", () => {
          const sw = reg.installing;
          if (!sw) return;
          sw.addEventListener("statechange", () => {
            if (sw.state === "installed" && navigator.serviceWorker.controller) sw.postMessage("SKIP_WAITING");
          });
        });
        return reg;
      })
      .catch(() => null);
  }

  // -------------------------------------------------------------------
  // Notifications
  // -------------------------------------------------------------------
  const supported = "Notification" in window;
  const permission = () => (supported ? Notification.permission : "denied");

  async function requestPermission() {
    if (!supported) return "denied";
    if (Notification.permission !== "default") return Notification.permission;
    try {
      return await Notification.requestPermission();
    } catch {
      return Notification.permission;
    }
  }

  // The Notification constructor throws on Android Chrome, so show through
  // the service worker registration whenever there is one.
  async function show(title, opts) {
    if (permission() !== "granted") return false;
    try {
      const reg = await swReady;
      if (reg && reg.showNotification) {
        await reg.showNotification(title, opts);
        return true;
      }
      new Notification(title, opts);
      return true;
    } catch {
      return false;
    }
  }

  // -------------------------------------------------------------------
  // Chime (browsers need a tap before audio can play)
  // -------------------------------------------------------------------
  // Three rising notes (C5, E5, G5), so it is not mistaken for the kitchen chime.
  const NOTES = [523.25, 659.25, 783.99];
  const NOTE_GAP = 0.13;
  const NOTE_LEN = 0.22;

  let audioCtx = null;
  function chime() {
    try {
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      if (audioCtx.state === "suspended") audioCtx.resume();
      const start = audioCtx.currentTime;
      NOTES.forEach((hz, i) => {
        const osc = audioCtx.createOscillator();
        const gain = audioCtx.createGain();
        osc.type = "sine";
        osc.frequency.value = hz;
        const t0 = start + i * NOTE_GAP;
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.3, t0 + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + NOTE_LEN);
        osc.connect(gain).connect(audioCtx.destination);
        osc.start(t0);
        osc.stop(t0 + NOTE_LEN + 0.05);
      });
    } catch {}
  }

  // -------------------------------------------------------------------
  // Sign-in alerts (super admin)
  // -------------------------------------------------------------------
  const CURSOR_KEY = "pos_login_cursor";
  const PREF_KEY = "pos_login_alerts";
  const POLL_MS = 60000;

  const store = {
    get(k, d) {
      try {
        const v = localStorage.getItem(k);
        return v === null ? d : v;
      } catch {
        return d;
      }
    },
    set(k, v) {
      try {
        localStorage.setItem(k, v);
      } catch {}
    },
  };

  let me = null;
  let on = store.get(PREF_KEY, "on") === "on";
  let cursor = Number(store.get(CURSOR_KEY, "")) || null;
  let timer = null, pending = null, busy = false, started = false;
  let bell = null;

  function start(admin) {
    if (started || !admin || admin.role !== "super") return;
    started = true;
    me = admin;
    mountBell();
    poll();
    subscribe();
    timer = setInterval(() => {
      if (!document.hidden) poll();
    }, POLL_MS);
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden) poll();
    });
  }

  // The database broadcasts an empty "login" event on topic "admin-logins".
  function subscribe() {
    try {
      App.db.channel("admin-logins").on("broadcast", { event: "login" }, schedulePoll).subscribe();
    } catch {}
  }

  const schedulePoll = () => {
    clearTimeout(pending);
    // The login row commits a moment before the ping reaches us.
    pending = setTimeout(poll, 400);
  };

  async function poll() {
    if (busy || !me) return;
    busy = true;
    try {
      const data = await App.rpc("recent_logins", { p_token: me.token, p_after_id: cursor });
      const rows = data.rows || [];
      const maxId = rows.reduce((m, r) => Math.max(m, r.id), Number(data.last_id) || 0);
      const first = cursor === null;
      cursor = maxId;
      store.set(CURSOR_KEY, String(cursor));
      // The first poll only learns the cursor; it must not replay old logins.
      if (first || !on) return;
      rows.filter((r) => String(r.username).toLowerCase() !== String(me.username).toLowerCase()).forEach(announce);
    } catch {
      // Offline or session expired; the next poll retries.
    } finally {
      busy = false;
    }
  }

  function announce(r) {
    const who = r.username;
    const role = r.role === "super" ? "Super admin" : "Admin";
    const at = App.fmtDate(r.created_at);
    App.toast(`${who} signed in · ${role}`, "info");
    chime();
    show(`${who} signed in`, {
      body: `${role} · ${at}${r.ip ? " · " + r.ip : ""}`,
      icon: "icons/icon-192.png",
      badge: "icons/badge-96.png",
      tag: "login-" + r.id, // same tag across tabs -> one notification
      renotify: true,
      data: { url: "audit.html" },
    });
  }

  // -------------------------------------------------------------------
  // Bell button in the top bar
  // -------------------------------------------------------------------
  function mountBell() {
    const bar = document.querySelector(".topbar-right");
    if (!bar || document.getElementById("login-bell")) return;
    bell = document.createElement("button");
    bell.id = "login-bell";
    bell.type = "button";
    bell.className = "btn btn-ghost btn-sm";
    bell.addEventListener("click", onBellClick);
    bar.insertBefore(bell, bar.firstChild);
    renderBell();
  }

  function renderBell() {
    if (!bell) return;
    const blocked = !supported || permission() === "denied";
    const label = blocked ? "🔕 Alerts blocked" : on ? "🔔 Sign-in alerts" : "🔕 Sign-in alerts";
    bell.textContent = label;
    bell.title = blocked
      ? "Allow notifications for this site in your browser settings."
      : on
      ? "You are notified when an admin signs in. Click to turn off."
      : "Click to be notified when an admin signs in.";
    bell.setAttribute("aria-pressed", String(on && !blocked));
  }

  async function onBellClick() {
    if (!supported) {
      App.toast("This browser cannot show notifications.", "error");
      return;
    }
    if (permission() === "denied") {
      App.toast("Notifications are blocked. Allow them in your browser settings.", "error");
      return;
    }
    if (!on) {
      on = true;
      store.set(PREF_KEY, "on");
      const p = await requestPermission();
      renderBell();
      chime(); // this click is the gesture that unlocks audio
      App.toast(p === "granted" ? "Sign-in alerts on." : "Alerts on in this tab. Allow notifications for pop-ups.", "info");
    } else {
      on = false;
      store.set(PREF_KEY, "off");
      renderBell();
      App.toast("Sign-in alerts off.", "info");
    }
  }

  // -------------------------------------------------------------------
  // Install button (Chrome / Edge / Android)
  // -------------------------------------------------------------------
  // Safari and Firefox never fire this event; there the user installs from
  // the browser menu ("Add to Home Screen").
  let installEvent = null;
  window.addEventListener("beforeinstallprompt", (e) => {
    e.preventDefault();
    installEvent = e;
    const bar = document.querySelector(".topbar-right");
    if (!bar || document.getElementById("install-btn")) return;
    const btn = document.createElement("button");
    btn.id = "install-btn";
    btn.type = "button";
    btn.className = "btn btn-ghost btn-sm";
    btn.textContent = "⬇ Install app";
    btn.title = "Install this app on your device.";
    btn.addEventListener("click", async () => {
      if (!installEvent) return;
      btn.disabled = true;
      installEvent.prompt();
      await installEvent.userChoice.catch(() => {});
      installEvent = null;
      btn.remove();
    });
    bar.insertBefore(btn, bar.firstChild);
  });
  window.addEventListener("appinstalled", () => {
    installEvent = null;
    document.getElementById("install-btn")?.remove();
  });

  App.loginAlerts = { start, poll };
  App.notify = { show, requestPermission, permission, supported, swReady, canInstall: () => !!installEvent };
})();

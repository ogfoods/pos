// PWA service worker, install button, and the super admin's sign-in alerts
// and approval queue.
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

  // Takes a notification down once it has been answered somewhere else.
  async function closeNotification(tag) {
    try {
      const reg = await swReady;
      if (!reg || !reg.getNotifications) return;
      (await reg.getNotifications({ tag })).forEach((n) => n.close());
    } catch {}
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
  // Sign-in alerts and approvals (super admin)
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
  let waiting = [];               // sign-ins still to be answered
  const listeners = new Set();    // pages that draw the waiting list

  const emit = () =>
    listeners.forEach((fn) => {
      try {
        fn(waiting);
      } catch {}
    });

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

  // The database broadcasts an empty "login" event on topic "admin-logins"
  // after a sign-in and after every approval or denial.
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

      // Who is waiting must be known before an alert is written, so the
      // alert can carry Approve / Deny.
      await refreshWaiting();

      // The first poll only learns the cursor; it must not replay old logins.
      if (first || !on) return;
      rows.filter((r) => String(r.username).toLowerCase() !== String(me.username).toLowerCase()).forEach(announce);
    } catch {
      // Offline or session expired; the next poll retries.
    } finally {
      busy = false;
    }
  }

  async function refreshWaiting() {
    if (!me) return waiting;
    try {
      waiting = await App.rpc("pending_logins", { p_token: me.token });
    } catch {
      waiting = [];
    }
    emit();
    return waiting;
  }

  const waitingFor = (username) =>
    waiting.find((w) => String(w.username).toLowerCase() === String(username).toLowerCase());

  function announce(r) {
    const who = r.username;
    const role = r.role === "super" ? "Super admin" : "Admin";
    const at = App.fmtDate(r.created_at);
    const w = waitingFor(who);
    chime();

    if (w) {
      actionToast(`${who} is waiting to be let in`, w.session_id);
      show(`${who} is waiting to be let in`, {
        body: `${role} · ${at}${r.ip ? " · " + r.ip : ""}`,
        icon: "icons/icon-192.png",
        badge: "icons/badge-96.png",
        tag: "approve-" + w.session_id,
        renotify: true,
        requireInteraction: true,
        actions: [
          { action: "approve", title: "Approve" },
          { action: "deny", title: "Deny" },
        ],
        data: { url: "dashboard.html", sessionId: w.session_id },
      });
      return;
    }

    App.toast(`${who} signed in · ${role}`, "info");
    show(`${who} signed in`, {
      body: `${role} · ${at}${r.ip ? " · " + r.ip : ""}`,
      icon: "icons/icon-192.png",
      badge: "icons/badge-96.png",
      tag: "login-" + r.id, // same tag across tabs -> one notification
      renotify: true,
      data: { url: "audit.html" },
    });
  }

  async function answer(sessionId, ok) {
    if (!me) return;
    const fn = ok ? "approve_login" : "deny_login";
    try {
      const res = await App.rpc(fn, { p_token: me.token, p_session_id: Number(sessionId) });
      App.toast(ok ? `${res.username} let in` : `${res.username} denied`, ok ? "success" : "info");
    } catch (err) {
      App.toast(err.message, "error");
    }
    closeNotification("approve-" + sessionId);
    await refreshWaiting();
  }

  // A toast carrying Approve / Deny, for the page the super admin is on.
  function actionToast(msg, sessionId) {
    let box = document.getElementById("toast-box");
    if (!box) {
      box = document.createElement("div");
      box.id = "toast-box";
      document.body.appendChild(box);
    }
    const t = document.createElement("div");
    t.className = "toast toast-info";
    t.innerHTML =
      `<div>${App.esc(msg)}</div>` +
      `<div class="toast-actions">` +
      `<button class="btn btn-sm" data-ok="1">Approve</button>` +
      `<button class="btn btn-ghost btn-sm" data-ok="0">Deny</button>` +
      `</div>`;
    t.addEventListener("click", (e) => {
      const b = e.target.closest("[data-ok]");
      if (!b) return;
      t.remove();
      answer(sessionId, b.dataset.ok === "1");
    });
    box.appendChild(t);
    // Stays long enough to act on; the dashboard banner keeps the list anyway.
    setTimeout(() => t.remove(), 30000);
  }

  // Approve / Deny tapped on the notification itself (relayed by sw.js).
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.addEventListener("message", (e) => {
      const d = e.data;
      if (!d || d.type !== "approval") return;
      answer(d.sessionId, d.action === "approve");
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
    const label = blocked ? "Alerts blocked" : "Sign-in alerts";
    // The label collapses to the emoji on narrow screens (see .btn-text).
    bell.innerHTML = `<span aria-hidden="true">${on && !blocked ? "🔔" : "🔕"}</span><span class="btn-text">${label}</span>`;
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
    btn.innerHTML = `<span aria-hidden="true">⬇</span><span class="btn-text">Install app</span>`;
    btn.setAttribute("aria-label", "Install app");
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
  App.approvals = {
    list: () => waiting,
    refresh: refreshWaiting,
    approve: (id) => answer(id, true),
    deny: (id) => answer(id, false),
    // Calls back now and on every change; returns an unsubscribe function.
    onChange(fn) {
      listeners.add(fn);
      fn(waiting);
      return () => listeners.delete(fn);
    },
  };
  App.notify = { show, requestPermission, permission, supported, swReady, canInstall: () => !!installEvent };
})();

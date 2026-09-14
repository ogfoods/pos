// Shared helpers used by every page.
(function () {
  const cfg = window.APP_CONFIG;
  const db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
  });

  const SESSION_KEY = "pos_admin_session";

  const session = {
    get() {
      try {
        const s = JSON.parse(localStorage.getItem(SESSION_KEY));
        if (!s || !s.token || new Date(s.expires_at) <= new Date()) return null;
        return s;
      } catch {
        return null;
      }
    },
    set(s) {
      localStorage.setItem(SESSION_KEY, JSON.stringify(s));
    },
    clear() {
      localStorage.removeItem(SESSION_KEY);
    },
  };

  async function rpc(fn, args) {
    const { data, error } = await db.rpc(fn, args);
    if (error) {
      if (error.code === "28000") {
        session.clear();
        location.href = "adminlogin.html";
      }
      throw new Error(error.message || "Request failed");
    }
    return data;
  }

  // Redirects to login if not signed in (or not super when required).
  async function requireAdmin({ superOnly = false } = {}) {
    const s = session.get();
    if (!s) {
      location.replace("adminlogin.html");
      return null;
    }
    const me = await rpc("admin_me", { p_token: s.token });
    session.set({ ...s, ...me });
    if (superOnly && me.role !== "super") {
      location.replace("dashboard.html");
      return null;
    }
    return { ...s, ...me };
  }

  async function logout() {
    const s = session.get();
    session.clear();
    if (s) {
      try {
        await db.rpc("admin_logout", { p_token: s.token });
      } catch {}
    }
    location.href = "adminlogin.html";
  }

  const money = (n) =>
    cfg.CURRENCY + Number(n || 0).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

  const fmtDate = (d) =>
    new Date(d).toLocaleString("en-IN", { dateStyle: "medium", timeStyle: "short" });

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const digits = (s) => String(s || "").replace(/\D/g, "");

  function toast(msg, type = "info") {
    let box = document.getElementById("toast-box");
    if (!box) {
      box = document.createElement("div");
      box.id = "toast-box";
      document.body.appendChild(box);
    }
    const t = document.createElement("div");
    t.className = "toast toast-" + type;
    t.textContent = msg;
    box.appendChild(t);
    setTimeout(() => t.remove(), 3500);
  }

  function renderItems(items) {
    return (items || [])
      .map((i) => `<li><span>${esc(i.name)} × ${i.qty}</span><span>${money(i.price * i.qty)}</span></li>`)
      .join("");
  }

  document.querySelectorAll("[data-shop-name]").forEach((el) => (el.textContent = cfg.SHOP_NAME));

  window.App = { cfg, db, rpc, session, requireAdmin, logout, money, fmtDate, esc, digits, toast, renderItems };
})();

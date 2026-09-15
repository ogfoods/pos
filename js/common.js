// Shared helpers used by every page.
(function () {
  const cfg = window.APP_CONFIG;
  const db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: false },
  });

  const SESSION_KEY = "pos_admin_session";
  const SETTINGS_KEY = "pos_settings";

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

  // Shop settings are edited on settings.html and stored in the database.
  // config.js values are fallbacks; the last loaded settings are cached for a fast first paint.
  const FALLBACK = {
    SHOP_NAME: cfg.SHOP_NAME,
    CURRENCY: cfg.CURRENCY,
    UPI_ID: cfg.UPI_ID,
    COUNTRY_CODE: cfg.COUNTRY_CODE || "91",
  };

  function applySettings(s) {
    if (s) {
      Object.assign(cfg, {
        SHOP_NAME: s.shop_name || FALLBACK.SHOP_NAME,
        CURRENCY: s.currency || FALLBACK.CURRENCY,
        UPI_ID: s.upi_id || FALLBACK.UPI_ID,
        COUNTRY_CODE: s.country_code || FALLBACK.COUNTRY_CODE,
        SHOP_ADDRESS: s.shop_address || "",
        SHOP_PHONE: s.shop_phone || "",
        RECEIPT_FOOTER: s.receipt_footer || "Thank you! Visit again.",
      });
      try {
        localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
      } catch {}
    }
    document.querySelectorAll("[data-shop-name]").forEach((el) => (el.textContent = cfg.SHOP_NAME));
  }

  let cached = null;
  try {
    cached = JSON.parse(localStorage.getItem(SETTINGS_KEY));
  } catch {}
  applySettings(cached);
  const settingsReady = db.rpc("get_settings").then(({ data }) => applySettings(data), () => {});

  // Redirects to login if not signed in (or not super when required).
  async function requireAdmin({ superOnly = false } = {}) {
    await settingsReady;
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

  const METHOD_LABELS = { cash: "Cash", upi: "UPI", card: "Card" };
  const methodLabel = (m) => METHOD_LABELS[m] || "—";

  const upiConfigured = () => !!cfg.UPI_ID && cfg.UPI_ID !== "sample@upi";

  // UPI deep link encoded in the payment QR.
  const upiLink = (amount) =>
    `upi://pay?pa=${encodeURIComponent(cfg.UPI_ID)}&pn=${encodeURIComponent(cfg.SHOP_NAME)}&am=${Number(amount).toFixed(2)}&cu=INR`;

  function renderQR(el, amount) {
    el.innerHTML = "";
    if (window.QRCode) new QRCode(el, { text: upiLink(amount), width: 200, height: 200, correctLevel: QRCode.CorrectLevel.M });
    else el.textContent = "QR unavailable";
    if (!upiConfigured()) el.insertAdjacentHTML("beforeend", `<div class="qr-warn">Sample UPI ID. Set your real one in Settings.</div>`);
  }

  // Receipt sized for a 58mm thermal printer. `o` is an order from create_order / get_order.
  function receiptHtml(o) {
    const items = (o.items || [])
      .map(
        (i) => `<div class="rc-item">${esc(i.name)}</div>
          <div class="rc-row"><span>${i.qty} × ${money(i.price)}</span><span>${money(i.price * i.qty)}</span></div>`
      )
      .join("");
    return `
      <div class="rc-center rc-shop">${esc(cfg.SHOP_NAME)}</div>
      ${cfg.SHOP_ADDRESS ? `<div class="rc-center">${esc(cfg.SHOP_ADDRESS)}</div>` : ""}
      ${cfg.SHOP_PHONE ? `<div class="rc-center">Ph: ${esc(cfg.SHOP_PHONE)}</div>` : ""}
      <hr>
      <div class="rc-center">Order #${o.id}</div>
      <div class="rc-center">${fmtDate(o.created_at)}</div>
      <hr>
      <div>${esc(o.customer_name || "Customer")} · ${esc(o.phone || "")}</div>
      <hr>
      ${items}
      <hr>
      <div class="rc-row rc-total"><span>TOTAL</span><span>${money(o.total)}</span></div>
      <div class="rc-row"><span>Payment</span><span>${methodLabel(o.payment_method)} · ${esc(String(o.payment_status).toUpperCase())}</span></div>
      <hr>
      <div class="rc-center">${esc(cfg.RECEIPT_FOOTER || "Thank you! Visit again.")}</div>`;
  }

  function printReceipt(o) {
    let box = document.getElementById("receipt-print");
    if (!box) {
      box = document.createElement("div");
      box.id = "receipt-print";
      document.body.appendChild(box);
    }
    box.innerHTML = receiptHtml(o);
    window.print();
  }

  // wa.me link with the bill summary, addressed to the customer's phone.
  function whatsappUrl(o) {
    const lines = [
      `*${cfg.SHOP_NAME}*`,
      `Order #${o.id} · ${fmtDate(o.created_at)}`,
      "",
      ...(o.items || []).map((i) => `${i.qty} × ${i.name} — ${money(i.price * i.qty)}`),
      "",
      `*Total: ${money(o.total)}*`,
      `Payment: ${methodLabel(o.payment_method)} (${o.payment_status})`,
      "",
      cfg.RECEIPT_FOOTER || "Thank you!",
    ];
    const phone = digits(o.phone);
    const to = phone.length === 10 ? (cfg.COUNTRY_CODE || "91") + phone : phone;
    return `https://wa.me/${to}?text=${encodeURIComponent(lines.join("\n"))}`;
  }

  window.App = {
    cfg, db, rpc, session, requireAdmin, logout, money, fmtDate, esc, digits, toast, renderItems,
    methodLabel, renderQR, printReceipt, whatsappUrl, applySettings, upiConfigured,
  };
})();

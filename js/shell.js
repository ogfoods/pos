// App shell for signed-in admins: the profile avatar in the top bar, the
// side drawer behind it, and the fixed bottom bar on phones and tablets.
// common.js calls App.shell.mount after requireAdmin, so every admin page
// gets the same navigation without repeating it in the markup.
(function () {
  const App = window.App;

  const svg = (d, extra = "") =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}${extra}</svg>`;

  const ICON = {
    home: svg(`<path d="M3 10.5 12 3l9 7.5"/><path d="M5 9.5V21h14V9.5"/><path d="M9.5 21v-6h5v6"/>`),
    kitchen: svg(`<path d="M7 21V10"/><path d="M5 3v5a2 2 0 0 0 4 0V3"/><path d="M7 3v5"/><path d="M17 21V3c-1.8 1-3 3.4-3 6.5S15.2 14 17 14"/>`),
    folder: svg(`<path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>`),
    menu: svg(`<path d="M4 5.5A1.5 1.5 0 0 1 5.5 4H19v16H5.5A1.5 1.5 0 0 1 4 18.5z"/><path d="M8 8.5h7M8 12h7M8 15.5h4"/>`),
    stock: svg(`<path d="M20 7 12 3 4 7v10l8 4 8-4z"/><path d="m4 7 8 4 8-4"/><path d="M12 11v10"/>`),
    coupon: svg(`<path d="M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z"/><circle cx="7.5" cy="7.5" r="1.5"/>`),
    chart: svg(`<path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-7"/><path d="M22 20H2"/>`),
    usage: svg(`<path d="M3 3v18h18"/><path d="m7 14 3.5-4 3 3L20 6"/>`),
    staff: svg(`<circle cx="9" cy="8" r="3.2"/><path d="M3 20c0-3.3 2.7-5.5 6-5.5s6 2.2 6 5.5"/><path d="M17 8.5a3 3 0 0 0 0-1M17 14.8c2.4.4 4 2.4 4 5.2"/>`),
    settings: svg(`<circle cx="12" cy="12" r="3"/><path d="M19.4 14.5a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2 2 2 0 1 1-4 0 1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 3.1 14a2 2 0 1 1 0-4 1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.7 1.7 0 0 0 10 3.1a2 2 0 1 1 4 0 1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0 1.2 2.9 2 2 0 1 1 0 4 1.7 1.7 0 0 0-1.5 1.5z"/>`),
    audit: svg(`<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>`),
    account: svg(`<circle cx="12" cy="8" r="3.5"/><path d="M4.5 20c0-3.6 3.4-6 7.5-6s7.5 2.4 7.5 6"/>`),
    more: svg(`<path d="M4 7h16M4 12h16M4 17h16"/>`),
    logout: svg(`<path d="M15 4h3a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-3"/><path d="M10 16l-4-4 4-4"/><path d="M6 12h10"/>`),
    close: svg(`<path d="M6 6l12 12M18 6 6 18"/>`),
  };

  // Everything an admin can reach. `super` items are dropped for plain admins.
  // `bar` marks the ones that earn a slot in the bottom bar.
  // New bill is deliberately absent: its card stays on the home page.
  const NAV = [
    { id: "home", href: "dashboard.html", icon: ICON.home, label: "Home", bar: true },
    { id: "kitchen", href: "kitchen.html", icon: ICON.kitchen, label: "Kitchen", bar: true },
    { id: "bills", href: "managebills.html", icon: ICON.folder, label: "Bills", super: true, bar: true },
    { id: "menu", href: "menu.html", icon: ICON.menu, label: "Menu", super: true },
    { id: "ingredients", href: "ingredients.html", icon: ICON.stock, label: "Ingredients", super: true },
    { id: "usage", href: "usage.html", icon: ICON.usage, label: "Usage", super: true },
    { id: "coupons", href: "coupons.html", icon: ICON.coupon, label: "Coupons", super: true },
    { id: "sales", href: "sales.html", icon: ICON.chart, label: "Sales", super: true },
    { id: "staff", href: "staff.html", icon: ICON.staff, label: "Staff", super: true },
    { id: "settings", href: "settings.html", icon: ICON.settings, label: "Shop settings", super: true },
    { id: "audit", href: "audit.html", icon: ICON.audit, label: "Audit log", super: true },
    { id: "account", href: "account.html", icon: ICON.account, label: "My account", bar: true },
  ];

  const here = location.pathname.split("/").pop() || "dashboard.html";
  let me = null, drawer = null, backdrop = null, avatar = null, lastFocus = null;

  function mount(admin) {
    // The waiting page has nothing to navigate to yet.
    if (!admin || admin.approved === false || document.getElementById("app-avatar")) return;
    me = admin;
    const items = NAV.filter((n) => !n.super || me.role === "super");
    mountAvatar();
    mountDrawer(items);
    mountBottomBar(items);
  }

  const isCurrent = (n) => n.href === here || (here === "" && n.href === "dashboard.html");

  function go(n) {
    if (n && !isCurrent(n)) location.href = n.href;
  }

  // ---------------------------------------------------------------- avatar
  function mountAvatar() {
    const bar = document.querySelector(".topbar-right");
    if (!bar) return;
    // The name chip, Account link and Logout button all live in the drawer now.
    bar.querySelectorAll("#who").forEach((el) => el.remove());
    bar.querySelectorAll('a[href="account.html"]').forEach((el) => el.remove());
    bar.querySelectorAll("button").forEach((b) => {
      if (/logout/i.test(b.textContent) || /logout/i.test(b.getAttribute("onclick") || "")) b.remove();
    });

    avatar = document.createElement("button");
    avatar.id = "app-avatar";
    avatar.type = "button";
    avatar.className = "avatar-btn";
    avatar.textContent = String(me.username || "?").trim().charAt(0).toUpperCase();
    avatar.title = `${me.username} · ${me.role === "super" ? "super admin" : "admin"}`;
    avatar.setAttribute("aria-label", "Account menu");
    avatar.setAttribute("aria-expanded", "false");
    avatar.addEventListener("click", () => (drawer.classList.contains("open") ? close() : open()));
    bar.appendChild(avatar);
  }

  // ---------------------------------------------------------------- drawer
  function mountDrawer(items) {
    backdrop = document.createElement("div");
    backdrop.className = "drawer-backdrop";
    backdrop.hidden = true;
    backdrop.addEventListener("click", close);

    drawer = document.createElement("aside");
    drawer.className = "drawer";
    drawer.id = "app-drawer";
    drawer.setAttribute("role", "dialog");
    drawer.setAttribute("aria-modal", "true");
    drawer.setAttribute("aria-label", "Menu");
    drawer.hidden = true;
    drawer.innerHTML = `
      <div class="drawer-head">
        <div class="avatar-btn avatar-lg" aria-hidden="true">${App.esc(String(me.username || "?").charAt(0).toUpperCase())}</div>
        <div class="grow">
          <strong>${App.esc(me.username)}</strong>
          <div><span class="badge ${me.role === "super" ? "badge-super" : ""}">${me.role === "super" ? "super admin" : "admin"}</span></div>
        </div>
        <button class="icon-btn drawer-close" type="button" aria-label="Close menu">${ICON.close}</button>
      </div>
      <nav class="drawer-nav">
        ${items
          .map(
            (n) => `<button class="drawer-item${isCurrent(n) ? " current" : ""}" type="button" data-nav="${n.id}">
              <span class="drawer-icon">${n.icon}</span><span>${App.esc(n.label)}</span></button>`
          )
          .join("")}
      </nav>
      <button class="drawer-item drawer-logout" type="button" id="drawer-logout">
        <span class="drawer-icon">${ICON.logout}</span><span>Logout</span>
      </button>`;

    drawer.querySelector(".drawer-close").addEventListener("click", close);
    drawer.querySelector("#drawer-logout").addEventListener("click", () => App.logout());
    drawer.querySelector(".drawer-nav").addEventListener("click", (e) => {
      const b = e.target.closest("[data-nav]");
      if (!b) return;
      close();
      go(items.find((n) => n.id === b.dataset.nav));
    });

    document.body.append(backdrop, drawer);
    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && drawer.classList.contains("open")) close();
    });
  }

  function open() {
    lastFocus = document.activeElement;
    backdrop.hidden = drawer.hidden = false;
    // A frame between unhiding and the class so the slide-in animates.
    requestAnimationFrame(() => {
      backdrop.classList.add("open");
      drawer.classList.add("open");
    });
    avatar.setAttribute("aria-expanded", "true");
    drawer.querySelector(".drawer-close").focus();
  }

  function close() {
    backdrop.classList.remove("open");
    drawer.classList.remove("open");
    avatar.setAttribute("aria-expanded", "false");
    setTimeout(() => {
      if (!drawer.classList.contains("open")) backdrop.hidden = drawer.hidden = true;
    }, 220);
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  // ------------------------------------------------------------ bottom bar
  // Phones and tablets get the bento cards as a fixed bar instead. Four
  // destinations plus More, which opens the drawer for everything else.
  function mountBottomBar(items) {
    const picks = items.filter((n) => n.bar).slice(0, 4);
    const rest = items.filter((n) => !picks.includes(n));

    const nav = document.createElement("nav");
    nav.className = "bottom-nav";
    nav.setAttribute("aria-label", "Main");
    nav.innerHTML =
      picks
        .map(
          (n) => `<button class="bottom-item${isCurrent(n) ? " current" : ""}" type="button" data-nav="${n.id}">
            <span class="bottom-icon">${n.icon}</span><span class="bottom-label">${App.esc(n.label)}</span></button>`
        )
        .join("") +
      (rest.length
        ? `<button class="bottom-item" type="button" data-more="1">
             <span class="bottom-icon">${ICON.more}</span><span class="bottom-label">More</span></button>`
        : "");

    nav.addEventListener("click", (e) => {
      const b = e.target.closest("button");
      if (!b) return;
      if (b.dataset.more) return open();
      go(items.find((n) => n.id === b.dataset.nav));
    });

    document.body.appendChild(nav);
    document.body.classList.add("has-bottom-nav");
  }

  App.shell = { mount, openDrawer: () => open(), closeDrawer: () => close() };
})();

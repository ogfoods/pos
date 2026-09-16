# User Guide

This guide lists every feature of POS Billing and explains how to use it.

Live site: https://ogfoods.github.io/pos/

## Who can do what

| Feature | Customer (no login) | Admin | Super admin |
|---|:---:|:---:|:---:|
| Home page: live kitchen board, menu, WhatsApp order | ✅ | ✅ | ✅ |
| Search order history by phone | ✅ | ✅ | ✅ |
| Log in / log out | — | ✅ | ✅ |
| Create a new bill | — | ✅ | ✅ |
| Manage bills (view, change status, delete) | — | ❌ | ✅ |
| Modify menu items | — | ❌ | ✅ |
| Manage ingredients, recipes and stock | — | ❌ | ✅ |
| See low stock warnings | — | ✅ | ✅ |
| View ingredient usage report | — | ❌ | ✅ |
| Manage staff, shop settings, audit log | — | ❌ | ✅ |
| Change own password | — | ✅ | ✅ |
| Open / close own cash shift | — | ✅ | ✅ |
| Kitchen screen | — | ✅ | ✅ |
| Sales report and all shifts | — | ❌ | ✅ |

---

## 1. Home page (public)

**Page:** `index.html` — what every visitor sees. Set it up in **Shop settings → Home page** (see [6.2](#62-shop-settings)).

| Section | What visitors see |
|---|---|
| **Hero** | Shop name, tagline, cover photo, **Open now · closes 10 pm** / **Closed · opens 7 am** (from opening hours, IST), and buttons: **Order on WhatsApp**, **Call**, **Directions**, **See menu**. Buttons without a configured number or link are hidden. |
| **Live numbers** | Orders cooking now, ready for pickup, and orders today. |
| **Live from our kitchen** | The kitchen board, updating live: **Order received → Preparing → Ready** with order number, items and how long ago. A line at the top announces the latest change ("#214 · Masala Dosa is on the stove 🔥"). Customers can spot their own order number. No names, phone numbers or amounts are shown. |
| **Today's favourites** | Up to 6 best sellers of the last 7 days, with photo and price. |
| **Menu** | All available items with photo, price and category chips; **Few left** / **Sold out** tags from stock tracking. |
| **WhatsApp basket** | Visitors tap **+ Add** on items; a bar at the bottom shows the count and **Order on WhatsApp** opens WhatsApp with the items pre-filled (e.g. "Hi OG Foods, I'd like to order: 2× Masala Dosa, 1× Filter Coffee"). You confirm and bill it as usual. |
| **Visit us** | Address, phone, opening hours with today highlighted, **Get directions**. |
| **Your orders** | Search order history by phone number (at least 6 digits); shows orders, status and total spent (cancelled not counted). |

---

## 2. Admin login

**Page:** click **Login** at the top-right of the home page (`adminlogin.html`)

1. Enter your **username** and **password**.
2. Click the **eye icon** in the password field to show or hide what you typed.
3. Click **Login**.

- Wrong details show **"Invalid username or password."**
- After **5 wrong passwords in 15 minutes** the account is locked for up to 15 minutes, and the message says how long to wait. A successful login resets the count. Too many failures from one network (20 in 15 minutes) also blocks logins from it for a while.
- A login lasts **12 hours**. After that you are sent back to the login page automatically.
- If you are already logged in, opening the login page takes you straight to the dashboard.
- Click **Logout** (top-right on any admin page) when you finish, especially on a shared device.

Accounts are created by a super admin on the **Staff** page. See [Staff](#61-staff).

---

## 3. Dashboard

**Page:** `dashboard.html` (opens after login)

The header shows your username and role. The page has these cards:

| Card | What it does | Available to |
|---|---|---|
| **New bill** | Opens the billing window | All admins |
| **Kitchen screen** | Live order queue for the kitchen | All admins |
| **Manage bills** | Opens the bill management page | Super admin only |
| **Modify menu items** | Opens the menu editor | Super admin only |
| **Sales** | Revenue, busy hours, top items, payment methods, shift closes | Super admin only |
| **Ingredient usage** | Opens the ingredient consumption report | Super admin only |
| **Staff** | Add users, reset passwords, sign people out | Super admin only |
| **Shop settings** | Shop name, address, UPI ID, receipt text | Super admin only |
| **Audit log** | History of changes to bills, menu, staff and settings | Super admin only |

**Account** (top right) lets any admin change their own password. The **shift bar** above the cards opens and closes your cash shift (see [Shifts](#shifts-cash-drawer-count)).

For a normal admin, the super admin cards are greyed out with a 🔒 label, and clicking them shows a message.

---

## 4. Create a new bill

**Where:** Dashboard → **New bill**

The window has three steps. The bar at the top shows which step you are on. Use **Back** to return to an earlier step without losing your entries.

### Step 1 — Customer details
1. Enter the customer's **phone number** (required, exactly 10 digits — letters and symbols are ignored).
2. Enter the **customer name** (optional). If left blank for a returning customer, their saved name is used.
3. Click **Next**.

### Step 2 — Select items
1. Tap a category chip (**All**, Snacks, Beverages, …) to narrow the list, or type in **Filter items…** to search by name or category.
2. Each item shows its photo (or first letter), name, category and price. Use **+** and **−** to set the quantity. Selected items are highlighted.
3. The bar at the bottom shows a cart badge with the item count and the running total.
4. Click **Next** (at least one item is required).

Stock warnings: a red **⚠** means out of stock and an amber **⚠** means low stock. Tap it for details. Depending on Shop settings, out-of-stock items are either hidden or shown with the warning. See [Stock](#56-stock).

If the list is empty, a super admin needs to add menu items first.

### Step 3 — Payment
1. Check the customer, item list and **total amount**.
2. Pick the payment method: **Cash**, **UPI** or **Card**.
   - **Cash / Card** — collect the money, then click **Save bill**. The bill is saved as **paid**.
   - **UPI** — the customer scans the **QR code** with any UPI app (GPay, PhonePe, Paytm, etc.; amount pre-filled). Click **Save bill**. The bill is saved as **pending**.
3. The saved screen shows the order number and status:
   - For UPI, keep the QR on screen. When the payment shows in your UPI app, click **✓ Payment received** to mark it **paid**.
   - **🖨️ Print receipt** prints a 58 mm receipt.
   - **WhatsApp** opens WhatsApp with the bill summary addressed to the customer's number.
4. Click **New bill** for the next customer, or close the window.

The order is saved under the customer's phone number and appears in their history immediately.

### Awaiting payment
UPI bills not yet confirmed appear under **Awaiting payment** on the dashboard (refreshes every minute). Click **✓ Received** once the money arrives, or **Receipt** to print. Any admin can confirm payments.

### Kitchen screen

**Where:** Dashboard → **Kitchen screen** (`kitchen.html`). Any admin can open it; use a tablet or TV in the kitchen and click **⛶ Full screen**.

- Every new bill appears in **🆕 New** within a second or two (top bar shows **Live**; if live updates are unavailable it shows **Auto-refresh 10s** and still refreshes).
- Each card shows the order number, customer, items with quantities, and how long ago it was billed. UPI bills not yet confirmed carry a **UPI pending** badge.
- Tap **Start preparing** → **Mark ready** → **Served ✓** to move a card along. **↩** moves it back one step.
- Cards turn **amber after 15 minutes** and **red after 25 minutes**, with "late" next to the timer.
- Tap **🔕 Sound off** once to switch on a chime for new orders (browsers only allow sound after a tap). The choice is remembered on that device.
- **Recently served** (bottom) lists orders served in the last 2 hours with **Undo**.
- Cancelled bills disappear from the screen. Orders older than 24 hours are not shown.
- Kitchen status changes are recorded in the audit log.

### Shifts (cash drawer count)

The **shift bar** at the top of the dashboard shows whether you have a shift open.

1. **Start of day:** click **Open shift**, count the cash in the drawer and enter it as **Opening cash**.
2. Bill as usual. The bar shows your **expected cash** so far = opening cash + cash from *your* paid bills.
3. **End of day:** click **Close shift**. You see opening cash, cash sales, expected cash, UPI, card and total sales. Count the drawer and enter **Cash counted in drawer**; the difference shows live as **Short by**, **Over by** or **Exact match**. Add a note if needed (e.g. cash paid to a vendor) and click **Close shift**.
4. Click **🖨️ Print shift report** for a 58 mm summary.

Notes:
- Each user has their own shift; only bills *you* created count toward it.
- Cancelled bills are not counted as cash. Pending UPI bills are listed as a warning; confirm them before closing if the money has arrived.
- Opening and closing a shift are recorded in the audit log. Super admins see all shifts on the **Sales** page and can close a shift someone forgot.

### Printing receipts
The receipt is laid out for 58 mm thermal paper. In the print dialog choose your receipt printer, set margins to **None**, and turn off headers/footers. On Android with a Bluetooth printer, use a print service app (e.g. RawBT) so it appears in the print dialog.

> Set your real UPI ID on the **Shop settings** page before accepting payments. Until then the QR shows a red "Sample UPI ID" warning.

**Tips**
- Close the window with **×**, the **Esc** key, or by tapping outside it. If items are selected, you will be asked to confirm discarding the bill.
- Prices on the bill always come from the current menu; they cannot be changed during billing.

---

## 5. Super admin features

### 5.1 Manage bills

**Where:** Dashboard → **Manage bills** (`managebills.html`)

The table lists all orders, newest first, 25 per page, with order number, date, customer name and phone, number of items, total, payment method, status, and who created the bill.

| Task | How |
|---|---|
| **Search** | Type a phone number (or part of one), a customer name, or an exact order number. Results update as you type. |
| **Change pages** | Use **← Prev** / **Next →** below the table. |
| **View details** | Click **View** to see the full item list, total, payment method and status. **🖨️ Print receipt** or **WhatsApp** the bill from there. |
| **Change status** | Pick **paid**, **pending** or **cancelled** from the status dropdown. It saves immediately. |
| **Delete a bill** | Click **Delete** and confirm. This permanently removes the order and cannot be undone. |

Tip: prefer marking a wrong bill as **cancelled** instead of deleting it, so there is a record. Cancelled orders are excluded from the customer's "total spent".

On phones, swipe the table sideways to see all columns.

### 5.2 Modify menu items

**Where:** Dashboard → **Modify menu items** (`menu.html`)

**Add an item**
1. Fill in **Name**, **Category** (pick an existing one from suggestions or type a new one; blank becomes "General") and **Price**.
2. Optionally paste an **Image URL** (must start with `https://`). The photo appears in New bill; without one, the item's first letter is shown.
3. Keep **Available** ticked so it appears when billing.
4. Click **Add**.

**Edit an item**
1. Click **Edit** on the item's row. The form at the top fills in.
2. Change the details and click **Save**, or **Cancel** to stop editing.

**Hide an item** (for example, out of stock)
- Edit it, untick **Available**, and save. It shows as "hidden" and no longer appears in New bill. Tick it again to bring it back.

**Delete an item**
- Click **Delete** and confirm. Past bills keep the item's name and price, so history is not affected.

**Filter** — type in **Filter items…** above the table to search by name or category.

Price changes only affect new bills; existing bills keep the price they were created with.

### 5.3 Ingredients and recipes

Link the ingredients each menu item needs, so the app records how much of every ingredient each order uses.

**Add ingredients** — Modify menu items → **Manage ingredients** (`ingredients.html`)
1. Enter a **Name** (e.g. Rice) and pick a **Unit**: g, kg, ml, l or pcs.
2. Click **Add**. The table shows how many menu items use each ingredient.
3. Use **Edit** / **Delete** as needed. Deleting removes it from recipes; past orders keep their ingredient history. Changing a unit does not convert existing recipe quantities.

**Link ingredients to a menu item** — Modify menu items → **Ingredients** column
1. Click **+ Link** (or **N linked**) on the item's row.
2. For each row pick an ingredient and enter the quantity needed to make **one** of that item (e.g. Dosa: Rice batter 150 g, Oil 10 ml).
3. **+ Add ingredient** adds a row; **×** removes one. Click **Save**.

**What happens when billing:** each new order stores ingredient usage = recipe quantity × quantity ordered (2 Dosa → 300 g batter, 20 ml oil). This is saved with the order, so editing a recipe later does not change past records. Orders created before a recipe was linked have no ingredient data.

### 5.4 Ingredient usage report

**Where:** Dashboard → **Ingredient usage** (`usage.html`)

1. Pick a quick range (**Today**, **Yesterday**, **Last 7 days**, **Last 30 days**, **This month**) or set **From** / **To** dates and click **Show**.
2. The table lists each ingredient with the total used and its unit. Large gram/millilitre totals also show kg / l.
3. Tick **Split by day** to see one block per day.
4. Click **Export CSV** to download the table for Excel / Google Sheets.

Notes:
- Days follow **IST** (midnight to midnight, India time).
- Cancelled orders are excluded. Changing an order to cancelled removes it from the report.
- The summary shows the number of orders and how many had no ingredient data (items without linked ingredients at billing time). Ranges are limited to one year.

### 5.5 Sales report

**Where:** Dashboard → **Sales** (`sales.html`)

1. Pick a quick range (**Today**, **Yesterday**, **Last 7 days**, **Last 30 days**, **This month**) or set **From** / **To** and click **Show**.
2. The top tiles show **Sales**, **Average bill**, **Pending** and **Cancelled** totals. Sales and average count paid bills only.
3. **Sales by day** and **Busy hours** are bar charts. Hover (or tap) a bar for the exact figures, or open **Show as table**.
4. **Payment methods**, **Top items** (top 10 by revenue) and **By staff** show each share with a bar.
5. **Shift closes** lists every shift opened in the range with opening, expected and counted cash and the difference. **Print** reprints a shift report; **Close** closes a shift that is still open (you enter the counted cash).

Days and hours follow IST. Bills are dated by when they were created. Ranges are limited to one year.

### 5.6 Stock

**Where:** Dashboard → **Modify menu items** → **Manage ingredients** (`ingredients.html`), **Stock** button on each row.

Stock is tracked per ingredient. An ingredient is **Not tracked** until you record stock for it, so nothing is blocked before you start.

| Task | How |
|---|---|
| **Add a purchase** | **Stock** → **➕ Purchase** → quantity bought → **Save**. Adds to stock. |
| **Record waste** | **Stock** → **🗑 Waste** → quantity → **Save**. Subtracts from stock. |
| **Stock count** | **Stock** → **🔢 Count** → the actual quantity you counted → **Save**. Sets stock to that number. |
| **Low stock alert** | **Stock** → **Low stock alert at** → e.g. `500` → **Save tracking**. |
| **Stop tracking** | **Stock** → untick **Track stock** → **Save tracking**. |

The screen shows "Stock after saving" before you save, and **History** lists every change: purchases, waste, counts, and each bill (**Bill #12**) or undone bill (**Bill undone #12**).

**What happens automatically**
- Each bill subtracts its ingredients (recipe quantity × quantity sold) from tracked stock.
- **Cancelling** a bill puts the ingredients back; changing it back from cancelled takes them again. **Deleting** a bill that was not cancelled also puts them back.
- The dashboard shows a **⚠ Low stock** list (all admins) for tracked ingredients at or below their alert level, or at zero.

**Out of stock on New bill** depends on **Shop settings → Hide menu items when an ingredient runs out**:

| Setting | New bill screen |
|---|---|
| **Ticked** (default) | Items that cannot be made are hidden ("N items hidden: out of stock"). **+** stops at the number stock allows. If stock ran out meanwhile, saving shows e.g. "Not enough Rice: 50 g left, this bill needs 150 g." |
| **Unticked** | Items stay visible with a red **⚠**. Tap it to see which ingredient is short, how much is left and how much each item needs. The bill still saves, stock goes below zero, and a "Stock below zero: …" message appears. |

In both modes, items running low show an amber **⚠** with the same details. The menu page also marks items **out of stock** / **low stock**.

---

## 6. Staff, settings and audit log (super admin)

### 6.1 Staff

**Where:** Dashboard → **Staff** (`staff.html`)

The table shows every user with role, status (active / disabled), last login and how many devices they are signed in on.

| Task | How |
|---|---|
| **Add a user** | Enter a **username** (3–32 characters: letters, numbers, `.` `-` `_`; stored in lowercase), pick **Admin** (billing only) or **Super admin** (everything), set a **password** (min 8 characters) and click **Add user**. |
| **Reset a password** | **Edit** → type a **New password** → **Save**. The user is signed out on all devices. Leave it blank to keep the current password. |
| **Change a role** | **Edit** → pick the role → **Save**. The user is signed out and gets the new access at next login. |
| **Disable a user** | **Edit** → untick **Active** → **Save**. They are signed out and cannot log in. Their past bills stay linked to them. |
| **Sign out everywhere** | **Sign out** on the row (e.g. a lost phone). Your own current session is kept. |

You cannot remove your own super admin role or disable yourself, so there is always at least one super admin.

### 6.2 Shop settings

**Where:** Dashboard → **Shop settings** (`settings.html`)

| Setting | Used for |
|---|---|
| **Shop name** | Header on every page, receipts, WhatsApp messages, UPI payee name |
| **Address**, **Shop phone** | Printed at the top of receipts |
| **UPI ID** | Where QR payments go (e.g. `myshop@okaxis`). Until it is set, the QR shows a red "Sample UPI ID" warning. |
| **Currency symbol** | Shown before every amount |
| **Country code** | Added before 10-digit customer numbers in WhatsApp links (`91` for India) |
| **Receipt footer** | Last line of receipts and WhatsApp messages |
| **Tagline** | One line under the shop name on the home page |
| **WhatsApp number** | Enables **Order on WhatsApp** and the menu basket on the home page. Enter the number with or without country code; 10-digit numbers get the country code added. |
| **Google Maps link** | **Directions** buttons on the home page (paste the share link from Google Maps) |
| **Cover photo URL** | Background of the home page hero (a wide https:// image) |
| **Opening hours** | Per day open/close time or **Closed** (IST). Drives **Open now / Closed** and the hours table. A closing time earlier than the opening time means after midnight. **Copy Monday to all days** fills the rest. Leave everything empty to hide hours. |
| **Hide menu items when an ingredient runs out** | Ticked: out-of-stock items are hidden and blocked on New bill. Unticked: they show a ⚠ warning and can still be billed. See [Stock](#56-stock). |

Click **Save settings**. Other open devices pick up the change when their page is refreshed. **🖨️ Test receipt** prints a sample using the saved settings.

### 6.3 Audit log

**Where:** Dashboard → **Audit log** (`audit.html`)

A record of who did what and when, newest first:

| Area | Recorded |
|---|---|
| Orders | Status changes (from → to), payment confirmations, deleted bills (with a full copy of the bill) |
| Menu | Items added, edited (old → new values), deleted, recipe changes (before / after) |
| Ingredients | Added, edited, deleted |
| Stock | Purchases, waste, counts (before → after), tracking and alert changes |
| Staff | Users added or edited, password resets, sign-outs, own password changes, login hours and auto-allow changes, sign-ins approved or denied, and sign-ins refused for being outside the login hours |
| Kitchen | Order moved between new / preparing / ready / served |
| Shifts | Opened (opening cash), closed (expected, counted, difference) |
| Settings | Every changed field (old → new) |

Filter with the area chips, or search by username, order number or item name. The log cannot be edited or deleted from the app.

### 6.4 Login hours and approving sign-ins

**Where:** Dashboard → **Staff** (`staff.html`), and the banner on the dashboard

Two controls decide when each admin can work. Both are per account, and neither
applies to super admins.

**Login hours.** In the user form, set **Login hours** to the shift, for example
`09:00` to `22:00` (IST). Then:

- Outside those hours the password is refused, with the hours in the message.
- An admin already signed in is dropped the moment the hours end, and the login
  page tells them why.
- Leave both boxes blank for no restriction.
- A shift crossing midnight is fine: `17:00` to `02:00`.

**Auto allow.** Each row in the staff table has an **Auto allow** checkbox.

| Auto allow | What happens when that person signs in |
|---|---|
| Ticked | Straight to the dashboard, as before |
| Unticked | They land on a waiting page until you let them in |

**Letting someone in.** When an admin who needs approval signs in, you get the
usual sign-in alert, now with **Approve** and **Deny** on it, and a
**Waiting to be let in** strip appears at the top of your dashboard listing
everyone waiting. Either place works, on any device where you are signed in.

- **Approve** — they tap **Refresh** on their screen and the dashboard opens.
- **Deny** — that device is signed out. They can try again.

Approval covers that one device, and lasts until the end of that day's login
hours. Next shift, or a second device, means approving again. With no login
hours set, it lasts until the 12-hour session runs out.

**Sign out devices** (the red button in each row) still works as before, and
clears both approved and waiting sessions.

> Accounts that existed before this feature was switched on are all set to
> **Auto allow**, so nothing changed for them. Untick it per person to start
> approving their sign-ins.

### 6.5 Sign-in alerts

**Where:** the 🔔 button at the top of any super admin page

Tells you the moment anyone signs in to the app.

1. Click **🔔 Sign-in alerts** once. The browser asks whether this site may show
   notifications — choose **Allow**.
2. From then on, each sign-in gives you a banner in the page, a short chime, and a
   desktop notification with the username, role, time and IP address.
3. Clicking the notification opens the app on the audit log.
4. Click the bell again to turn alerts off. The choice is remembered on that device.

Notes:

- Your own sign-ins are not announced to you.
- Alerts arrive only while the app is open in a tab or window (it can be minimised or
  in the background, but not closed). Notifications with the app fully closed are not
  built yet.
- If the button says **🔕 Alerts blocked**, notifications were refused for this site
  earlier. Allow them again in the browser's site settings (the padlock in the
  address bar).
- Every sign-in is also listed on the audit log, so nothing is lost if you miss an
  alert.

### 6.6 My account (all admins)

**Where:** **Account** at the top of the dashboard (`account.html`)

Change your own password: enter the current one, then the new one twice (min 8 characters). You stay signed in on this device; your other devices are signed out.

### 6.7 First super admin (owner / developer)

The very first super admin is created in Supabase → **SQL Editor**; after that, use the Staff page.

```sql
insert into public.admins (username, password_hash, role)
values ('owner', crypt('StrongPassword', gen_salt('bf')), 'super');
```

If every super admin is locked out, reset a password the same way:

```sql
update public.admins set password_hash = crypt('NewStrongPassword', gen_salt('bf')), is_active = true
where username = 'owner';
```

---

## 7. Technical settings (`js/config.js`)

`config.js` holds the Supabase connection (`SUPABASE_URL`, `SUPABASE_ANON_KEY`). Its `SHOP_NAME`, `CURRENCY`, `UPI_ID` and `COUNTRY_CODE` are only fallbacks used before the database settings load; change those on the **Shop settings** page instead.

---

## 8. Using on phones and tablets

- All pages adapt to screen size; the dashboard cards stack on narrow screens.
- On phones the New bill window opens full-screen with an app-style layout: numbered steps, category chips, item photos, and a cart bar at the bottom. On larger screens it opens as a compact centred window.
- Dark mode follows the device setting.

**Install it as an app.** The site can be installed like a normal app, so it opens
full screen with its own icon and no browser bars:

| Device | How |
|---|---|
| Android (Chrome) | Tap **⬇ Install app** at the top, or the browser menu → **Install app** |
| iPhone / iPad (Safari) | **Share** → **Add to Home Screen** |
| Windows / Mac (Chrome, Edge) | Click **⬇ Install app** at the top, or the install icon in the address bar |

Once installed, pages you have already opened still load without a connection, and
you get an **No connection** screen instead of a browser error. Live data — bills,
the kitchen board, the menu — always needs the internet.

---

## 9. Troubleshooting

| Problem | Fix |
|---|---|
| "Invalid username or password." | Check spelling; confirm the account exists, is active, and the password was set with `crypt()`. |
| Sent back to login unexpectedly | The 12-hour session expired or the account was disabled. Log in again. |
| "Super admin access required." | Your account is a normal admin. Ask the owner to change your role. |
| New bill shows no items | No available menu items. A super admin must add items or tick **Available**. |
| QR code not showing | Check the internet connection (the QR library loads from a CDN) and refresh. |
| Changes not visible after pushing | Wait 1–2 minutes for GitHub Pages, then hard-refresh. |
| Page shows errors about the database | Check `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `js/config.js` and that `schema.sql` (or all migrations) was run. |
| "Too many failed attempts" | Wait the number of minutes shown, or ask a super admin to reset your password on the Staff page. |
| Shop name / UPI ID not updated on a device | Refresh the page; settings load when a page opens. |
| "You can only sign in between …" | That account has login hours set. A super admin can change them on the Staff page. |
| "Your login hours … have ended." | The shift window closed. Nothing is lost; sign in again next shift. |
| Admin stuck on the waiting page | A super admin has to approve them: dashboard banner or the sign-in alert. Tick **Auto allow** on the Staff page to stop asking. |
| Waiting admin never appears for approval | Their login hours may have ended, which hides them from the list. Check the hours on the Staff page. |
| No sign-in alerts | Check the bell says **🔔 Sign-in alerts**, that the app is open somewhere, and that the browser is allowed to show notifications for the site. Your own sign-ins are never announced. |
| Alerts have no sound | Browsers only allow sound after a click. Click the bell once on that device. |
| App still shows an old version after an update | Close every window of the installed app and reopen it, or hard-refresh in the browser. |

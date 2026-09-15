# User Guide

This guide lists every feature of POS Billing and explains how to use it.

Live site: https://ogfoods.github.io/pos/

## Who can do what

| Feature | Customer (no login) | Admin | Super admin |
|---|:---:|:---:|:---:|
| Search order history by phone | ✅ | ✅ | ✅ |
| Log in / log out | — | ✅ | ✅ |
| Create a new bill | — | ✅ | ✅ |
| Manage bills (view, change status, delete) | — | ❌ | ✅ |
| Modify menu items | — | ❌ | ✅ |
| Manage ingredients and link them to items | — | ❌ | ✅ |
| View ingredient usage report | — | ❌ | ✅ |
| Manage staff, shop settings, audit log | — | ❌ | ✅ |
| Change own password | — | ✅ | ✅ |

---

## 1. Customer: view order history

**Page:** home page (`index.html`)

1. Open the site.
2. Type your phone number in the search bar. Spaces and dashes are fine; only digits are used. At least 6 digits are needed.
3. Press **Search** (or Enter).

You will see:
- Number of orders and the **total spent** (cancelled orders are not counted).
- One card per order, newest first, showing order number, date and time, status (paid / pending / cancelled), each item with quantity and price, and the order total.

If nothing appears, check that the number matches the one given at billing.

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
| **Manage bills** | Opens the bill management page | Super admin only |
| **Modify menu items** | Opens the menu editor | Super admin only |
| **Ingredient usage** | Opens the ingredient consumption report | Super admin only |
| **Staff** | Add users, reset passwords, sign people out | Super admin only |
| **Shop settings** | Shop name, address, UPI ID, receipt text | Super admin only |
| **Audit log** | History of changes to bills, menu, staff and settings | Super admin only |

**Account** (top right) lets any admin change their own password.

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

Click **Save settings**. Other open devices pick up the change when their page is refreshed. **🖨️ Test receipt** prints a sample using the saved settings.

### 6.3 Audit log

**Where:** Dashboard → **Audit log** (`audit.html`)

A record of who did what and when, newest first:

| Area | Recorded |
|---|---|
| Orders | Status changes (from → to), payment confirmations, deleted bills (with a full copy of the bill) |
| Menu | Items added, edited (old → new values), deleted, recipe changes (before / after) |
| Ingredients | Added, edited, deleted |
| Staff | Users added or edited, password resets, sign-outs, own password changes |
| Settings | Every changed field (old → new) |

Filter with the area chips, or search by username, order number or item name. The log cannot be edited or deleted from the app.

### 6.4 My account (all admins)

**Where:** **Account** at the top of the dashboard (`account.html`)

Change your own password: enter the current one, then the new one twice (min 8 characters). You stay signed in on this device; your other devices are signed out.

### 6.5 First super admin (owner / developer)

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
- Tip: add the site to your home screen from the browser menu for quick access at the counter.

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

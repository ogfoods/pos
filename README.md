# POS Billing

Static, responsive POS billing web app. Hosted on GitHub Pages, data in Supabase.

Docs: [Architecture](docs/ARCHITECTURE.md) · [User guide](docs/USER_GUIDE.md)

## Pages

| Page | Who | What |
|---|---|---|
| `index.html` | Public | Home page: open status, live kitchen board, favourites, menu with WhatsApp basket, visit info, order lookup by phone |
| `adminlogin.html` | Admins | Username / password login |
| `dashboard.html` | All admins | Cash shift open/close, bento dashboard, awaiting-payment list, **New bill** modal (items → customer → Cash/UPI/Card → receipt) |
| `managebills.html` | Super admin | Search, view, change status, delete orders, print/WhatsApp receipts |
| `menu.html` | Super admin | Add / edit / hide / delete menu items, link ingredients to each item |
| `ingredients.html` | Super admin | Ingredients, stock (purchase / waste / count), low-stock alerts, history |
| `usage.html` | Super admin | Ingredients consumed per day (IST), CSV export |
| `staff.html` | Super admin | Add users, change roles, reset passwords, set login hours, auto-allow, sign out devices |
| `settings.html` | Super admin | Shop name, address, phone, UPI ID, currency, receipt footer |
| `audit.html` | Super admin | Who changed bills, menu, recipes, ingredients, staff, settings |
| `account.html` | All admins | Change own password |
| `pending.html` | Admins | Waiting room until a super admin allows the sign-in |
| `offline.html` | Everyone | Shown when a page is opened with no connection |
| `kitchen.html` | All admins | Kitchen display: live queue new → preparing → ready → served, late colours, chime |
| `sales.html` | Super admin | Sales by day/hour, payment methods, top items, staff, shift closes |

## Setup

### 1. Supabase
1. Create project at https://supabase.com.
2. SQL Editor → paste and run `supabase/schema.sql`.
3. Create the first super admin (SQL Editor):
   ```sql
   insert into public.admins(username, password_hash, role)
   values ('owner', crypt('ChangeMe#1', gen_salt('bf')), 'super');
   ```
   Add everyone else from the **Staff** page after logging in. Passwords are bcrypt hashes; in SQL always use `crypt(...)`.
4. Project Settings → API → copy **Project URL** and **anon public key** into `js/config.js`.
5. Log in → **Shop settings** → set shop name, UPI ID, address, receipt footer, and the **Home page** details (tagline, WhatsApp, Maps link, cover photo, opening hours).

Existing database? Run the new files in `supabase/migrations/` in order instead of `schema.sql`.

### 2. GitHub Pages
```bash
git init
git add .
git commit -m "Initial POS billing app"
git branch -M main
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```
Repo → Settings → Pages → Source: `main` branch, `/ (root)`. Site appears at `https://<you>.github.io/<repo>/`.

### Local preview
Any static server, e.g. `npx serve .` or `python -m http.server 8000`.

## Install as an app

The site is a PWA: `manifest.webmanifest`, `sw.js` and `icons/`. On Chrome, Edge and
Android an **Install app** button appears in the top bar; on iOS use Safari's
**Share → Add to Home Screen**. Installed, it opens full screen with its own icon,
and pages already visited still open without a connection. Live data (bills, the
kitchen board, the menu) always needs the internet.

## Controlling when admins can work

On the **Staff** page each admin account has:

- **Login hours** — a daily from/to in IST. Outside it the password is refused,
  and an admin already signed in is dropped the moment the window closes. Blank
  means any time. `17:00`–`02:00` wraps past midnight.
- **Auto allow** — a checkbox next to the account. Ticked, sign-ins go straight
  through. Unticked, each sign-in lands on a waiting page until a super admin
  approves it from the dashboard banner or the sign-in alert. Approval covers
  that one device and lasts to the end of that day's login hours.
- **Sign out** — removes every session for that user, on all devices.

Super admins are never gated. Accounts that already existed when migration 013
was run keep working: they are all set to auto allow until you untick them.

Requires migration `013_login_hours_approval.sql`.

## Sign-in alerts

Super admins are notified when anyone signs in. The 🔔 button in the top bar turns
alerts on and asks for notification permission; after that every sign-in shows a
toast, a chime and a desktop notification on any device where a super admin has the
app open. Own sign-ins are skipped.

Requires migration `012_login_alerts.sql`. Notifications only arrive while the app is
open in a tab or window — push with the app fully closed needs Web Push and is not
built yet.

## Security notes
- All tables have RLS on with no policies; browser talks only to `SECURITY DEFINER` RPC functions.
- Login returns a 12-hour session token; admin/super checks happen in the database, not just the UI.
- Login is rate-limited (5 failures per username / 20 per IP in 15 minutes).
- Login hours and the approval step are enforced in the database on every call, not only at login.
- Super admin changes are recorded in an audit log.
- Sign-in alerts broadcast an empty Realtime ping; who signed in is fetched with `recent_logins`, which requires a super admin token.
- Order totals are computed server-side from menu prices.
- The public phone search shows history to anyone who knows a phone number. Acceptable for simple shops; add OTP verification if that is a concern.

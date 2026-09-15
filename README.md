# POS Billing

Static, responsive POS billing web app. Hosted on GitHub Pages, data in Supabase.

Docs: [Architecture](docs/ARCHITECTURE.md) · [User guide](docs/USER_GUIDE.md)

## Pages

| Page | Who | What |
|---|---|---|
| `index.html` | Public | Search order history by phone number |
| `adminlogin.html` | Admins | Username / password login |
| `dashboard.html` | All admins | Bento dashboard, awaiting-payment list, **New bill** modal (customer → items → Cash/UPI/Card → receipt) |
| `managebills.html` | Super admin | Search, view, change status, delete orders, print/WhatsApp receipts |
| `menu.html` | Super admin | Add / edit / hide / delete menu items, link ingredients to each item |
| `ingredients.html` | Super admin | Ingredient master list (name + unit) |
| `usage.html` | Super admin | Ingredients consumed per day (IST), CSV export |
| `staff.html` | Super admin | Add users, change roles, reset passwords, sign out devices |
| `settings.html` | Super admin | Shop name, address, phone, UPI ID, currency, receipt footer |
| `audit.html` | Super admin | Who changed bills, menu, recipes, ingredients, staff, settings |
| `account.html` | All admins | Change own password |

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
5. Log in → **Shop settings** → set shop name, UPI ID, address and receipt footer.

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

## Security notes
- All tables have RLS on with no policies; browser talks only to `SECURITY DEFINER` RPC functions.
- Login returns a 12-hour session token; admin/super checks happen in the database, not just the UI.
- Login is rate-limited (5 failures per username / 20 per IP in 15 minutes).
- Super admin changes are recorded in an audit log.
- Order totals are computed server-side from menu prices.
- The public phone search shows history to anyone who knows a phone number. Acceptable for simple shops; add OTP verification if that is a concern.

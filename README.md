# POS Billing

Static, responsive POS billing web app. Hosted on GitHub Pages, data in Supabase.

Docs: [Architecture](docs/ARCHITECTURE.md) · [User guide](docs/USER_GUIDE.md)

## Pages

| Page | Who | What |
|---|---|---|
| `index.html` | Public | Search order history by phone number |
| `adminlogin.html` | Admins | Username / password login |
| `dashboard.html` | All admins | Bento dashboard + **New bill** modal (customer → items → payment QR → Done) |
| `managebills.html` | Super admin | Search, view, change status, delete orders |
| `menu.html` | Super admin | Add / edit / hide / delete menu items |

## Setup

### 1. Supabase
1. Create project at https://supabase.com.
2. SQL Editor → paste and run `supabase/schema.sql`.
3. Create admins (SQL Editor):
   ```sql
   insert into public.admins(username, password_hash, role) values
     ('owner',   crypt('ChangeMe#1', gen_salt('bf')), 'super'),
     ('cashier', crypt('ChangeMe#2', gen_salt('bf')), 'admin');
   ```
   Change a password later:
   ```sql
   update public.admins set password_hash = crypt('NewPassword', gen_salt('bf')) where username = 'cashier';
   ```
   Passwords are stored as bcrypt hashes — always set them with `crypt(...)`, never plain text.
4. Project Settings → API → copy **Project URL** and **anon public key** into `js/config.js`. Also set `SHOP_NAME` and `UPI_ID`.

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
- Order totals are computed server-side from menu prices.
- The public phone search shows history to anyone who knows a phone number. Acceptable for simple shops; add OTP verification if that is a concern.

# Klong Phai Farm CRM

A small, zero-cost CRM: the code lives here on GitHub, but no client or
company data ever does. Actual data lives in a separate Postgres database
(hosted free on Supabase), reachable only after login, with each person's
access level enforced by the database itself — not by anything in this
code that a person could bypass.

**Who sees what:**
- **admin** (you) — every client, every field, every rep's pipeline.
- **sales** — only clients assigned to them.
- **director** — new leads only. No deal values, no won/lost history, no
  other rep's pipeline. This is enforced at the database level (see
  `sql/schema.sql`), not just hidden in the interface.

---

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) → New project. No credit card
   required for the free tier.
2. Once it's created, open **SQL Editor** → New query, paste the entire
   contents of `sql/schema.sql`, and run it. This creates all the tables,
   the roles, and the security rules in one go.
3. Open **Project Settings → API** and copy two values into `web/config.js`:
   - **Project URL** → `SUPABASE_URL`
   - **anon public** key → `SUPABASE_ANON_KEY`

   (The anon key is *meant* to be public — it can't do anything the Row
   Level Security rules don't allow. Never put the **service_role** key in
   this file or anywhere in the repo; it bypasses all security rules.)

4. Open **Project Settings → Database** and copy the **Connection string**
   (URI, "Session pooler" or direct connection both work) — you'll need this
   in step 4 for backups. Keep it private; it's the master key to your data.

## 2. Create your first users

1. **Authentication → Users → Add user**, once per person (yourself, the
   sales director, each rep). Set a real password for each — send it to
   them privately, not over an insecure channel.
2. Everyone is created as `sales` by default. Promote yourself to admin and
   the director to `director` from **SQL Editor**:
   ```sql
   update public.profiles set role = 'admin'    where id = '<your user id>';
   update public.profiles set role = 'director' where id = '<director''s user id>';
   ```
   (Find each user's id on the Authentication → Users page.)

## 3. Put the app online

The site lives in `web/`. GitHub Pages can only publish from the repo root
or a folder literally named `docs/`, so when you're ready to go live:

```bash
cp -r web docs
git add docs web
git commit -m "Publish app"
git push
```

Then in the GitHub repo: **Settings → Pages → Deploy from a branch → main →
/docs**. GitHub gives you a URL a minute or two later. Bookmark it — that's
what everyone signs into.

## 4. Turn on automatic backups

1. Generate an encryption key (run this once, keep the output somewhere
   safe — you'll need it to ever restore a backup):
   ```bash
   python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
   ```
2. In the GitHub repo: **Settings → Secrets and variables → Actions**, add:
   - `SUPABASE_DB_URL` — the connection string from step 1.4
   - `BACKUP_ENCRYPTION_KEY` — the key you just generated
   - `SUPABASE_URL`, `SUPABASE_ANON_KEY` — same as in `web/config.js`
3. That's it — `.github/workflows/backup.yml` runs every night, dumps the
   database, encrypts it, and commits it into `backups/`. The same run also
   pings Supabase so the free-tier project never goes idle long enough to
   auto-pause (that happens after 7 days of no activity).

To restore a backup if you ever need to:
```bash
export BACKUP_ENCRYPTION_KEY="<your key>"
python3 scripts/backup.py --decrypt backups/backup_20260901_030000.sql.enc backups/backup_20260901_030000.sql restored.sql
psql "<SUPABASE_DB_URL>" -f restored.sql
```

## 5. Import your existing client list (optional, one time)

See the header comment in `scripts/import_excel.py` — point it at an export
of your current client list and it'll load it in, matching sales reps to
their CRM logins by email.

---

## Known limitations, honestly

- **2FA isn't wired into the sign-up flow yet.** The login screen *checks*
  for a 2FA code if an account has one enrolled, but enrolling (scanning a
  QR code into an authenticator app) has to be done from the browser
  console for now: while logged in, run
  `await supabase.auth.mfa.enroll({ factorType: 'totp' })` and follow the
  returned QR code. A proper "Enable 2FA" button in Settings is the natural
  next addition.
- **The director's row-level restriction is solid; the column restriction
  is not database-enforced.** Row Level Security guarantees a director can
  only ever *see rows* where `stage = 'lead'` — that's a real database
  guarantee, not just a UI filter. Hiding the `deal_value`/`notes` columns
  on those rows is currently done by the app simply never asking for them
  (`director_leads` view), which is fine in practice since deal value is
  rarely populated yet at lead stage — but a determined director with
  browser dev tools could still query those columns directly on lead rows.
  If that ever needs to be airtight, the fix is mapping each app role to
  its own Postgres database role with column-level `GRANT`s — a bigger
  change, worth doing only if it becomes a real concern.
- **No password reset flow yet** — reset a forgotten password from the
  Supabase dashboard (Authentication → Users → ⋯ → Send password recovery)
  until a self-service "forgot password" link is added.
- Supabase's free tier gives a 7-day point-in-time snapshot automatically;
  the nightly Action above is what gives you backups older than 7 days.

## Cost

$0 required. Supabase's paid tier ($25/month) only becomes relevant if you
outgrow the free database size (500MB — a very large amount of headroom for
a client list like this) or want same-day support from Supabase directly.

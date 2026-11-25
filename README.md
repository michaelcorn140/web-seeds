# Seeds Studio website

Static site, no build step. Open `index.html` or deploy the folder as-is (GitHub Pages, Vercel, Netlify).

- Font: Open Sauce Sans (SIL Open Font License), self-hosted in `fonts/`.
- Prices, slot count and most social links are still placeholders.

## Accounts & gacha (Supabase)

Without Supabase the site runs in **demo mode**: anyone can open packs, nothing is saved.
With Supabase, visitors sign up with email + password, each account gets **1 pull**,
and the pull is rolled **on the server** (`pull_gacha()`), so it can't be faked from the browser.

### Setup (once)

1. Create a project at <https://supabase.com/dashboard> (region: Southeast Asia / Singapore).
2. **SQL Editor → New query**, paste all of [`supabase/schema.sql`](supabase/schema.sql), **Run**.
3. **Project Settings → API**: copy the *Project URL* and the *anon / publishable* key into
   [`js/supabase-config.js`](js/supabase-config.js). (Never use the `service_role` / secret key.)
4. **Authentication → URL Configuration**: set *Site URL* to the live address,
   e.g. `https://michaelcorn140.github.io/web-seeds/`.
5. Sign up on the site with the studio email, then make it an admin in the SQL Editor:

   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'studio@example.com';
   ```

   Admins get the **Studio panel** (players, prizes claimed, orders, gacha rates).

### How it fits together

| File | What it does |
| --- | --- |
| `supabase/schema.sql` | Tables (`players`, `orders`, `settings`, `admins`), row-level security, sign-up trigger, gacha + admin functions |
| `js/supabase-config.js` | Project URL + anon key (empty = demo mode) |
| `js/sb.js` | Bridge between the page and Supabase (auth, data, realtime) |
| `js/vendor/supabase.js` | `@supabase/supabase-js` 2.119.0 (MIT), self-hosted |

Security notes:
- Players can only read their own row and only change nick / handle / avatar.
- `used`, `history` and `claimed` change only through `pull_gacha()` and the admin functions.
- Orders and gacha rates are admin-only, so visitors can't see the odds.
- Email confirmation is turned OFF (Authentication → Sign In / Providers → Email → Confirm email), so new accounts can pull right away. Turn it back on together with custom SMTP if fake accounts become a problem.

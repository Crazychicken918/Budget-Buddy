# Budget Buddy

A personal finance tracking web app — income, expenses, assets and liabilities,
multi-account support, loan tracking with prime-rate linking, and a recurring
payments calendar.

## Stack
- Single-file static site (`index.html`) — no build step
- [Supabase](https://supabase.com) for auth + Postgres database (schema in `schema.sql`)
- Deployed on [Vercel](https://vercel.com)

## Files
- `index.html` — the app
- `schema.sql` — database schema (safe to re-run; every statement is idempotent)
- `privacy.html` — privacy policy page, linked from the app footer

## Setup
1. Run `schema.sql` in your Supabase project's SQL editor.
2. Fill in `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the top of `index.html`'s `<script>` block.
3. Deploy `index.html` and `privacy.html` as a static site (e.g. on Vercel).

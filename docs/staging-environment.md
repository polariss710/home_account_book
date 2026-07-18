# Cash Staging Environment

Status date: 2026-07-18

- Baseline: `47731f4522689fa686b153c7ba997adc92330465` (`codex/cash-dev-environment`).
- Branch: `codex/cash-staging-environment`.
- Supabase project: `aozora-school-v3-staging` (`bxnxdkbjlxkcqwzzeyds`, Tokyo).
- School API: `https://aozora-school-system-v3-api-staging.onrender.com/api`.
- Cash site: `https://aozora-cash-v3-staging.onrender.com`.

The committed frontend config contains a staging-only anon-key placeholder. Render must replace
`__STAGING_SUPABASE_ANON_KEY__` from its `STAGING_SUPABASE_ANON_KEY` environment variable during
the build. This branch must never point at the current Cash production or School v2 projects, and
staging must not be populated from production exports.

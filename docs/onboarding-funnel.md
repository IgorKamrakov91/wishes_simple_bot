# Onboarding funnel contract

`User#onboarding?` means `onboarding_eligible && first_item_at.nil?`. Lists and
gifts already present on an account do not override an explicit funnel reset.
New accounts are eligible. Migration excludes all pre-existing accounts,
including those without gifts, and backfills `first_list_at` / `first_item_at`
from the earliest surviving records. Missing historical contacts/sources stay
unknown. Deleted historical gifts cannot be reconstructed.

All timestamps are UTC datetimes. The first list/item milestones are written
by model creation callbacks in the same transaction as the saved record. This
covers manual input, URL-first input, AI choices and future preset-list buttons.
Later saves, webhook retries and deletions do not replace the milestones.

| User field | Meaning |
|---|---|
| `first_contact_at`, `first_contact_kind` | First observed contact for the new cohort: `start`, `campaign_start`, `share_link`, `inline_query`, `callback`, or `message`. |
| `acquisition_source` | First explicit `src_<tag>` campaign observed for that cohort; independent of contact kind. Never an invitation token. |
| `first_private_start_at` | First recognized private `/start`, including campaign and invitation starts. Not inferred from inline queries or callbacks. |
| `first_list_at`, `first_item_at` | First successfully saved owned list/gift, retained after deletion. |
| `first_share_query_at` | First explicit inline `share_<owned list ID>` query. A card request, not proof it was sent. |
| `first_shared_list_open_at` | First authorized invitation opening by a guest; excludes the owner's own opens and unavailable links. |

Campaign tags accept 1–60 ASCII letters, digits, underscores or hyphens, so
`src_` plus the tag fits the 64-character payload. `/start@OurBot src_<tag>`
normalizes to the same `/start` flow as the plain command, after attribution.
Other arguments keep their existing routing, access checks and input policy.
Group prompts preserve valid campaign payloads without creating an account;
tracking begins when the user continues in private.

These fields count **people reaching a milestone**, not every repeated event.
Use `first_private_start_at` as the denominator for new private starts and
compare `first_item_at` within 24 hours; report contacts originating in inline
mode separately. `last_seen_at` supports activity/return queries. Joining
`list_viewers` to owned wishlists identifies which list attracted a guest;
neither clipboard actions nor query responses prove that a message was sent.

## Manual reset

```sh
bin/rails 'onboarding:reset[797229231]'
```

The positive Telegram ID is required; missing, malformed and unknown IDs fail
without updates. The task locks one user, clears only funnel timestamps/source
and sets `onboarding_eligible` to true. It prints JSON snapshots before and
after. Lists, gifts, pending input, profile, preferences and `updated_at` are
unchanged. The next private start becomes a fresh funnel observation. This is
for an explicitly selected test account; it also resets its analytics cohort.
The task is provided here, not executed against production.

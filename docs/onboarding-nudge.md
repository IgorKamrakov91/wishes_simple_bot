# One onboarding reminder

`OnboardingNudgesJob` runs every 15 minutes. Only eligible users who started a
private chat, have not saved their first gift, and have reminders enabled qualify.
Delivery is at least 24 hours after both the private start and the latest activity,
in the next 12:00–18:00 Moscow window. Activity while queued or generating ideas
postpones the reminder; saving a gift or opting out cancels it.

An empty owned list gets up to three Yandex AI ideas using the empty-list prompt
(occasion from the list title, varied categories and price levels). The request
contains only the list title and empty gift context. Automatic requests count
toward the shared daily application cap, but do not spend or block the user's
personal allowance. Both generation jobs share the two-worker concurrency limit.
Without a list, with AI disabled, at the global cap, or after an AI failure, the
reminder uses three fixed examples. Existing input is resumed without changes.

One unique `onboarding_nudges` row per user survives queue retries and funnel
resets. A preparation claim prevents duplicate generation. Ideas and their
request ID are saved before Telegram delivery. A preparation abandoned for two
minutes recovers the saved answer or fixed examples, never another model call.
Deleted or changed target lists use fixed examples without another request.

Delivery claims are atomic and stay claimed after uncertain HTTP failures, so a
timeout cannot send a duplicate. Known rejected requests can retry in the daytime
window (at most three attempts); 400, 403 and 404 are terminal. The scheduler
revisits due retries. The send conditions are checked again immediately before
HTTP; no database locks are held during either external request.

“Don't remind me” and the settings switch control `users.notify_onboarding`.
Turning it back on does not resend a delivered/terminal reminder.
`onboarding:reset` changes only funnel fields, not reminders or this preference.
English and Russian reminder/settings copy are supplied; the nudge captures the
app locale when scheduled, like existing AI requests (no per-user locale exists).

Validation uses an isolated PostgreSQL database and mocked model/Telegram calls;
the live Telegram flow and deployment are verified separately by the owner.

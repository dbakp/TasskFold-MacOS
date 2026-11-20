# Auth email templates (hosted)

`recovery.html` is the password-reset email live on the hosted project since 20 Nov 2026.
It sends a 6-digit code (`{{ .Token }}`) that the apps' Forgot password screen verifies
(`RecoveryCode.length = 6`), so hosted `auth.email.otp_length` must stay 6.

The main `supabase/config.toml` declares only function settings and must not be pushed.
To re-apply this template, use a scratch workdir whose config.toml declares only:

    project_id = "zqxflydiyfjeedqvyova"
    [auth.email]
    otp_length = 6
    [auth.email.template.recovery]
    subject = "Your Taskfold reset code"
    content_path = "./supabase/templates/recovery.html"

then `supabase config diff --workdir <dir> --remote=<ref>` and review before `config push`.

## Confirm email (sign-up confirmation)

`confirmation.html` is the "Confirm signup" email, prepared for when hosted **Confirm email**
(`auth.email.enable_confirmations`) is switched on. It is **not applied yet**: confirmation is OFF on the hosted
project today. The apps work in both states. With it off, sign-up returns a session and goes straight in. With it on,
sign-up shows "Check your email" and the person types the 6-digit `{{ .Token }}` code, which the apps verify with
`/auth/v1/verify` type `signup`. Signing in with an unconfirmed account opens the same step. Hosted `otp_length` must
stay 6 (`RecoveryCode.length`).

**Set up custom SMTP first.** The built-in Supabase sender is limited to a few emails per hour across the whole
project, so with confirmation on, sign-ups would be refused ("Too many emails") almost at once. Configure a custom SMTP
sender (Dashboard > Authentication > Emails > SMTP Settings) and send yourself a test before going further.

To apply the template and turn confirmation on, use a scratch workdir (never the main `supabase/config.toml`) whose
config.toml declares only:

    project_id = "zqxflydiyfjeedqvyova"
    [auth.email]
    enable_confirmations = true
    otp_length = 6
    [auth.email.template.confirmation]
    subject = "Confirm your Taskfold account"
    content_path = "./supabase/templates/confirmation.html"

with `confirmation.html` copied to `<dir>/supabase/templates/`. Then run
`supabase config diff --workdir <dir> --remote=<ref>` first and check that the only differences are
`enable_confirmations` and the confirmation template, and only then `supabase config push --workdir <dir>`.
Afterwards create a throwaway account with an address you own and confirm the code arrives and works in both apps.
To turn confirmation off again, push the same config with `enable_confirmations = false`.

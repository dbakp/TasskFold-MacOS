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

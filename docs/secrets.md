# Secrets this template keeps in OpenBao

Con Services keeps secrets in an OpenBao KV version 2 mount (`openbao.kvPath`,
default `conservices`). Nothing secret is written to Git. External Secrets
Operator creates the random values and copies them into Kubernetes Secrets.
You enter provider credentials (S3, SMTP, Cloudflare, a registry token, an
optional Google service-account key) with `bootstrap/scripts/openbao-seed.sh`
or `openbao-seed.ps1`, or in the OpenBao web UI.

The full inventory, including who may read each value and how the applications
use it, is on the
[Secrets](https://aglelectronics.github.io/con-services/operations/secrets/)
page of the Con Services site. The paths below are the ones this template
creates. A generated value is written once (`updatePolicy: IfNotExists`) and
an upgrade does not replace it.

## DEN_CREDENTIAL_KEY

| | |
| --- | --- |
| OpenBao path | `conservices/modules/den/credential-key` |
| Property | `key` |
| Kubernetes Secret | `den-secrets` in `conservices-den`, key `DEN_CREDENTIAL_KEY` |
| Who uses it | Den's backend |
| Created by | External Secrets, generator `conservices-random-credential` |

Den derives each paired module's server-to-server credential from this key
with HMAC-SHA256, then calls `GET /api/portal/todos` on the module with that
credential. The module stores the same credential encrypted with its own
`DEN_LINK_ENCRYPTION_KEY`. The value is 48 letters and digits (no symbols),
which is more than the 32 characters Den requires. It is a different
generator from Desk's `modules/desk/secret-key`, which also uses a property
named `key`.

The PushSecret creates the entry the first time it syncs. Later syncs,
including an upgrade of this template, leave the existing value in place.
Deleting the entry and letting External Secrets write a new one is a
rotation: portal to-dos for a module stay empty until that module is paired
again. The module keeps reaching Den with its current credential until then.
Pair every module again after the new key is in `den-secrets` and
`den-backend` has been restarted.

To rotate it on purpose:

1. Delete the OpenBao entry (do not edit the PushSecret to force a new value
   while the entry still exists; `IfNotExists` will not replace it):

    ```sh
    bao kv metadata delete conservices/modules/den/credential-key
    ```

2. Ask the PushSecret to run now, then the ExternalSecret:

    ```sh
    kubectl -n external-secrets annotate pushsecret generated-den-credential-key force-sync="$(date +%s)" --overwrite
    kubectl -n conservices-den annotate externalsecret den-secrets force-sync="$(date +%s)" --overwrite
    ```

    On PowerShell, replace `$(date +%s)` with
    `$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())`.

3. Restart Den, then pair every module again (Den → Modules → Pair, paste
   the URL into the module):

    ```sh
    kubectl -n conservices-den rollout restart deploy/den-backend
    ```

A new installation does this for you: the key exists before the first
pairing, so the credentials Den hands out are derived from it. You do not
type the key anywhere.

Replacing the key without pairing again does not lock modules out of Den.
It only stops Den calling them for the portal's to-do list, until each one
is paired again.

## Other generated entries

| OpenBao path | Property | Becomes |
| --- | --- | --- |
| `infra/postgres/superuser` | `password` | CloudNativePG superuser; `PG_ADMIN_URL` in `den-operator-secrets` |
| `infra/postgres/roles/<role>` | `password` | that role's login and the application's `DATABASE_URL` |
| `modules/den/operator-token` | `token` | `OPERATOR_TOKEN` in `den-secrets` and `den-operator-secrets` |
| `modules/den/credential-key` | `key` | `DEN_CREDENTIAL_KEY` in `den-secrets` |
| `modules/<module>/den-link` | `key` | `DEN_LINK_ENCRYPTION_KEY` |
| `modules/<module>/service-token` (`learn`, `wiki`, `tasks`) | `token` | that module's service token, and the matching hook on HR |
| `modules/hr/service-token` | `hr_service_token` | `HR_SERVICE_TOKEN` on HR and on every enabled module that checks the role catalog |
| `modules/hr/directory-token` | `hr_directory_token` | `HR_DIRECTORY_TOKEN` on HR and, when HR is enabled, on Wiki |
| `modules/learn/feedback-pepper` | `pepper` | `LEARN_FEEDBACK_PEPPER` |
| `modules/desk/secret-key` | `key` | `DESK_SECRET_KEY` |
| `infra/keycloak/bootstrap-admin` | `password` | Keycloak's temporary admin, first start only |
| `infra/keycloak/clients` | `den-keycloak`, `hr-provisioner`, `learn-provisioner` | those client secrets |

External Secrets 2.14 cannot mark one property optional. `DEN_LINK_ENCRYPTION_KEY_PREVIOUS`
and `DESK_SECRET_KEY_PREVIOUS` are therefore not copied into the Kubernetes
Secrets. Do not delete `modules/<module>/den-link` or `modules/desk/secret-key`.
Replacing a module's `den-link` key without the
[two-step rotation](https://aglelectronics.github.io/con-services/operations/secrets/#den-link-encryption-key)
makes that module pair again. Replacing Desk's `secret-key` without keeping
the old value makes stored mailbox passwords unreadable: enter them again.

SMTP passwords and Telegram tokens must exist as OpenBao entries. An empty
value keeps the feature off. Skipping the prompt in `openbao-seed.sh` or
`openbao-seed.ps1` stores that empty value. A missing entry stops the
ExternalSecret.

## Entries you type

S3 keys, optional Telegram tokens, optional SMTP passwords, the Keycloak
mail server, the Cloudflare token and the registry login are listed by
`openbao-seed.sh` / `openbao-seed.ps1` for the modules you enabled. Two of
them are easy to miss:

- `modules/den/smtp`, property `password`, becomes `DEN_SMTP_PASSWORD`.
  Optional. Leave it unset and modules send mail without a login. It is not
  stored in Den's database.
- `modules/desk/google`, property `credentials.json`, becomes Secret
  `desk-google` key `service-account.json`. Optional. Desk stays on IMAP
  until you store the JSON **and** set
  `modules.desk.values.google.enabled: true` (that also opens egress to
  Google's APIs).
- `modules/hr/google-workspace`, property `credentials.json`, is asked for
  only when `modules.hr.values.googleWorkspace.enabled` is true. It becomes
  Secret `hr-google-workspace`.

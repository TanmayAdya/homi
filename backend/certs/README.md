# Public Supabase database CA

`supabase-root-2021.crt` is a public CA certificate, not a credential or private
key. The runtime container uses it to verify both the database certificate chain
and hostname. Keep TLS verification enabled.

Obtained through the project's Database Settings → SSL Configuration download on
October 17, 2026, from Supabase's official distribution URL:

https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt

- Subject: Supabase Root 2021 CA / Supabase Inc
- Valid until: April 26, 2031
- SHA-256 certificate fingerprint:
  `80:70:25:AD:50:D4:ED:21:9D:2C:9C:7D:29:9C:00:4F:82:4E:B0:0C:F7:F6:5A:FE:F6:07:D0:7B:72:E6:CA:FA`

When Supabase rotates this CA, review the official Dashboard download, validate
its subject/CA constraints/validity and update the file before redeploying. Do
not fetch a new certificate dynamically at application startup or trust a
certificate copied from a failed TLS connection. Other PostgreSQL providers need
their own verified trust configuration via `SAFEATHOME_DATABASE_CA_FILE`.

See [Supabase SSL enforcement](https://supabase.com/docs/guides/platform/ssl-enforcement)
and [the hosting guide](../../docs/https-hosting.md).

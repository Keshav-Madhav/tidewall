# Security

Tidewall runs with no special permissions: it reads window positions and app names from
`CGWindowListCopyWindowInfo`, serves its own bundled pages over a private `tidewall://` scheme, and makes no network
requests except Wind Map's public weather data from Open-Meteo.

If you find a security problem (for example a way for a web page to read files outside the app's `themes` folder, or
to drive the app through its window's message bridge), please **don't open a public issue**. Use GitHub's
[private vulnerability reporting](../../security/advisories/new) for this repository instead, with steps to reproduce.
You'll get a reply within a week.

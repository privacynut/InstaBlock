# InstaBlock website

Static promo site + support form, deployed as a Cloudflare Worker with static
assets (`public/`) and one API route (`POST /api/support`) that emails support
requests through Cloudflare Email Routing.

## Deploy

```bash
cd site
npx wrangler login          # one-time: opens a browser to authorize your Cloudflare account
npx wrangler deploy         # publishes to https://instablock.app (and www.instablock.app)
```

`wrangler.toml` declares both hostnames as Workers custom domains, so the deploy
creates the DNS records and certificates automatically — the `instablock.app`
zone just has to be in the same Cloudflare account. Delete any pre-existing
A/AAAA/CNAME records for `@` and `www` first if the deploy reports a conflict.

## Support form email (one-time setup)

The form posts to `/api/support`; the worker sends the email with the
`send_email` binding, which only works when:

1. **Email Routing** is enabled on `instablock.app` (Cloudflare dashboard → the
   zone → Email → Email Routing). Cloudflare adds the MX/SPF records for you.
2. `leo+instablock@pechersky.me` is added and **verified** as a destination
   address there (Email Routing → Destination addresses). The verification mail
   lands in the base inbox; plus-addressing is fine.
3. `SUPPORT_FROM` is `support@instablock.app`, on that same zone. The site pages
   present this address publicly, so add a routing rule
   `support@instablock.app → leo+instablock@pechersky.me` (Email Routing →
   Routing rules) so mail sent to it — and replies to support emails — reach you.

Until that's done the form returns 503 and the page automatically shows a
`mailto:` fallback, so support is never dead.

## Local preview

```bash
npx wrangler dev            # http://localhost:8787 — email sending is stubbed locally
```

## Search engines

- `tools/indexnow.sh` submits every sitemap URL to IndexNow (Bing, Yandex, Seznam,
  Naver share it). The key is in `indexnow.key` and served from `public/<key>.txt`;
  run it after deploying content changes.
- Google doesn't use IndexNow: submit `https://instablock.app/sitemap.xml` once in
  Google Search Console, and also in Bing Webmaster Tools for reporting.

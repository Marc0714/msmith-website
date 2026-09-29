# marcsmith88 — Personal Site

Static site (no build step) for Marc Smith's digital résumé / personal site.

## Structure

```
index.html          Main page (all sections) — includes JSON-LD Person schema,
                     Open Graph/Twitter tags, and SEO meta tags
css/styles.css       All styling
js/main.js           Nav toggle, scroll reveal, animated stat counters
assets/              Favicon + downloadable résumé PDF
robots.txt           Crawler rules; blocks low-value SEO scrapers, allows AI/search bots
sitemap.xml          Single-page sitemap
llms.txt             AI-crawler-friendly summary (llms.txt standard)
```

### AI/SEO discoverability

- **`robots.txt`** and **`sitemap.xml`** — standard crawler directives.
- **`llms.txt`** — a structured, human-and-AI-readable summary of who Marc is
  and what he's done, per the [llms.txt](https://llmstxt.org) convention.
- **JSON-LD `Person` schema** (in `index.html`'s `<head>`) — lets search
  engines and AI assistants parse name, title, employer, education, and
  skills as structured data rather than guessing from prose.
- **Open Graph / Twitter meta tags** — control how the site previews when
  shared on LinkedIn, Slack, iMessage, etc. There's no dedicated OG image
  yet (`assets/favicon.svg` isn't a good fit — OG previews need a PNG/JPG,
  ideally 1200×630). Add one at `assets/og-image.png` and wire it into
  `og:image` / `twitter:image` in `index.html` if you want a richer preview
  card.

All three new root files (`robots.txt`, `sitemap.xml`, `llms.txt`) are synced
by `scripts/deploy.sh` and `scripts/update.sh` alongside `index.html`.

### Cloudflare's "AI-friendly domain" checklist

Cloudflare's domain scan (Level 1: Quick Wins) grades a few extra signals:

- **Content Signals** — a `robots.txt` extension declaring whether search
  indexing, AI retrieval, and AI training are each allowed. Added as
  `Content-Signal: search=yes, ai-input=yes, ai-train=yes` in `robots.txt`.
- **Markdown Negotiation** — serving a markdown version of a page when a
  client's `Accept` header requests `text/markdown`, instead of HTML. Handled
  at the edge: the CloudFront Function (`WWWRedirectFunction` in
  `cloudformation.yaml`) rewrites `/` and `/index.html` to `/llms.txt` when
  it sees that Accept header, reusing the existing llms.txt content rather
  than maintaining a second markdown copy of the page. **Requires
  redeploying the stack** (`./scripts/deploy.sh`) since it's a
  CloudFormation change, not just a file sync.
- **AI Crawler Rules** ("Manage AI bots") — this is a Cloudflare bot-management
  feature that only works when Cloudflare is proxying traffic (orange cloud).
  This site's DNS is intentionally **DNS-only (grey cloud)** — CloudFront
  handles TLS and CDN directly, and layering Cloudflare's proxy on top would
  mean two CDNs in front of one bucket and risks SSL conflicts. Skipped for
  that reason; revisit only if you're willing to change the DNS proxy mode.

Levels 2 and 3 (API Catalog, OAuth Discovery, MCP Server Card, A2A Agent
Card, WebMCP, etc.) and the Commerce section are aimed at sites that expose
actual services or products to agents. Not applicable to a static résumé
site with no backend — skipped.

## Local preview

```
python3 -m http.server 8000
```

Then open http://localhost:8000

## Deploying to S3 + CloudFront

All infrastructure (S3 bucket, CloudFront distribution, ACM certificate,
security headers, OAC) is defined in `cloudformation.yaml` and deployed to
`us-east-1` (required — CloudFront ACM certs are region-locked there).

DNS is managed in Cloudflare; TLS certificates are issued by ACM and
DNS-validated via CNAME records added to Cloudflare.

### Prerequisites

| Tool | Purpose |
|------|---------|
| `aws` CLI | All AWS operations |
| `jq` | JSON parsing in deploy scripts |

An AWS profile named `gcs` must be configured (`~/.aws/config`) with
permissions for CloudFormation, S3, CloudFront, and ACM.

### First deploy

```
./scripts/deploy.sh msmith-website us-east-1 gcs
```

What happens:
1. CloudFormation creates the S3 bucket, CloudFront distribution, ACM
   certificate, and CloudFront Function (www → apex redirect)
2. The script polls for the ACM DNS validation CNAMEs and prints them —
   **add both to Cloudflare as DNS only (grey cloud)**
3. CloudFormation waits until the cert validates (1–5 min after adding the
   CNAMEs)
4. Static files (`index.html`, `css/`, `js/`, `assets/`) are synced to S3 —
   `index.html` is set to never cache; everything else caches for a day
   (CloudFront is invalidated on every deploy, so updates still show up
   immediately)
5. CloudFront cache is invalidated

After deployment, add two more DNS records to Cloudflare (printed at the end
of the script):

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| CNAME | `@` | `<dist>.cloudfront.net` | DNS only (grey cloud) |
| CNAME | `www` | `<dist>.cloudfront.net` | DNS only (grey cloud) |

**These must be DNS only (unproxied).** CloudFront handles CDN, caching, and
TLS — Cloudflare proxying on top causes SSL conflicts.

### Subsequent deploys

After content changes, run:

```
./scripts/update.sh msmith-website us-east-1 gcs
```

This skips CloudFormation (infrastructure is unchanged) and just does:
S3 sync → CloudFront invalidation.

> Only `index.html`, `css/`, `js/`, and `assets/` are synced — `Resume/`,
> `README.md`, `cloudformation.yaml`, and `scripts/` stay local. If you add a
> new top-level file or folder that should be published, add it to the
> `--include` list in both scripts.

## Updating content

All résumé content lives directly in `index.html` (Experience, Skills,
Certifications, Education, Contact sections) — edit it there. Source
material (original résumé/LinkedIn exports) is kept in `Resume/` for
reference and is not deployed.

#!/usr/bin/env python3
"""Generate guide pages, sitemap, robots.txt, llms.txt and patch <head> tags
on the hand-written pages. Run from site/: python3 tools/gen-pages.py"""
import json, re, pathlib, datetime

PUB = pathlib.Path("public")
SITE = "https://instablock.app"
ONE_LINER = ("InstaBlock is a free iOS and Android app that blocks Instagram Reels and TikTok videos "
             "while keeping DMs, stories and photos working.")
TODAY = datetime.date(2026, 9, 3).isoformat()

HEAD = ('<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<link rel="icon" href="/assets/favicon.png"><link rel="apple-touch-icon" href="/assets/icon.png">'
        '<link rel="stylesheet" href="/styles.css">')
NAV = ('<header><div class="wrap"><nav><a class="brand" href="/"><img src="/assets/icon.png" alt=""><span>InstaBlock</span></a>'
       '<ul><li><a href="/#how">How it works</a></li><li><a href="/guides">Guides</a></li><li><a href="/#faq">FAQ</a></li>'
       '<li><a href="/support">Support</a></li><li><a href="/privacy">Privacy</a></li></ul></nav></div></header>')
FOOT = ('<footer><div class="wrap"><div class="row"><div>© 2026 InstaBlock · Not affiliated with Instagram, Meta, or TikTok.</div>'
        '<div><a href="/guides">Guides</a> · <a href="/support">Support</a> · <a href="/privacy">Privacy Policy</a> · <a href="/terms">Terms of Service</a></div></div></div></footer>')

def social(path, title, desc, image="/assets/01-reels-blocked.png", kind="website"):
    url = SITE + path
    return (f'<title>{title}</title><meta name="description" content="{desc}">'
            f'<link rel="canonical" href="{url}">'
            f'<meta property="og:type" content="{kind}"><meta property="og:site_name" content="InstaBlock">'
            f'<meta property="og:url" content="{url}"><meta property="og:title" content="{title}">'
            f'<meta property="og:description" content="{desc}"><meta property="og:image" content="{SITE}{image}">'
            f'<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{title}">'
            f'<meta name="twitter:description" content="{desc}"><meta name="twitter:image" content="{SITE}{image}">')

def ld(obj):
    return '<script type="application/ld+json">' + json.dumps(obj, ensure_ascii=False) + '</script>'

ORG = {"@type": "Organization", "name": "InstaBlock", "url": SITE + "/", "logo": SITE + "/assets/icon.png",
       "contactPoint": {"@type": "ContactPoint", "email": "support@instablock.app", "contactType": "customer support"}}
APP = {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": "InstaBlock",
       "operatingSystem": "iOS 17 or later, iPadOS 17 or later, Android 7 or later", "applicationCategory": "UtilitiesApplication",
       "applicationSubCategory": "Digital wellbeing / distraction blocker",
       "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
       "description": ONE_LINER + " Tap for a 1, 5, 15 or 30-minute break when you want to watch; videos stop again automatically. No account, no tracking; the filter runs entirely on-device.",
       "url": SITE + "/", "installUrl": "https://play.google.com/store/apps/details?id=com.helpon.instablock",
       "downloadUrl": ["https://play.google.com/store/apps/details?id=com.helpon.instablock"],
       "screenshot": [SITE + f"/assets/0{i}-{n}.png" for i, n in [(1, "reels-blocked"), (2, "take-a-break"), (3, "times-up"), (4, "private")]],
       "featureList": ["Blocks Instagram Reels and TikTok videos", "Instagram DMs, stories, comments and photos keep working",
                       "Timed breaks: hold a card for 5 seconds to allow videos for 1, 5, 15 or 30 minutes, then they block again automatically",
                       "Always on — no off switch to cheat with", "No account, no analytics, no servers; on-device network filter",
                       "Steps aside for other VPNs and notifies you; comes back when they disconnect",
                       "Android: filter scoped to the Instagram and TikTok apps only"],
       "author": {"@type": "Person", "name": "Leonid Pechersky"}, "publisher": ORG, "datePublished": TODAY, "isAccessibleForFree": True}

HOME_FAQ = [
    ("Why not just use Screen Time?", "Screen Time blocks the whole app, so you either lose your messages or tap \"Ignore Limit\" and keep scrolling. InstaBlock removes only the addictive part and leaves the useful part alone."),
    ("Does it work with TikTok too?", "Yes. TikTok's video servers are blocked the same way. Since TikTok is all video, the feed effectively stops loading while blocking is on. A break brings it right back."),
    ("Is it really a VPN? Does my traffic go somewhere?", "It uses iOS's VPN framework to run a filter on your phone, but it has no server. Your traffic goes exactly where it always went — the app just refuses to let video servers stream at full speed."),
    ("Can I turn blocking off?", "You can pause it for 1, 5, 15 or 30 minutes by holding a duration card for 5 seconds — long enough to notice you're choosing, short enough not to be annoying. After each break the cards lock for a few seconds (5–30 s, matching the break) so one break can't roll straight into the next; \"Block videos now\" is always one tap during a break. There's deliberately no permanent off switch — deleting the app (or its VPN profile in Settings) is the only way out."),
    ("Does it drain battery or slow the internet?", "No. Only traffic to Instagram's and TikTok's video servers passes through the filter; everything else never touches it."),
    ("Does it collect anything?", "Nothing. There's no backend to collect it with."),
    ("Can I use InstaBlock together with my regular VPN?", "Not at the same time — phones allow one active VPN and InstaBlock's filter counts as one. When you turn on another VPN, InstaBlock steps aside and notifies you that videos are no longer blocked; when that VPN disconnects, InstaBlock comes back (one tap on the notification on iPhone; automatically or via a one-tap notification on Android). It never kicks your other VPN off on its own."),
    ("Why does the app say 'Paused — another VPN is active'?", "Another VPN holds the phone's VPN slot, so InstaBlock's filter isn't running and videos play. Turn that VPN off, or tap 'Turn InstaBlock back on' to let InstaBlock take over."),
    ("Does it keep working when I switch between Wi-Fi and cellular?", "Yes. The filter follows the phone across networks and re-checks its settings on every switch."),
    ("Is there an Android version?", "Yes — <a href=\"https://play.google.com/store/apps/details?id=com.helpon.instablock\" rel=\"noopener\">InstaBlock is on Google Play</a>. It works the same way with the same design, and applies the filter only to the Instagram and TikTok apps. Android asks for VPN permission again after another VPN app has been used."),
]
def faq_ld(pairs):
    return {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": a}} for q, a in pairs]}

# ---------------------------------------------------------------- guides
GUIDES = [
 dict(slug="block-instagram-reels-without-deleting-instagram",
  title="How to block Instagram Reels without deleting Instagram (iPhone)",
  desc="You can block Reels on iPhone and still use Instagram DMs, stories and photos. Here's why Screen Time can't do it and what does.",
  answer="Yes — you can block Instagram Reels on an iPhone without deleting Instagram or losing your messages. iOS has no built-in setting for it, and Instagram doesn't offer one either, but a local network filter like InstaBlock can stop just the video servers while everything else in the app keeps working.",
  body="""
<h2>Why there's no setting for this</h2>
<p>Instagram has never shipped an option to disable Reels; the closest it offers is a per-video "Not interested" and a daily time reminder you can dismiss. iOS Screen Time works at the app level — it can limit or block <em>Instagram</em>, but it has no idea what a Reel is. That leaves most people choosing between deleting the app (and losing DMs, group chats and stories) or white-knuckling it.</p>
<h2>What actually works: block the video, not the app</h2>
<p>Instagram loads photos and messages from its own servers, and streams video from content delivery hosts. A filter running on your phone can slow those video hosts to a trickle. Photos are small enough to get through; a video needs sustained bandwidth and simply never starts. From inside Instagram it looks like Reels are "broken" — the tab opens, the spinner turns, nothing plays — while the feed, DMs, stories and comments behave normally.</p>
<p>That is exactly what InstaBlock does:</p>
<ol>
<li>Install <a href="/">InstaBlock</a> from the App Store and open it once. iOS asks to add a VPN configuration — tap <strong>Allow</strong>. (It's a local filter; nothing is routed through a server.)</li>
<li>Blocking is now on, permanently. Force-quit Instagram and reopen it: Reels stop loading, DMs work.</li>
<li>When you genuinely want to watch something, tap <strong>1, 5, 15 or 30 minutes</strong>. Reels come back for that long and then stop again on their own — you don't have to remember to re-enable anything.</li>
</ol>
<h2>What to expect</h2>
<ul>
<li>Reels and video posts stall instead of playing; Instagram doesn't crash.</li>
<li>Photos may load slightly slower than usual. Messages are unaffected.</li>
<li>A VPN badge appears in the status bar while the filter is on.</li>
<li>Videos Instagram already downloaded (for example during a break) may still play once from cache.</li>
</ul>
<h2>Other options, honestly</h2>
<ul>
<li><strong>Screen Time app limit</strong>: blocks all of Instagram; one tap on "Ignore Limit" defeats it.</li>
<li><strong>Delete the app, use the website</strong>: instagram.com in Safari has a much weaker Reels experience, but DMs are clunky and you lose notifications.</li>
<li><strong>Log out between sessions</strong>: adds friction, changes nothing about the feed once you're in.</li>
</ul>
""",
  faq=[("Can I block Reels but keep Instagram messages?", "Yes. A network filter that limits only Instagram's video servers, such as InstaBlock, stops Reels from playing while DMs, stories and photos keep working."),
       ("Does Instagram have a setting to turn off Reels?", "No. Instagram offers 'Not interested' on individual videos and a dismissible daily time reminder, but no way to disable Reels."),
       ("Can Screen Time block only Reels?", "No. Screen Time limits apps, not features inside an app; it can only block all of Instagram, and the limit can be ignored with one tap.")]),
 dict(slug="turn-off-reels-on-iphone",
  title="How to turn off Reels on iPhone — and why Screen Time doesn't work",
  desc="There is no Reels off switch in Instagram or iOS. Here's what each workaround does, what fails, and the one approach that keeps DMs working.",
  answer="You can't turn off Reels inside Instagram or in iOS settings — no such switch exists. What you can do on iPhone is stop Reels from loading with an on-device network filter, which keeps the rest of Instagram working. Screen Time is not that: it only blocks the whole app, and its limit can be bypassed with one tap.",
  body="""
<h2>What people try first (and why it fails)</h2>
<table style="border-collapse:collapse;width:100%"><thead><tr><th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)">Approach</th><th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)">Result</th></tr></thead><tbody>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Screen Time app limit on Instagram</td><td style="padding:8px;border-bottom:1px solid var(--line)">Blocks DMs too; "Ignore Limit for 15 minutes" is one tap away.</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Screen Time content restrictions</td><td style="padding:8px;border-bottom:1px solid var(--line)">Can't see inside apps. No effect on Reels.</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Instagram's "Not interested" / time reminders</td><td style="padding:8px;border-bottom:1px solid var(--line)">Tunes the feed; doesn't remove it. Reminders are dismissible.</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Blocking apps with schedules (Opal-style)</td><td style="padding:8px;border-bottom:1px solid var(--line)">Still all-or-nothing per app; messages go dark during blocks.</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Deleting Instagram</td><td style="padding:8px;border-bottom:1px solid var(--line)">Works, until you reinstall it to answer a DM.</td></tr>
</tbody></table>
<h2>The approach that works: make Reels fail to load</h2>
<p>Instagram streams video from dedicated media servers. If your phone limits traffic to just those servers, Reels can't buffer — but photos, messages and stories, which are tiny by comparison, still get through. That's a feature-level block that iOS can't do natively but a small on-device filter can.</p>
<p><a href="/">InstaBlock</a> is built around exactly this. Install it, allow the VPN configuration it asks for (it has no server — the "VPN" is just how iOS lets an app filter traffic locally), and Reels stop playing from then on. When you want to watch, tap a 1, 5, 15 or 30-minute break; the block returns by itself when the time is up, without opening the app.</p>
<h2>Why "no off switch" is the point</h2>
<p>Every Reels workaround dies the same way: a late-night tap on whatever undoes it. InstaBlock deliberately has no permanent off. You can take a timed break, and that's it — the only way to remove the block is to delete the app. Friction where it matters, none where it doesn't.</p>
""",
  faq=[("Is there a setting to turn off Reels in Instagram?", "No. Instagram has no option to disable Reels on iPhone or Android."),
       ("Can iOS Screen Time turn off Reels?", "No. Screen Time works at the app level and can't distinguish Reels from the rest of Instagram."),
       ("How does InstaBlock turn off Reels?", "It runs an on-device network filter that limits bandwidth to Instagram's video servers, so Reels fail to load while messages, stories and photos keep working.")]),
 dict(slug="block-tiktok-videos-on-iphone",
  title="How to block TikTok on iPhone without Screen Time",
  desc="A way to block TikTok videos on iOS that can't be bypassed with 'Ignore Limit' — and lets you allow it for a few minutes when you choose.",
  answer="The most reliable way to block TikTok on an iPhone without relying on Screen Time is to stop its video servers from loading with an on-device network filter. TikTok is almost entirely video, so blocking its content delivery servers effectively stops the feed, while a timed break can bring it back for a few minutes when you decide to.",
  body="""
<h2>Why Screen Time isn't enough for TikTok</h2>
<p>Screen Time can limit TikTok, but the limit ends with an "Ignore Limit" button, and the daily allowance resets every midnight. For an app engineered around the next swipe, a tappable limit is barely a speed bump. A Screen Time passcode held by someone else helps — if you have someone to hold it.</p>
<h2>Blocking the servers instead of the app</h2>
<p>TikTok downloads every clip from its content delivery servers. <a href="/">InstaBlock</a> learns those servers' addresses as your phone looks them up and drops traffic to them. The TikTok app still opens, but the feed can't fetch videos, so there is nothing to scroll. Because TikTok also serves parts of its API from the same servers, the app may show a loading error rather than a silent feed — the outcome is the same.</p>
<ol>
<li>Install InstaBlock and tap <strong>Allow</strong> on the VPN configuration prompt (local filter, no server).</li>
<li>Force-quit TikTok and reopen it. Fresh videos won't load.</li>
<li>Want ten minutes of TikTok on purpose? Tap <strong>5</strong> or <strong>15 minutes</strong> in InstaBlock. When the timer ends, the block returns automatically.</li>
</ol>
<h2>One honest caveat</h2>
<p>TikTok pre-downloads upcoming clips while you watch. Right after a break, a few already-cached videos may still play before the block catches up. Nothing new can be fetched, so the feed runs dry within a handful of swipes — but it's not instant.</p>
<h2>Instagram Reels too</h2>
<p>The same app handles Instagram: Reels stop loading while DMs, stories and photos keep working. See <a href="/guides/block-instagram-reels-without-deleting-instagram">how to block Reels without deleting Instagram</a>.</p>
""",
  faq=[("Can I block TikTok on iPhone without Screen Time?", "Yes. An on-device network filter such as InstaBlock blocks TikTok's video servers, so the feed can't load, and it can't be bypassed with 'Ignore Limit'."),
       ("Will TikTok still open?", "The app opens, but videos don't load. Because TikTok serves its API from the same servers as its videos, the feed may show a loading error instead."),
       ("Can I allow TikTok temporarily?", "Yes. Tap 1, 5, 15 or 30 minutes in InstaBlock; TikTok works for that long and the block returns automatically.")]),
 dict(slug="instablock-vs-screen-time-vs-app-blockers",
  title="InstaBlock vs Screen Time vs app blockers (Opal, one sec, ClearSpace)",
  desc="How InstaBlock differs from Screen Time and app blockers like Opal, one sec and ClearSpace: it blocks Reels and TikTok video, not the whole app.",
  answer="The difference is what gets blocked. Screen Time and app blockers such as Opal, one sec and ClearSpace work on the whole app — Instagram is either available or it isn't. InstaBlock works on the traffic: it stops Instagram Reels and TikTok videos from loading while messages, stories and photos keep working, and it has no off switch to bypass.",
  body="""
<h2>Side by side</h2>
<table style="border-collapse:collapse;width:100%;font-size:15px"><thead><tr>
<th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)"></th><th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)">InstaBlock</th><th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)">Screen Time</th><th style="text-align:left;padding:8px;border-bottom:1px solid var(--line)">App blockers*</th></tr></thead><tbody>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Blocks Reels but keeps DMs</td><td style="padding:8px;border-bottom:1px solid var(--line)">Yes</td><td style="padding:8px;border-bottom:1px solid var(--line)">No — whole app</td><td style="padding:8px;border-bottom:1px solid var(--line)">No — whole app</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Can be bypassed in the moment</td><td style="padding:8px;border-bottom:1px solid var(--line)">Only via a timed break; no off switch</td><td style="padding:8px;border-bottom:1px solid var(--line)">"Ignore Limit", one tap</td><td style="padding:8px;border-bottom:1px solid var(--line)">Varies; many offer "difficult" modes</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Works inside TikTok</td><td style="padding:8px;border-bottom:1px solid var(--line)">Yes (blocks videos)</td><td style="padding:8px;border-bottom:1px solid var(--line)">App-level only</td><td style="padding:8px;border-bottom:1px solid var(--line)">App-level only</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Account / subscription</td><td style="padding:8px;border-bottom:1px solid var(--line)">None; free</td><td style="padding:8px;border-bottom:1px solid var(--line)">None; built in</td><td style="padding:8px;border-bottom:1px solid var(--line)">Typically a subscription</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Data collection</td><td style="padding:8px;border-bottom:1px solid var(--line)">None; no server</td><td style="padding:8px;border-bottom:1px solid var(--line)">On-device</td><td style="padding:8px;border-bottom:1px solid var(--line)">Varies by app</td></tr>
<tr><td style="padding:8px;border-bottom:1px solid var(--line)">Mechanism</td><td style="padding:8px;border-bottom:1px solid var(--line)">Local network filter on video servers</td><td style="padding:8px;border-bottom:1px solid var(--line)">OS app limits</td><td style="padding:8px;border-bottom:1px solid var(--line)">Screen Time API shields, pauses, schedules</td></tr>
</tbody></table>
<p style="color:var(--muted);font-size:14px">*Opal, one sec, ClearSpace and similar apps as generally described on their own sites as of September 2026; check them for current features and pricing.</p>
<h2>When an app blocker is the better tool</h2>
<p>If your goal is "no Instagram at all during work hours" or "a breathing pause before every social app", Screen Time or an app blocker does that well, and one sec's pause-before-opening approach is genuinely effective for impulse opens. They also cover apps InstaBlock doesn't touch.</p>
<h2>When InstaBlock is</h2>
<p>If the problem is specifically Reels and TikTok — the infinite video feed — while you still need Instagram for messages, group chats, stories or your own posts, an app-level block forces a bad trade. InstaBlock removes the feed and keeps the rest. It's also the only option here with no bypass beyond a timed break.</p>
<h2>Using both</h2>
<p>They don't conflict. Some people keep a Screen Time schedule for overnight and run InstaBlock all day so Instagram stays usable but un-scrollable.</p>
""",
  faq=[("What's the difference between InstaBlock and Screen Time?", "Screen Time blocks or limits whole apps. InstaBlock blocks only Instagram Reels and TikTok video traffic, so DMs, stories and photos keep working, and it has no 'Ignore Limit' bypass."),
       ("Is InstaBlock like Opal or one sec?", "No. Those are app blockers that shield or pause whole apps using the Screen Time framework. InstaBlock is a local network filter that targets video servers inside Instagram and TikTok."),
       ("Can I use InstaBlock together with Screen Time?", "Yes. They work at different levels and don't conflict.")]),
]

def guide_page(g):
    path = f"/guides/{g['slug']}"
    faq_html = "".join(f'<details><summary>{q}</summary><p>{a}</p></details>' for q, a in g["faq"])
    article = {"@context": "https://schema.org", "@type": "Article", "headline": g["title"], "description": g["desc"],
               "url": SITE + path, "datePublished": TODAY, "dateModified": TODAY,
               "author": {"@type": "Person", "name": "Leonid Pechersky"}, "publisher": ORG,
               "about": {"@type": "SoftwareApplication", "name": "InstaBlock", "url": SITE + "/"},
               "image": SITE + "/assets/01-reels-blocked.png"}
    crumbs = {"@context": "https://schema.org", "@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "Guides", "item": SITE + "/guides"},
        {"@type": "ListItem", "position": 2, "name": g["title"], "item": SITE + path}]}
    html = f"""<!doctype html><html lang="en"><head>{HEAD}{social(path, g['title'], g['desc'], kind='article')}
{ld(article)}{ld(faq_ld(g['faq']))}{ld(crumbs)}</head><body>{NAV}
<main class="wrap prose">
<p class="meta"><a href="/guides">Guides</a> · Updated September 2026</p>
<h1>{g['title']}</h1>
<p><strong>{g['answer']}</strong></p>
{g['body']}
<h2>Questions</h2><div class="faq">{faq_html}</div>
<p style="margin-top:36px"><a class="btn" href="/#download">Get InstaBlock — free on the App Store and Google Play</a></p>
</main>{FOOT}</body></html>"""
    (PUB / "guides").mkdir(exist_ok=True)
    (PUB / "guides" / f"{g['slug']}.html").write_text(html)
    return path

paths = [guide_page(g) for g in GUIDES]

# guides index
items = "".join(f'<div class="card"><h3><a href="/guides/{g["slug"]}">{g["title"]}</a></h3><p>{g["desc"]}</p></div>' for g in GUIDES)
(PUB / "guides.html").write_text(f"""<!doctype html><html lang="en"><head>{HEAD}{social('/guides', 'Guides — blocking Reels and TikTok on iPhone', 'Practical, honest guides to blocking Instagram Reels and TikTok videos on iPhone while keeping the rest of the apps working.')}
{ld({"@context":"https://schema.org","@type":"CollectionPage","name":"InstaBlock guides","url":SITE+"/guides","hasPart":[{"@type":"Article","headline":g["title"],"url":SITE+"/guides/"+g["slug"]} for g in GUIDES]})}</head><body>{NAV}
<main class="wrap"><section><h2>Guides</h2><p class="sub">Straight answers to the questions people actually ask about Reels, TikTok and iPhone.</p>
<div class="grid" style="grid-template-columns:1fr 1fr">{items}</div></section></main>{FOOT}</body></html>""")

# ---------------------------------------------------------------- patch hand-written pages
def patch(name, path, title, desc, extra_ld=None, kind="website"):
    p = PUB / name
    s = p.read_text()
    s = re.sub(r'<title>.*?</title>', '', s, count=1, flags=re.S)
    s = re.sub(r'<meta name="description"[^>]*>', '', s)
    s = re.sub(r'<meta property="og:[^"]*"[^>]*>', '', s)
    s = re.sub(r'<link rel="canonical"[^>]*>', '', s)
    s = re.sub(r'<meta name="twitter:[^"]*"[^>]*>', '', s)
    # Re-runs must not stack structured data: drop previously injected blocks.
    s = re.sub(r'<script type="application/ld\+json">.*?</script>', '', s, flags=re.S)
    tags = social(path, title, desc, kind=kind) + "".join(ld(o) for o in (extra_ld or []))
    s = s.replace('<link rel="stylesheet" href="/styles.css">', '<link rel="stylesheet" href="/styles.css">' + tags, 1)
    # nav + footer refresh (adds Guides)
    s = re.sub(r'<header>.*?</header>', NAV, s, count=1, flags=re.S)
    s = re.sub(r'<footer>.*?</footer>', FOOT, s, count=1, flags=re.S)
    p.write_text(s)

patch("index.html", "/", "InstaBlock — Kill Reels. Keep the DMs.",
      "InstaBlock stops Instagram Reels and TikTok videos from loading while DMs, stories and photos keep working. Tap for a 5-minute scroll when you want one — it blocks itself again.",
      [APP, faq_ld(HOME_FAQ), {"@context": "https://schema.org", **ORG}])
patch("support.html", "/support", "Support — InstaBlock", "Get help with InstaBlock: quick fixes for videos still playing, VPN permission, and how to contact us.")
patch("privacy.html", "/privacy", "Privacy Policy — InstaBlock", "InstaBlock collects no data. How the on-device filter works, what the support form stores, and how to reach us.")
patch("terms.html", "/terms", "Terms of Service — InstaBlock", "Terms for using the InstaBlock app and website.")
patch("404.html", "/404", "Not found — InstaBlock", "That page scrolled away.")

# ---------------------------------------------------------------- sitemap / robots / llms.txt
urls = ["/", "/guides"] + paths + ["/support", "/privacy", "/terms"]
sm = '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "".join(
    f"  <url><loc>{SITE}{u}</loc><lastmod>{TODAY}</lastmod><changefreq>{'weekly' if u in ('/', '/guides') else 'monthly'}</changefreq><priority>{'1.0' if u == '/' else '0.8' if u.startswith('/guides') else '0.4'}</priority></url>\n" for u in urls) + "</urlset>\n"
(PUB / "sitemap.xml").write_text(sm)

(PUB / "robots.txt").write_text("""# InstaBlock — AI crawlers are welcome.
User-agent: *
Allow: /

User-agent: GPTBot
Allow: /
User-agent: OAI-SearchBot
Allow: /
User-agent: ChatGPT-User
Allow: /
User-agent: ClaudeBot
Allow: /
User-agent: anthropic-ai
Allow: /
User-agent: Claude-User
Allow: /
User-agent: PerplexityBot
Allow: /
User-agent: Google-Extended
Allow: /
User-agent: Bingbot
Allow: /
User-agent: CCBot
Allow: /
User-agent: Applebot
Allow: /
User-agent: Applebot-Extended
Allow: /

Sitemap: https://instablock.app/sitemap.xml
""")

(PUB / "llms.txt").write_text(f"""# InstaBlock

> {ONE_LINER}

InstaBlock is a free app for iPhone/iPad (iOS 17+) and Android (7+) for people who
want to stop doomscrolling Instagram Reels and TikTok without deleting the apps or
losing Instagram messages. It is not affiliated with Instagram, Meta, TikTok or ByteDance.

## What it does
- Blocks Instagram Reels and TikTok videos from loading. Instagram DMs, stories,
  comments and photos keep working; TikTok's feed effectively stops (it is all video).
- Blocking is always on; there is deliberately no off switch.
- Timed breaks: hold a card for 5 seconds to allow videos for 1, 5, 15 or 30 minutes, then the block returns; a short cooldown (5–30 s) follows each break
  automatically — the user does not need to open the app again.
- No account, no sign-up, no analytics, no server. The filter runs entirely on-device.

## How it works (technical)
The app installs a local iOS packet-tunnel (shown by iOS as a VPN, but with no
remote server). It intercepts DNS lookups only for Instagram's and TikTok's media
CDN domains (fbcdn.net, cdninstagram.com, tiktokcdn.com and related), learns the
resolved addresses, and rate-limits traffic to them (Instagram) or drops it
(TikTok). Photos are small and survive the limit; video cannot stream. All other
traffic never enters the filter.

## Other VPNs
Phones allow one active VPN and the filter counts as one. When another VPN turns
on, InstaBlock steps aside and notifies the user ("InstaBlock is off"); when it
disconnects, InstaBlock comes back — on iPhone via a one-tap notification action or
opening the app, on Android automatically where consent survives, otherwise via a
one-tap notification (Android re-asks VPN permission). It never evicts another VPN
on its own. On Android the filter is scoped to the Instagram and TikTok apps only.

## Known limitations
- Videos already cached by Instagram/TikTok (for example during a break) may play once.
- A VPN badge shows in the status bar while blocking is on.
- Photos may load slightly slower.
- Wi-Fi/cellular switches are handled automatically.

## Pages
- Home: {SITE}/
- Guides: {SITE}/guides
{chr(10).join(f'- {g["title"]}: {SITE}/guides/{g["slug"]}' for g in GUIDES)}
- Support: {SITE}/support (contact: support@instablock.app)
- Privacy policy: {SITE}/privacy (no data collected)
- Terms: {SITE}/terms
- Google Play: https://play.google.com/store/apps/details?id=com.helpon.instablock
- App Store: iOS version submitted, awaiting App Review (link will be added when live)
""")
print("generated:", *urls, sep="\n  ")

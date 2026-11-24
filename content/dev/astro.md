---
title: Astro and the frontend landscape
description: Islands architecture, where Astro fits among the frameworks, and how to think about frontend choices from an infrastructure perspective
tags: [dev, frontend, astro, web, javascript]
type: concept
status: complete
---

# Astro and the frontend landscape

Notes from an infrastructure perspective — what these tools produce, what they need to
run, and which choice makes them somebody's operational problem.

## The question that actually matters

For anyone deploying frontends, the useful classification is **what artifact comes out
of the build**:

| Output | Runtime | Deploy to |
| --- | --- | --- |
| **Static files** | None | Any web server, S3, a CDN |
| **A Node.js server** | Node process | A container, with all that implies |
| **Edge functions** | Vendor runtime | That vendor |

That decision determines whether the frontend is a directory you copy or a service you
operate — patching, scaling, monitoring and paging for. It is worth having an opinion
about it before the framework is chosen rather than after.

## Astro

[Astro](https://astro.build) is a framework whose default output is **static HTML with
no JavaScript at all**.

Its distinguishing idea is **islands architecture**: the page is static by default, and
you explicitly opt individual components into interactivity.

```astro
---
// This runs at build time only. It never reaches the browser.
import SearchBox from '../components/SearchBox.jsx';
const posts = await fetch('https://api.example.com/posts').then(r => r.json());
---

<html>
  <body>
    <h1>Posts</h1>
    {posts.map(post => <article><h2>{post.title}</h2></article>)}

    <!-- An island: only this component ships JavaScript -->
    <SearchBox client:load />
  </body>
</html>
```

The `client:` directives control when a component hydrates:

| Directive | Loads |
| --- | --- |
| `client:load` | Immediately |
| `client:idle` | When the browser is idle |
| `client:visible` | When it scrolls into view |
| `client:media="(max-width: 50em)"` | On a media query match |
| `client:only="react"` | Client-side only, never rendered at build; name the framework |

> [!important] The default is what makes it different
> Most frameworks ship a JavaScript runtime and let you optimise downward. Astro ships
> nothing and makes you opt in per component.
>
> For a documentation site, a marketing site or a blog — where the vast majority of the
> page is genuinely static — the result is a directory of HTML that any web server can
> serve, with no runtime to operate. That is a meaningful operational difference, not
> just a performance one.

It is also framework-agnostic: React, Vue, Svelte and Solid components all work, and
can coexist in one project. Each framework needs its integration, such as
`npx astro add react`. That matters when a team has existing components and does
not want to rewrite them.

## The landscape

| Framework | Default output | Best at |
| --- | --- | --- |
| **Astro** | Static HTML, opt-in JS | Content sites, docs, marketing |
| **Next.js** | Node server, or static | React applications; the default choice for React |
| **Nuxt** | Node server, or static | The Vue equivalent |
| **SvelteKit** | Adaptable per platform | Svelte applications; small bundles |
| **React Router** (formerly Remix) | Node server, or static | Applications leaning on web standards |
| **Vite + a library** | Static SPA | Applications where you want control and no framework opinions |
| **Docusaurus** / **VitePress** | Static | Documentation specifically |

> [!tip] Static output is a deployment decision, not a limitation
> Several of these can produce static output — Next.js with `output: export`, Nuxt
> with `nuxi generate`, SvelteKit with the static adapter. The question is what the
> team will end up needing, because a framework whose *default* is a server tends to
> acquire server-only features.
>
> If the site can be static, keeping it static removes an entire class of operational
> work: no Node runtime to patch, no process to monitor, no cold starts, and caching
> that a CDN handles for free.

## Deploying static output

```bash
npm run build          # → dist/
```

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name docs.example.com;
    ssl_certificate     /etc/nginx/tls/docs.example.com.crt;
    ssl_certificate_key /etc/nginx/tls/docs.example.com.key;

    root /var/www/docs;
    index index.html;
    error_page 404 /404.html;

    location / {
        try_files $uri $uri/ =404;
    }

    # Hashed assets — cache hard
    location /_astro/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
```

`=404` with `error_page` serves the 404 page with a 404 status. `try_files $uri $uri/
/404.html` would serve it with `200 OK`, so crawlers and monitoring see missing pages
as present. See [[servers/nginx]] and [[security/cryptography/tls-protocol]].

Containerised, this is a `scratch`-adjacent image — static files and a tiny server,
with essentially no attack surface:

```dockerfile
FROM node:24-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY --from=build /app/dist /usr/share/nginx/html
```

The `nginx-unprivileged` image runs as non-root by default, and so listens on port
8080, not 80 — see
[[security/secure-container-images]].

## What to be wary of, operationally

**Server-side rendering is a Node.js service.** It needs patching, memory limits,
health checks and log aggregation like anything else. Choosing SSR because it improves
a metric, without the team that will operate it, is a common way to acquire an
unowned production service.

**Build-time data fetching bakes data in.** Astro's default fetches at build time, so
content changes need a rebuild. For a documentation site that is fine and desirable;
for anything with frequently changing data it is a rebuild pipeline you must
operate.

**The dependency tree is large.** A frontend build pulls in hundreds of packages, and
that is a supply chain — see [[security/supply-chain/sbom]]. Generate an SBOM for the
frontend as you would for anything else, and run `npm audit` or Grype in CI.

> [!warning] `npm ci`, never `npm install`, in a build
> `npm install` can update the lockfile and resolve different versions than were
> tested. `npm ci` installs exactly what the lockfile says and fails if it disagrees
> with `package.json` — which is what a reproducible build requires.

## Where to go next

- [[servers/nginx]] — serving the output
- [[security/secure-container-images]] — building the image
- [[security/supply-chain/sbom]] — the dependency tree you just acquired

<!-- uplink -->
Part of [[dev/index|Development]].

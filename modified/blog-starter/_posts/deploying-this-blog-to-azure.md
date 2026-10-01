---
title: "How This Blog Gets to Azure"
excerpt: "Every page you see here started as a Markdown file. Here is what happens between saving that file and it showing up on Azure Static Web Apps, and why there is no server involved."
coverImage: "/assets/blog/deploying-this-blog-to-azure/cover.jpg"
date: "2026-10-01T12:00:00.000Z"
author:
  name: Glen Souza
  picture: "/assets/blog/authors/glen.jpeg"
ogImage:
  url: "/assets/blog/deploying-this-blog-to-azure/cover.jpg"
---

This post is a small test with a purpose: if you can read it, the whole publishing path worked. It was added the same way any author would add one, by dropping a single Markdown file into the `_posts` folder. Nothing else in the code changed.

## From Markdown to HTML

The blog is built with Next.js, but it never runs a Node.js server in production. At build time, Next.js reads every file in `_posts`, converts the Markdown to HTML, and writes each page out as a plain HTML file. One setting makes that happen:

```ts
const nextConfig: NextConfig = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
};
```

The result is a folder of HTML, CSS, JavaScript and images. There is no runtime to patch, no server to scale, and nothing for an attacker to log in to.

## From the repository to Azure

When this file was committed, a GitHub Actions workflow picked it up:

1. Install the exact dependency versions from the lock file and fail on any high-severity vulnerability.
2. Type check and build the static site.
3. On the pull request, publish a **preview environment** with its own URL, so the post could be reviewed exactly as readers would see it.
4. After the merge, deploy the same build to dev, then to production once a reviewer approved it.

The pipeline signs in to Azure with OpenID Connect. GitHub gets a short-lived token that only this repository can use, so there is no password or deployment key stored anywhere.

## Hosting and monitoring

Azure Static Web Apps serves the site from a global edge network with a managed TLS certificate and strict security headers. Application Insights requests the home page every five minutes from five regions, and an alert goes out if two or more of them fail.

Rolling back means redeploying the previous build, which takes under a minute. The cost is a flat fee of about nine dollars a month per environment.

## Adding the next post

Write a Markdown file with the same front matter as this one, put any images under `public/assets/blog/`, and open a pull request. The preview link shows up on the pull request a few minutes later.

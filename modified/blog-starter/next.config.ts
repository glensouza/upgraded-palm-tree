import type { NextConfig } from "next";

// The blog is 100% statically generated from the Markdown files in /_posts,
// so we export plain HTML/CSS/JS and host it on Azure Static Web Apps.
// No Node.js server is needed at runtime.
const nextConfig: NextConfig = {
  output: "export",
  // Static Web Apps serves /posts/hello-world/index.html for /posts/hello-world/
  trailingSlash: true,
  images: {
    // The built-in image optimizer needs a server. Images are pre-sized
    // assets served from the CDN instead.
    unoptimized: true,
  },
  poweredByHeader: false,
};

export default nextConfig;

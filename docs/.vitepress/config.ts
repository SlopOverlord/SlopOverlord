import { defineConfig } from "vitepress";

export default defineConfig({
  title: "Sloppy Docs",
  description: "Runtime specifications, ADRs, and implementation notes for Sloppy.",
  base: "/",
  lang: "en-US",
  markdown: {
    theme: {
      light: "vesper",
      dark: "vesper"
    }
  },
  cleanUrls: true,
  lastUpdated: true,
  appearance: false,
  ignoreDeadLinks: false,
  head: [
    ["link", { rel: "preconnect", href: "https://fonts.googleapis.com" }],
    ["link", { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" }],
    ["link", { rel: "icon", type: "image/svg+xml", href: "/so_logo.svg" }],
    ["link", { rel: "stylesheet", href: "https://fonts.googleapis.com/css2?family=Fira+Code:wght@300..700&display=swap" }]
  ],
  themeConfig: {
    logo: "/so_logo.svg",
    nav: [
      { text: "Guides", link: "/guides/build-from-terminal" },
      { text: "API", link: "/api/reference" },
      { text: "Design", link: "/architecture/project-design" },
      { text: "Specs", link: "/specs/protocol-v1" },
      { text: "ADR", link: "/adr/0001-runtime-architecture" },
      { text: "Dashboard UI", link: "/dashboard-style" }
    ],
    sidebar: [
      {
        text: "Overview",
        items: [
          { text: "Home", link: "/" },
          { text: "Dashboard Style", link: "/dashboard-style" },
          { text: "API Reference", link: "/api/reference" }
        ]
      },
      {
        text: "Guides",
        items: [
          { text: "Build From Terminal", link: "/guides/build-from-terminal" },
          { text: "Build With Docker", link: "/guides/build-with-docker" },
          { text: "Development Workflow", link: "/guides/development-workflow" }
        ]
      },
      {
        text: "Architecture",
        items: [
          { text: "Project Design", link: "/architecture/project-design" },
          { text: "ADR-0001 Runtime Architecture", link: "/adr/0001-runtime-architecture" }
        ]
      },
      {
        text: "Specifications",
        items: [
          { text: "Protocol v1", link: "/specs/protocol-v1" },
          { text: "Channel Plugin Protocol v1", link: "/specs/channel-plugin-protocol" },
          { text: "PRD Runtime v1", link: "/specs/prd-runtime-v1" }
        ]
      }
    ],
    socialLinks: [
      { icon: "github", link: "https://github.com/TeamSloppy/Sloppy" }
    ],
    outline: {
      level: [2, 3],
      label: "On this page"
    },
    search: {
      provider: "local"
    },
    footer: {
      message: "Built from docs/ and styled to match the live Dashboard shell.",
      copyright: "Sloppy"
    }
  }
});

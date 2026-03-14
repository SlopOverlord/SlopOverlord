---
layout: home

hero:
  name: "Sloppy Docs"
  text: "Runtime docs in the live Dashboard shell"
  tagline: "VitePress portal rebuilt around the current Dashboard language: mono typography, acid-lime signals, square surfaces, and a dedicated OpenAPI reference."
  actions:
    - theme: brand
      text: Open Specs
      link: /specs/protocol-v1
    - theme: alt
      text: Open API
      link: /api/reference

features:
  - title: Build Guides
    details: Step-by-step docs explain how to run Sloppy from the terminal, how to use Docker Compose, and what checks to run before opening a PR.
  - title: API Reference
    details: OpenAPI endpoints now have a dedicated docs page with grouped operations, parameters, responses, and a direct link to the raw swagger spec.
  - title: Project Design
    details: A detailed architecture document explains module boundaries, runtime flows, persistence, integrations, and current implementation tradeoffs.
  - title: Runtime Specs
    details: Protocol, runtime model, plugin contracts, and PRD documents stay published directly from the repository Markdown files.
  - title: Dashboard Palette
    details: Docs inherit the current Dashboard background, surface hierarchy, Fira Code typography, hard edges, and high-contrast accent treatments.
  - title: Repository-First
    details: The site stays generated directly from docs/, so design and API documentation ship together with the codebase.
---

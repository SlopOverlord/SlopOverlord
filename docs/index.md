---
layout: home

hero:
  name: "SlopOverlord Docs"
  text: "Runtime specs and ADRs in the Dashboard visual language"
  tagline: "VitePress site built from docs/, with the same dark palette, surfaces, and accent system used in the Dashboard."
  image:
    src: /so_logo.svg
    alt: SlopOverlord logo
  actions:
    - theme: brand
      text: Open Specs
      link: /specs/protocol-v1
    - theme: alt
      text: Review Architecture
      link: /adr/0001-runtime-architecture

features:
  - title: Runtime Specs
    details: Protocol, runtime model, plugin contracts, PRD, and gap analysis stay published directly from the repository Markdown files.
  - title: Dashboard Palette
    details: Docs inherit the Dashboard background, surface hierarchy, border tones, text colors, and accent treatments.
  - title: CI Publish Flow
    details: GitLab builds the VitePress site and pushes the generated static output to the GitHub Pages branch.
---

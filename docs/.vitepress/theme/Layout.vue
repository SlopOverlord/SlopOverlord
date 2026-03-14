<script setup lang="ts">
import DefaultTheme from "vitepress/theme";
import { useData } from "vitepress";
import OrchestratorAsciiArt from "./components/OrchestratorAsciiArt.vue";

const { Layout } = DefaultTheme;
const { frontmatter } = useData();
</script>

<template>
  <Layout>
    <template #home-hero-image>
      <OrchestratorAsciiArt v-if="frontmatter.layout === 'home'" />
    </template>
  </Layout>
</template>

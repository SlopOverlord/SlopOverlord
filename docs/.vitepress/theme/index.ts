import DefaultTheme from "vitepress/theme";
import type { Theme } from "vitepress";
import ApiReference from "./components/ApiReference.vue";
import Layout from "./Layout.vue";
import "./style.css";

const theme: Theme = {
  ...DefaultTheme,
  Layout,
  enhanceApp({ app }) {
    app.component("ApiReference", ApiReference);
  }
};

export default theme;

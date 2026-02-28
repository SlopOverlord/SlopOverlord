import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "./styles.css";

const configuredAccentColor = window.__SLOPOVERLORD_CONFIG__?.accentColor;
if (
  typeof configuredAccentColor === "string" &&
  configuredAccentColor.trim().length > 0 &&
  typeof window.CSS !== "undefined" &&
  window.CSS.supports("color", configuredAccentColor.trim())
) {
  document.documentElement.style.setProperty("--accent-color", configuredAccentColor.trim());
}

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element #root was not found");
}

createRoot(rootElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

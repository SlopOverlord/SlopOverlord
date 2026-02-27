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

createRoot(document.getElementById("root")).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);

import React from "react";

export const PROJECT_IMAGE_ICON_MAX_BYTES = 512 * 1024;

const PROJECT_IMAGE_ICON_PATTERN = /^data:image\/(?:png|jpeg|webp|gif);base64,/i;

export function isProjectImageIcon(icon) {
  return PROJECT_IMAGE_ICON_PATTERN.test(String(icon || "").trim());
}

function joinClasses(...classes) {
  return classes.filter(Boolean).join(" ");
}

export function ProjectIcon({
  icon,
  fallback = null,
  className = "",
  imageClassName = "",
  symbolClassName = "",
  fallbackClassName = ""
}) {
  const value = String(icon || "").trim();

  if (isProjectImageIcon(value)) {
    return (
      <img
        src={value}
        alt=""
        aria-hidden="true"
        draggable="false"
        className={joinClasses(className, imageClassName)}
      />
    );
  }

  if (value) {
    return (
      <span className={joinClasses("material-symbols-rounded", className, symbolClassName)} aria-hidden="true">
        {value}
      </span>
    );
  }

  if (fallback != null) {
    return (
      <span className={joinClasses(className, fallbackClassName)} aria-hidden="true">
        {fallback}
      </span>
    );
  }

  return null;
}

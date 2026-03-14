<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { withBase } from "vitepress";

type RenderState = "idle" | "ready" | "error";

const asciiRamps = [
  "  .,:-+=xX$&",
  "   `.^\";!iIYVHW",
  "  .-~+*#%@"
];

const defaultColumns = 200;
const frameDelayMs = 200;

const rootElement = ref<HTMLElement | null>(null);
const columns = ref(defaultColumns);
const frames = ref<string[]>([]);
const frameIndex = ref(0);
const renderError = ref<string | null>(null);
const renderState = ref<RenderState>("idle");

let resizeObserver: ResizeObserver | null = null;
let intervalId: number | null = null;
let renderToken = 0;

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function getAsciiColumns(containerWidth: number): number {
  if (containerWidth < 280) return 34;
  if (containerWidth < 360) return 40;
  if (containerWidth < 440) return 48;
  if (containerWidth < 520) return 56;
  return clamp(Math.floor(containerWidth / 8.1), 58, 72);
}

function buildAsciiFrames(grid: number[][]): string[] {
  return Array.from({ length: 6 }, (_, frame) => {
    const ramp = asciiRamps[frame % asciiRamps.length];
    const phase = frame * 0.9;

    return grid
      .map((row, rowIndex) =>
        row
          .map((brightness, columnIndex) => {
            const pulse = brightness > 18
              ? Math.sin(columnIndex * 0.28 + rowIndex * 0.18 + phase) * 18
              : 0;
            const adjusted = clamp(brightness + pulse, 0, 255);
            const rampIndex = Math.round((adjusted / 255) * (ramp.length - 1));
            return ramp[rampIndex];
          })
          .join("")
      )
      .join("\n");
  });
}

async function renderAsciiFrameSet(): Promise<void> {
  const currentToken = ++renderToken;
  renderState.value = "idle";

  try {
    const source = new Image();

    await new Promise<void>((resolve, reject) => {
      source.onload = () => resolve();
      source.onerror = () => reject(new Error("failed to load orchestrator.png"));
      source.src = withBase("/orchestrator.png");
    });

    if (currentToken !== renderToken) {
      return;
    }

    const rows = Math.max(22, Math.round(columns.value * (source.height / source.width) * 0.52));
    const canvas = document.createElement("canvas");
    canvas.width = columns.value;
    canvas.height = rows;

    const context = canvas.getContext("2d", { willReadFrequently: true });
    if (!context) {
      throw new Error("Canvas 2D context is unavailable");
    }

    context.drawImage(source, 0, 0, columns.value, rows);
    const pixels = context.getImageData(0, 0, columns.value, rows).data;
    const grid: number[][] = [];

    for (let rowIndex = 0; rowIndex < rows; rowIndex += 1) {
      const row: number[] = [];

      for (let columnIndex = 0; columnIndex < columns.value; columnIndex += 1) {
        const offset = (rowIndex * columns.value + columnIndex) * 4;
        const red = pixels[offset];
        const green = pixels[offset + 1];
        const blue = pixels[offset + 2];
        const brightness = red * 0.299 + green * 0.587 + blue * 0.114;
        row.push(brightness);
      }

      grid.push(row);
    }

    frames.value = buildAsciiFrames(grid);
    frameIndex.value = 0;
    renderError.value = null;
    renderState.value = "ready";
  } catch (error) {
    if (currentToken !== renderToken) {
      return;
    }

    frames.value = [];
    renderError.value = error instanceof Error
      ? `[ ${error.message} ]`
      : "[ ascii render unavailable ]";
    renderState.value = "error";
  }
}

function syncColumns(containerWidth: number): void {
  const nextColumns = getAsciiColumns(containerWidth);
  if (nextColumns !== columns.value) {
    columns.value = nextColumns;
    void renderAsciiFrameSet();
  }
}

const renderOutput = computed(() => {
  if (renderError.value) {
    return renderError.value;
  }

  return frames.value[frameIndex.value] ?? "[ building ascii frame buffer ]";
});

const hasMotion = computed(() => {
  if (typeof window === "undefined") {
    return false;
  }

  return !window.matchMedia("(prefers-reduced-motion: reduce)").matches;
});

onMounted(() => {
  const initialWidth = rootElement.value?.getBoundingClientRect().width ?? window.innerWidth;
  columns.value = getAsciiColumns(initialWidth);
  void renderAsciiFrameSet();

  if (rootElement.value) {
    resizeObserver = new ResizeObserver((entries) => {
      const entry = entries[0];
      if (!entry) {
        return;
      }

      syncColumns(entry.contentRect.width);
    });

    resizeObserver.observe(rootElement.value);
  }

  if (hasMotion.value) {
    intervalId = window.setInterval(() => {
      if (frames.value.length > 1) {
        frameIndex.value = (frameIndex.value + 1) % frames.value.length;
      }
    }, frameDelayMs);
  }
});

onBeforeUnmount(() => {
  renderToken += 1;

  if (resizeObserver) {
    resizeObserver.disconnect();
  }

  if (intervalId !== null) {
    window.clearInterval(intervalId);
  }
});
</script>

<template>
  <div ref="rootElement" class="docs-orchestrator-shell" aria-hidden="true">
    <pre class="docs-orchestrator-ascii">{{ renderOutput }}</pre>
  </div>
</template>

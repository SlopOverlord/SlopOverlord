<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { withBase } from "vitepress";

type HttpMethod = "get" | "post" | "put" | "patch" | "delete";

interface OpenAPIParameter {
  name: string;
  in: string;
  required?: boolean;
  schema?: {
    type?: string;
  };
}

interface OpenAPIResponse {
  description?: string;
}

interface OpenAPIRequestBody {
  content?: Record<string, unknown>;
}

interface OpenAPIOperation {
  summary?: string;
  description?: string;
  tags?: string[];
  parameters?: OpenAPIParameter[];
  responses?: Record<string, OpenAPIResponse>;
  requestBody?: OpenAPIRequestBody;
}

interface OpenAPIPathItem {
  parameters?: OpenAPIParameter[];
  get?: OpenAPIOperation;
  post?: OpenAPIOperation;
  put?: OpenAPIOperation;
  patch?: OpenAPIOperation;
  delete?: OpenAPIOperation;
}

interface OpenAPISpec {
  openapi?: string;
  info?: {
    title?: string;
    version?: string;
    description?: string;
  };
  paths?: Record<string, OpenAPIPathItem>;
}

interface EndpointEntry {
  method: HttpMethod;
  path: string;
  operation: OpenAPIOperation;
  parameters: OpenAPIParameter[];
}

const loading = ref(true);
const errorMessage = ref("");
const spec = ref<OpenAPISpec | null>(null);

const methodOrder: HttpMethod[] = ["get", "post", "put", "patch", "delete"];

const endpoints = computed<EndpointEntry[]>(() => {
  if (!spec.value?.paths) {
    return [];
  }

  return Object.entries(spec.value.paths)
    .flatMap(([path, pathItem]) => {
      const pathParameters = pathItem.parameters ?? [];
      return methodOrder.flatMap((method) => {
        const operation = pathItem[method];
        if (!operation) {
          return [];
        }

        return [
          {
            method,
            path,
            operation,
            parameters: [...pathParameters, ...(operation.parameters ?? [])]
          }
        ];
      });
    })
    .sort((left, right) => {
      const methodDelta = methodOrder.indexOf(left.method) - methodOrder.indexOf(right.method);
      return methodDelta !== 0 ? methodDelta : left.path.localeCompare(right.path);
    });
});

const groupedEndpoints = computed(() => {
  const groups = new Map<string, EndpointEntry[]>();

  for (const endpoint of endpoints.value) {
    const tag = endpoint.operation.tags?.[0] ?? "General";
    const collection = groups.get(tag) ?? [];
    collection.push(endpoint);
    groups.set(tag, collection);
  }

  return Array.from(groups.entries())
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([tag, items]) => ({
      tag,
      items
    }));
});

const totalOperations = computed(() => endpoints.value.length);

function getContentTypes(operation: OpenAPIOperation): string[] {
  return Object.keys(operation.requestBody?.content ?? {});
}

function methodClass(method: HttpMethod): string {
  return `api-reference-method api-reference-method-${method}`;
}

onMounted(async () => {
  try {
    const response = await fetch(withBase("/swagger.json"));
    if (!response.ok) {
      throw new Error(`Failed to load OpenAPI spec (${response.status})`);
    }

    spec.value = (await response.json()) as OpenAPISpec;
  } catch (error) {
    errorMessage.value = error instanceof Error ? error.message : "Unable to load OpenAPI spec.";
  } finally {
    loading.value = false;
  }
});
</script>

<template>
  <section class="api-reference">
    <div class="api-reference-hero" v-if="spec">
      <span class="api-reference-kicker">OpenAPI Reference</span>
      <h2>{{ spec.info?.title || "Sloppy API" }}</h2>
      <p>
        {{ spec.info?.description || "Generated endpoint catalog for the Sloppy runtime. Operations are grouped by primary tag and rendered directly from the swagger spec in docs/public." }}
      </p>
      <div class="api-reference-meta">
        <span class="api-reference-chip"><strong>Version</strong>&nbsp;{{ spec.info?.version || "n/a" }}</span>
        <span class="api-reference-chip"><strong>OpenAPI</strong>&nbsp;{{ spec.openapi || "n/a" }}</span>
        <span class="api-reference-chip"><strong>Operations</strong>&nbsp;{{ totalOperations }}</span>
      </div>
      <div class="api-reference-actions">
        <a class="api-reference-action" :href="withBase('/swagger.json')" target="_blank" rel="noreferrer">Open Raw JSON</a>
      </div>
    </div>

    <div v-if="loading" class="api-reference-state">
      <span class="api-reference-kicker">Loading</span>
      <p>Fetching the OpenAPI spec from the docs bundle.</p>
    </div>

    <div v-else-if="errorMessage" class="api-reference-state">
      <span class="api-reference-kicker">Load Error</span>
      <p>{{ errorMessage }}</p>
    </div>

    <div v-else class="api-reference-tags">
      <section v-for="group in groupedEndpoints" :key="group.tag" class="api-reference-tag">
        <div class="api-reference-tag-head">
          <h3>{{ group.tag }}</h3>
          <div class="api-reference-counters">
            <span>{{ group.items.length }} operations</span>
          </div>
        </div>

        <div class="api-reference-operations">
          <article v-for="endpoint in group.items" :key="`${endpoint.method}:${endpoint.path}`" class="api-reference-operation">
            <span :class="methodClass(endpoint.method)">{{ endpoint.method }}</span>
            <div class="api-reference-operation-main">
              <h4>{{ endpoint.operation.summary || endpoint.path }}</h4>
              <p class="api-reference-path"><code>{{ endpoint.path }}</code></p>
              <p v-if="endpoint.operation.description" class="api-reference-description">
                {{ endpoint.operation.description }}
              </p>

              <div v-if="endpoint.parameters.length" class="api-reference-section">
                <strong>Parameters</strong>
                <div class="api-reference-parameter-list">
                  <div v-for="parameter in endpoint.parameters" :key="`${endpoint.path}:${parameter.name}:${parameter.in}`" class="api-reference-parameter">
                    <code>{{ parameter.name }}</code>
                    <span>{{ parameter.in }}</span>
                    <span v-if="parameter.schema?.type"> · {{ parameter.schema.type }}</span>
                    <span v-if="parameter.required"> · required</span>
                  </div>
                </div>
              </div>

              <div v-if="getContentTypes(endpoint.operation).length" class="api-reference-section">
                <strong>Request Body</strong>
                <div class="api-reference-content-list">
                  <div v-for="contentType in getContentTypes(endpoint.operation)" :key="contentType" class="api-reference-content">
                    <code>{{ contentType }}</code>
                  </div>
                </div>
              </div>

              <div v-if="endpoint.operation.responses" class="api-reference-section">
                <strong>Responses</strong>
                <div class="api-reference-response-list">
                  <div v-for="(response, status) in endpoint.operation.responses" :key="status" class="api-reference-response">
                    <code>{{ status }}</code>
                    <span>{{ response.description || "Response" }}</span>
                  </div>
                </div>
              </div>
            </div>
          </article>
        </div>
      </section>
    </div>
  </section>
</template>

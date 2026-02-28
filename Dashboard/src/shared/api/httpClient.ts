type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

interface JsonRequestOptions<TBody = unknown> {
  path: string;
  method?: HttpMethod;
  body?: TBody;
  signal?: AbortSignal;
  headers?: HeadersInit;
}

export interface JsonResponse<TData> {
  ok: boolean;
  status: number;
  data: TData | null;
}

const DEFAULT_API_BASE = "http://localhost:25101";

function resolveApiBase() {
  const configured = window.__SLOPOVERLORD_CONFIG__?.apiBase;
  if (typeof configured !== "string" || configured.trim().length === 0) {
    return DEFAULT_API_BASE;
  }
  return configured.trim().replace(/\/+$/, "");
}

function joinURL(path: string) {
  const base = resolveApiBase();
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  return `${base}${normalizedPath}`;
}

async function parseJSONSafely<TData>(response: Response): Promise<TData | null> {
  try {
    return (await response.json()) as TData;
  } catch {
    return null;
  }
}

export async function requestJson<TResponse, TBody = unknown>(
  options: JsonRequestOptions<TBody>
): Promise<JsonResponse<TResponse>> {
  const headers = new Headers(options.headers ?? undefined);
  const hasBody = options.body !== undefined;
  const method = options.method ?? (hasBody ? "POST" : "GET");

  if (hasBody && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }

  const requestInit: RequestInit = {
    method,
    signal: options.signal
  };

  requestInit.headers = headers;

  if (hasBody) {
    requestInit.body = JSON.stringify(options.body);
  }

  try {
    const response = await fetch(joinURL(options.path), requestInit);
    const data = await parseJSONSafely<TResponse>(response);
    return { ok: response.ok, status: response.status, data };
  } catch {
    return { ok: false, status: 0, data: null };
  }
}

import axios, { AxiosRequestConfig, AxiosResponse, InternalAxiosRequestConfig } from '@ohos/axios';
import { rcp } from '@kit.RemoteCommunicationKit';
import { createLogger } from '../Logger';
import { networkModeManager } from './NetworkModeManager';

const logger = createLogger('RcpAxiosAdapter')

/** 共享 RCP 会话：普通请求直发，直连请求按请求注入静态 DNS 规则 */
const session: rcp.Session = rcp.createSession();

const DEFAULT_CONNECT_TIMEOUT_MS: number = 15000;
const DEFAULT_TRANSFER_TIMEOUT_MS: number = 30000;

/**
 * 基于 RCP 的 axios 自定义适配器。
 *
 * 为什么不用 @ohos/axios 默认适配器：默认适配器按白名单构造 @ohos.net.http 的请求参数，
 * 而鸿蒙 http 模块没有「按域名指定解析 IP」的 ArkTS 能力；RCP 的静态 DNS 规则
 * （Configuration.dns.dnsRules）可以只替换解析结果、保留原域名做 SNI 与证书校验，
 * 与 Shaft 的 OkHttp 自定义 Dns 等价。直连模式下对映射表内的域名注入规则，
 * 其余请求（GitHub 更新检查、DoH 等）行为不变。
 *
 * 认证链路兼容：401 时抛出携带 response 的 AxiosError，现有响应拦截器无需改动。
 */
export async function rcpAdapter(config: AxiosRequestConfig): Promise<AxiosResponse<Object>> {
  const internalConfig = config as InternalAxiosRequestConfig<Object>;
  let fullUrl = joinBaseUrl(internalConfig);
  fullUrl = appendParams(fullUrl, internalConfig.params);
  const method = (internalConfig.method ?? 'get').toUpperCase() as rcp.HttpMethod;
  const headers = headersToRecord(internalConfig.headers);
  const host = hostOf(fullUrl);

  const requestConfiguration: rcp.Configuration = {
    transfer: {
      timeout: {
        connectMs: internalConfig.connectTimeout ?? DEFAULT_CONNECT_TIMEOUT_MS,
        transferMs: internalConfig.timeout ?? DEFAULT_TRANSFER_TIMEOUT_MS,
      },
    },
  };
  if (host && networkModeManager.isDirectModeForHost(host)) {
    const ip = networkModeManager.getWinnerIp(host);
    requestConfiguration.dns = { dnsRules: [{ host: host, port: 443, ipAddresses: [ip] }] };
    logger.debug(`direct -> ${host} via ${ip}`);
  }

  const content = internalConfig.data === undefined ? undefined : internalConfig.data as rcp.RequestContent;
  const request = new rcp.Request(fullUrl, method, headers, content, undefined, undefined, requestConfiguration);
  const response = await session.fetch(request);

  const status = response.statusCode;
  const responseType = String(internalConfig.responseType ?? 'json');
  let data: Object | null = null;
  if (responseType === 'array_buffer' || responseType === 'ARRAY_BUFFER') {
    data = response.body ?? null;
  } else {
    const text = response.toString();
    if (text !== null && text !== '') {
      try {
        data = JSON.parse(text) as Object;
      } catch (e) {
        data = text;
      }
    }
  }

  const axiosResponse: AxiosResponse<Object, Object> = {
    data: data ?? '',
    status: status,
    statusText: response.reasonPhrase ?? '',
    headers: flattenResponseHeaders(response.headers),
    config: internalConfig,
  };

  const validate = internalConfig.validateStatus;
  const ok = validate ? validate(status) : (status >= 200 && status < 300);
  if (!ok) {
    logger.warn(`request failed: ${method} ${fullUrl} -> ${status}`);
    throw new AdapterHttpError(
      `Request failed with status code ${status}`,
      axiosResponse,
      internalConfig
    );
  }
  return axiosResponse;
}

/**
 * 非成功状态抛出的错误：携带 response 与 config，
 * 现有响应拦截器据此做 401 自动刷新并重试原请求
 */
class AdapterHttpError extends Error {
  public response?: AxiosResponse<Object, Object>;
  public config?: InternalAxiosRequestConfig<Object>;

  constructor(message: string, response: AxiosResponse<Object, Object>, config: InternalAxiosRequestConfig<Object>) {
    super(message);
    this.name = 'AdapterHttpError';
    this.response = response;
    this.config = config;
  }
}

/** 拼接 baseURL 与相对路径 */
function joinBaseUrl(config: InternalAxiosRequestConfig): string {
  const url = config.url ?? '';
  if (/^https?:\/\//i.test(url)) return url;
  const base = config.baseURL ?? '';
  if (!base) return url;
  if (base.endsWith('/') && url.startsWith('/')) return base + url.substring(1);
  if (!base.endsWith('/') && !url.startsWith('/')) return base + '/' + url;
  return base + url;
}

/** 追加查询参数（数组值展开为重复键，跳过 null/undefined） */
function appendParams(url: string, params: Object | undefined): string {
  if (!params) return url;
  const record = params as Record<string, Object>;
  const parts: string[] = [];
  const keys = Object.keys(record);
  for (const key of keys) {
    const value = record[key];
    if (value === null || value === undefined) continue;
    if (Array.isArray(value)) {
      const arr = value as string[];
      for (const item of arr) {
        parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(item))}`);
      }
    } else {
      parts.push(`${encodeURIComponent(key)}=${encodeURIComponent(String(value))}`);
    }
  }
  if (parts.length === 0) return url;
  return url + (url.includes('?') ? '&' : '?') + parts.join('&');
}

/** 从 URL 提取主机名 */
function hostOf(url: string): string {
  const match = url.match(/^https?:\/\/([^/:?#]+)/);
  return match ? match[1] : '';
}

/**
 * axios 请求头 -> RCP 请求头。
 * AxiosHeaders 实例优先走 toJSON()，退化为 forEach 遍历，最后兜底普通对象展开。
 */
function headersToRecord(headers: Object | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  if (!headers) return result;
  const candidate = headers as Record<string, Object>;
  if (typeof candidate['toJSON'] === 'function') {
    const json = (candidate['toJSON'] as () => Object)();
    mergeFlat(result, json);
    return result;
  }
  if (typeof candidate['forEach'] === 'function') {
    const forEach = candidate['forEach'] as (cb: (value: Object, key: string) => void) => void;
    forEach((value: Object, key: string) => {
      result[key] = joinValue(value);
    });
    return result;
  }
  mergeFlat(result, headers);
  return result;
}

function mergeFlat(target: Record<string, string>, source: Object): void {
  const record = source as Record<string, Object>;
  for (const key of Object.keys(record)) {
    const value = record[key];
    if (value === null || value === undefined) continue;
    target[key] = joinValue(value);
  }
}

/** 标量或字符串数组统一折叠为逗号分隔字符串 */
function joinValue(value: Object): string {
  if (value === null || value === undefined) return '';
  if (Array.isArray(value)) {
    return (value as string[]).join(',');
  }
  return String(value);
}

/** RCP 响应头 -> axios 扁平键值对 */
function flattenResponseHeaders(headers: rcp.ResponseHeaders): Record<string, string> {
  const result: Record<string, string> = {};
  const record = headers as Record<string, Object>;
  for (const key of Object.keys(record)) {
    const value = record[key];
    if (value === null || value === undefined) continue;
    result[key] = joinValue(value);
  }
  return result;
}

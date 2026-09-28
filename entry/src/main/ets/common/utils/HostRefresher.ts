import { rcp } from '@kit.RemoteCommunicationKit';
import { createLogger } from './Logger';
import { DIRECT_PROBE_HOST, getPixivHostCandidates } from './HostMap';

const logger = createLogger('HostRefresher');

/** 普通网络探测超时（ms）：用户要求低阈值，超时即视为普通网络不可用 */
export const NORMAL_PROBE_TIMEOUT_MS: number = 2000;

/** 直连候选探测超时（ms）：只验证 TCP+TLS 握手可行性 */
export const DIRECT_PROBE_TIMEOUT_MS: number = 1500;

/** 探测请求 UA（对齐 Pixiv 官方客户端，降低被服务端 WAF 区别对待的概率） */
const PROBE_UA: string = 'PixivAndroidApp/5.0.234 (Android 11; Pixel 5)';

/** 共享探测会话：静态 DNS 规则按请求注入，会话本身不带规则 */
const probeSession: rcp.Session = rcp.createSession();

/**
 * 普通网络连通性探测：向基准主机发一个最小请求，
 * 拿到任意 HTTP 响应（含 403/404）即视为普通网络可用
 */
export async function probeNormalEndpoint(timeoutMs: number): Promise<boolean> {
  try {
    const request = new rcp.Request(`https://${DIRECT_PROBE_HOST}/`, 'GET');
    request.headers = { 'user-agent': PROBE_UA };
    request.configuration = {
      transfer: { timeout: { connectMs: timeoutMs, transferMs: timeoutMs } },
    };
    const response = await probeSession.fetch(request);
    const ok = response.statusCode > 0;
    logger.info(`probeNormalEndpoint: status=${response.statusCode}, ok=${ok}`);
    return ok;
  } catch (e) {
    logger.warn(`probeNormalEndpoint failed: ${getErrMsg(e)}`);
    return false;
  }
}

/**
 * 直连单点探测：对「域名 + 候选 IP」注入静态 DNS 规则发起 HTTPS 请求。
 * RCP 只替换解析结果，SNI/证书校验仍按原域名走，
 * 因此探测通过 = TCP 可达 + TLS 握手 + 证书校验全部成立。
 */
export async function probeHostWithIp(host: string, ip: string, connectTimeoutMs: number): Promise<boolean> {
  try {
    const request = new rcp.Request(`https://${host}/`, 'GET');
    request.headers = { 'user-agent': PROBE_UA };
    request.configuration = {
      dns: { dnsRules: [{ host: host, port: 443, ipAddresses: [ip] }] },
      transfer: { timeout: { connectMs: connectTimeoutMs, transferMs: connectTimeoutMs } },
    };
    const response = await probeSession.fetch(request);
    return response.statusCode > 0;
  } catch (e) {
    logger.debug(`probe ${host} via ${ip} failed: ${getErrMsg(e)}`);
    return false;
  }
}

/**
 * 对单个域名并行探测全部候选 IP，返回首个校验通过的 IP；全部失败返回 null。
 * 内部函数永不 reject，可安全地参与 Promise.all / 并行竞速。
 */
export function probeHostCandidates(host: string, connectTimeoutMs: number = DIRECT_PROBE_TIMEOUT_MS): Promise<string | null> {
  const candidates = getPixivHostCandidates(host);
  if (candidates.length === 0) {
    return Promise.resolve(null);
  }
  return new Promise<string | null>((resolve) => {
    let settled = false;
    let pending = candidates.length;
    for (const ip of candidates) {
      probeHostWithIp(host, ip, connectTimeoutMs).then((ok: boolean) => {
        pending -= 1;
        if (settled) {
          return;
        }
        if (ok) {
          settled = true;
          logger.info(`probe ${host}: winner ${ip}`);
          resolve(ip);
        } else if (pending === 0) {
          settled = true;
          logger.warn(`probe ${host}: all ${candidates.length} candidates failed`);
          resolve(null);
        }
      });
    }
  });
}

function getErrMsg(e: Object): string {
  const err = e as Error;
  return err?.message ?? String(e);
}

import { rcp } from '@kit.RemoteCommunicationKit';
import { createLogger } from '../Logger';
import { networkModeManager } from './NetworkModeManager';

const logger = createLogger('DirectDownloader')

/** 与系统下载器一致的请求头（i.pximg.net 需要 Referer 防盗链） */
const DOWNLOAD_HEADERS: Record<string, string> = {
  'Referer': 'https://www.pixiv.net/',
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
}

/**
 * 直连下载引擎：系统下载服务 request.agent 无法自定义 DNS（域名会被污染），
 * 直连模式下由本引擎接管图片下载 —— RCP 静态 DNS 规则按域名解析到探测胜出的 IP，
 * SNI/证书仍按原域名校验，落盘位置与系统下载器一致（沙箱 Download/Pixiv/Pictures）。
 *
 * 约束：任务入队时定引擎、中途不切换；直连任务不支持暂停/恢复（重启任务重新走本引擎）。
 */
export class DirectDownloader {
  private session: rcp.Session = rcp.createSession();

  /**
   * 下载文件到指定路径
   * @returns 是否成功（HTTP 2xx）
   */
  async download(url: string, filePath: string, onProgress?: (percent: number) => void): Promise<boolean> {
    try {
      const request = new rcp.Request(url, 'GET');
      request.headers = DOWNLOAD_HEADERS;
      const requestConfiguration: rcp.Configuration = {
        transfer: { timeout: { connectMs: 15000, transferMs: 600000, inactivityMs: 30000 } },
        tracing: {
          httpEventsHandler: {
            onDownloadProgress: (totalSize: number, transferredSize: number) => {
              if (onProgress && totalSize > 0) {
                onProgress(Math.min(100, Math.floor((transferredSize / totalSize) * 100)));
              }
            }
          }
        },
      };
      // 直连模式注入静态 DNS 规则（与 RcpAxiosAdapter 同方案）：DNS 污染网络下
      // 系统/RCP 默认解析都会失败，必须按探测胜出的 IP 解析，SNI/证书仍按原域名校验
      const host = hostOf(url);
      if (host && networkModeManager.isDirectModeForHost(host)) {
        requestConfiguration.dns = {
          dnsRules: [{ host: host, port: 443, ipAddresses: [networkModeManager.getWinnerIp(host)] }]
        };
      }
      request.configuration = requestConfiguration;
      request.destination = { kind: 'file', file: filePath };
      const response = await this.session.fetch(request);
      const ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!ok) {
        logger.warn(`download ${url} -> http ${response.statusCode}`);
      }
      return ok;
    } catch (e) {
      logger.error(`download failed: ${url}, ${getErrMsg(e)}`);
      return false;
    }
  }
}

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}

/** 从 URL 提取主机名（直连 DNS 规则选择用） */
function hostOf(url: string): string {
  const match = url.match(/^https?:\/\/([^/:?#]+)/);
  return match ? match[1] : '';
}

export const directDownloader = new DirectDownloader();

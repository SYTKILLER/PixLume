/**
 * Pixiv 域名 -> 候选 IP 列表（直连模式数据源）
 *
 * 背景：国内 DNS 对 pixiv 系域名存在污染（实测阿里 DoH 对 pixiv.net 返回的是
 * Twitter/Dropbox 段的假 IP），因此直连不依赖域名解析，改为「内置候选 IP +
 * 启动探测择优」，思路参考 Pixiv-Shaft 的 HostManager/HttpDns。
 *
 * 候选段来源：
 * - 210.140.139.129~138：Pixiv-Shaft HostManager 的 imgaz/i.pximg.net 硬编码段
 * - 210.140.139.155~158：Pixiv-Shaft HttpDns 的 API 域名固定段
 * - 172.64.145.x / 104.18.42.180：app-api/oauth.secure 的 Cloudflare 前置 IP（1.0.2 时期记录）
 *
 * 注意：本表只提供候选，实际可用性一律以 HostRefresher 的启动探测结果为准；
 * IP 失效时探测会全部失败并自动回退普通模式，更新本表即可恢复直连。
 */
export const DIRECT_HOST_CANDIDATES: Record<string, string[]> = {
  // API 域名
  'app-api.pixiv.net': ['210.140.139.155', '210.140.139.156', '210.140.139.157', '210.140.139.158', '172.64.145.17'],
  'oauth.secure.pixiv.net': ['210.140.139.155', '210.140.139.156', '210.140.139.157', '210.140.139.158', '172.64.145.76'],
  'www.pixiv.net': ['210.140.139.155', '210.140.139.156', '210.140.139.157', '210.140.139.158', '172.64.145.76'],

  // 图片域名
  'i.pximg.net': [
    '210.140.139.129', '210.140.139.130', '210.140.139.131', '210.140.139.132', '210.140.139.133',
    '210.140.139.155', '210.140.139.156', '210.140.139.157', '210.140.139.158', '104.18.42.180',
  ],
  's.pximg.net': [
    '210.140.139.129', '210.140.139.130', '210.140.139.131', '210.140.139.132', '210.140.139.133',
    '210.140.139.155', '210.140.139.156', '210.140.139.157', '210.140.139.158', '104.18.42.180',
  ],
};

/**
 * 探测/连通性判定用的基准主机：
 * 自动模式先测普通网络能否访问它，失败再对它的候选 IP 做直连探测
 */
export const DIRECT_PROBE_HOST: string = 'app-api.pixiv.net';

/** 获取某域名的候选 IP 列表（不在表中返回空数组） */
export function getPixivHostCandidates(originHost: string): string[] {
  return DIRECT_HOST_CANDIDATES[originHost] ?? [];
}

/** 判断某域名是否在直连映射表内 */
export function isDirectHost(originHost: string): boolean {
  return DIRECT_HOST_CANDIDATES[originHost] !== undefined;
}

/**
 * 兼容旧接口：返回第一个候选 IP（BypassUrlRewriter 仍在引用）。
 * 注意：URL 换 IP + Host 头的方案会破坏 TLS/SNI 证书校验，已废弃，新代码勿用。
 */
export function getPixivHostIp(originHost: string): string | null {
  return DIRECT_HOST_CANDIDATES[originHost]?.[0] ?? null;
}

import { ImageKnife, DnsOption, StaticDnsRuleItem } from '@ohos/imageknifepro';
import { appSettings } from '../../entity/SettingsModel';
import { AppConstants } from '../../constants/AppConstants';
import { preferenceUtil } from '../persistence/PreferenceUtil';
import { toastUtil } from '../ToastUtils';
import { createLogger } from '../Logger';
import { DIRECT_HOST_CANDIDATES, DIRECT_PROBE_HOST, isDirectHost } from '../HostMap';
import { NORMAL_PROBE_TIMEOUT_MS, DIRECT_PROBE_TIMEOUT_MS, probeHostCandidates, probeNormalEndpoint } from '../HostRefresher';

const logger = createLogger('NetworkModeManager')

/** 直连设置项取值 */
export type DirectConnectSetting = 'auto' | 'off' | 'on'

/** 探测后实际生效的网络模式 */
export type ResolvedNetworkMode = 'normal' | 'direct'

/**
 * 直连模式管理单例：APP 内三条网络链路（API / 图片 / 下载）统一从这里查询生效模式。
 *
 * - 职责：启动探测（自动模式）、胜出 IP 的内存与持久化、给 ImageKnife 下发静态 DNS 规则
 * - 时序约束：bootstrap() 必须在 EntryAbility.onCreate 内、loadContent / backgroundSyncData
 *   之前完成，保证任何请求与图片发出前链路已定型
 * - 失败语义：自动模式下普通网络与直连候选全部失败 → 置位待发通知（UI 就绪后 toast）并按普通模式放行
 */
@ObservedV2
export class NetworkModeManager {
  /** 设置项（appSettings.direct_connect_mode 的镜像，供状态展示） */
  @Trace setting: DirectConnectSetting = 'auto'
  /** 本次会话实际生效的模式（API 链路逐请求查询） */
  @Trace resolvedMode: ResolvedNetworkMode = 'normal'
  /** 基准主机探测到的直连 IP（设置页副标题展示用） */
  @Trace lastProbeIp: string = ''

  /** 各主机直连探测胜出的 IP（内存态，持久化于 preferences） */
  private winners: Record<string, string> = {}
  /** 自动模式探测双双失败时置位，UI 就绪后由 EntryAbility 消费并 toast */
  private pendingFailureNotice: boolean = false
  private bootstrapped: boolean = false

  /**
   * 启动探测入口。耗时预算：关闭 0ms；开启 0ms（后台刷新）；自动 ≤~2s（两路探测并行）
   */
  async bootstrap(): Promise<void> {
    if (this.bootstrapped) return
    this.bootstrapped = true
    this.setting = (appSettings.direct_connect_mode as DirectConnectSetting) || 'auto'
    await this.loadPersistedWinners()

    if (this.setting === 'off') {
      this.resolvedMode = 'normal'
      logger.info('bootstrap: mode=off -> normal')
      return
    }
    if (this.setting === 'on') {
      this.resolvedMode = 'direct'
      this.applyImageDns()
      this.refreshAllWinnersInBackground()
      logger.info('bootstrap: mode=on -> direct')
      return
    }

    // 自动模式：普通网络与直连候选两路并行探测，普通网络失败才切换直连
    const started = Date.now()
    const normalTask = probeNormalEndpoint(NORMAL_PROBE_TIMEOUT_MS)
    const directTask = probeHostCandidates(DIRECT_PROBE_HOST, DIRECT_PROBE_TIMEOUT_MS)
    const normalOk = await normalTask
    if (normalOk) {
      this.resolvedMode = 'normal'
      logger.info(`bootstrap: normal reachable in ${Date.now() - started}ms, keep normal`)
      this.refreshAllWinnersInBackground()
      return
    }
    const ip = await directTask
    if (ip) {
      this.resolvedMode = 'direct'
      logger.info(`bootstrap: normal failed, direct OK via ${ip} (${Date.now() - started}ms)`)
      // 补齐其余主机的胜出 IP 后再下发图片规则，避免图片域名落到无规则的普通链路
      await this.refreshAllWinners()
      this.applyImageDns()
    } else {
      this.resolvedMode = 'normal'
      this.pendingFailureNotice = true
      logger.warn(`bootstrap: normal & direct both failed (${Date.now() - started}ms), fallback normal`)
    }
  }

  /**
   * 设置项变更回调（设置页调用）。API 链路逐请求查询、立即生效；
   * 图片链路的 DNS 规则若未能即时生效，重启后完全生效。
   */
  onSettingChanged(value: string): void {
    this.setting = (value as DirectConnectSetting) || 'auto'
    logger.info(`onSettingChanged: ${this.setting}`)
    if (this.setting === 'off') {
      this.resolvedMode = 'normal'
      // 以空规则覆盖，尽量即时停用图片直连（覆盖语义未经文档保证，真机验证）
      try {
        ImageKnife.getInstance().setGlobalDnsOption(new DnsOption())
      } catch (e) {
        logger.warn(`clear image dns failed: ${getErrMsg(e)}`)
      }
      return
    }
    if (this.setting === 'on') {
      this.resolvedMode = 'direct'
      this.applyImageDns()
      this.refreshAllWinnersInBackground()
      toastUtil.showToast({ message: '直连已开启' })
      return
    }
    // auto：后台立即探测一次并应用结果
    this.reprobeAutoInBackground()
  }

  /** API/下载链路查询：该主机在当前模式下是否应走直连规则 */
  isDirectModeForHost(host: string): boolean {
    return this.resolvedMode === 'direct' && isDirectHost(host) && !!this.winners[host]
  }

  /** 获取某主机探测胜出的直连 IP（无则返回空串） */
  getWinnerIp(host: string): string {
    return this.winners[host] ?? ''
  }

  /** 设置页副标题：当前链路状态 */
  get statusText(): string {
    if (this.setting === 'off') return '已关闭'
    if (this.resolvedMode === 'direct') {
      return this.lastProbeIp ? `直连已生效 · ${this.lastProbeIp}` : '直连已生效'
    }
    return this.setting === 'on' ? '普通网络（直连不可用）' : '普通网络'
  }

  /** 消费「双失败」待发通知（UI 就绪后由 EntryAbility 调用） */
  consumeFailureNotice(): boolean {
    const value = this.pendingFailureNotice
    this.pendingFailureNotice = false
    return value
  }

  /** 自动模式的后台重探测（设置切回自动时触发） */
  private async reprobeAutoInBackground(): Promise<void> {
    const normalOk = await probeNormalEndpoint(NORMAL_PROBE_TIMEOUT_MS)
    if (normalOk) {
      this.resolvedMode = 'normal'
      toastUtil.showToast({ message: '直连模式：自动（当前普通网络可用）' })
      return
    }
    const ip = await probeHostCandidates(DIRECT_PROBE_HOST, DIRECT_PROBE_TIMEOUT_MS)
    if (ip) {
      this.resolvedMode = 'direct'
      await this.refreshAllWinners()
      this.applyImageDns()
      toastUtil.showToast({ message: `已切换为直连 · ${ip}` })
    } else {
      this.resolvedMode = 'normal'
      toastUtil.showToast({ message: '网络连接失败' })
    }
  }

  /** 后台刷新全部主机的胜出 IP，完成后重下图片规则 */
  private refreshAllWinnersInBackground(): void {
    this.refreshAllWinners().then(() => {
      if (this.resolvedMode === 'direct') {
        this.applyImageDns()
      }
    })
  }

  /** 并行探测映射表内全部主机，胜出 IP 写内存 + 持久化 */
  private async refreshAllWinners(): Promise<void> {
    const hosts = Object.keys(DIRECT_HOST_CANDIDATES)
    const results = await Promise.all(hosts.map((h: string) => probeHostCandidates(h, DIRECT_PROBE_TIMEOUT_MS)))
    const next: Record<string, string> = {}
    for (let i = 0; i < hosts.length; i++) {
      const ip = results[i]
      if (ip) next[hosts[i]] = ip
    }
    this.winners = next
    if (next[DIRECT_PROBE_HOST]) {
      this.lastProbeIp = next[DIRECT_PROBE_HOST]
    }
    try {
      await preferenceUtil.put(AppConstants.KEY_DIRECT_WINNERS, JSON.stringify(next))
      logger.info(`refreshAllWinners: ${Object.keys(next).length}/${hosts.length} hosts OK`)
    } catch (e) {
      logger.warn(`persist winners failed: ${getErrMsg(e)}`)
    }
  }

  /** 把胜出 IP 下发给 ImageKnife（图片链路的直连规则，静态 DNS + 原 SNI/证书校验） */
  private applyImageDns(): void {
    try {
      const hosts = Object.keys(this.winners)
      if (hosts.length === 0) return
      const dnsOption = new DnsOption()
      for (const host of hosts) {
        const item = new StaticDnsRuleItem()
        item.host = host
        item.port = 443
        item.ipAddresses = [this.winners[host]]
        dnsOption.staticDnsRule.push(item)
      }
      ImageKnife.getInstance().setGlobalDnsOption(dnsOption)
      logger.info(`applyImageDns: ${hosts.length} hosts applied`)
    } catch (e) {
      logger.error(`applyImageDns failed: ${getErrMsg(e)}`)
    }
  }

  private async loadPersistedWinners(): Promise<void> {
    try {
      const json = await preferenceUtil.get<string>(AppConstants.KEY_DIRECT_WINNERS, '')
      if (!json) return
      this.winners = JSON.parse(json) as Record<string, string>
      if (this.winners[DIRECT_PROBE_HOST]) {
        this.lastProbeIp = this.winners[DIRECT_PROBE_HOST]
      }
    } catch (e) {
      logger.warn(`load persisted winners failed: ${getErrMsg(e)}`)
    }
  }
}

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}

export const networkModeManager: NetworkModeManager = new NetworkModeManager()

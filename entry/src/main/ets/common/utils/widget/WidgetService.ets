import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import axios from '@ohos/axios';
import { pixiv } from '../../../services/PixivService';
import { AccountContext, PixivIllust, PixivListResult } from '../../../services/PixivTypes';
import { appSettings } from '../../entity/SettingsModel';
import { rcpAdapter } from '../network/RcpAxiosAdapter';
import { directDownloader } from '../network/DirectDownloader';
import { networkModeManager } from '../network/NetworkModeManager';
import { preferenceUtil } from '../persistence/PreferenceUtil';
import { kvDbUtil } from '../KVdbUtil';
import { tagCollectionService } from '../TagCollectionService';
import { createLogger } from '../Logger';

const logger = createLogger('WidgetService')

const WIDGET_PREF_FILE = 'pixlume_widget'
const IMAGE_DIR = 'widget'
// 列表缓存有效期：命中后单次刷新只剩一次小图下载，5 秒生命窗内更稳
const LIST_CACHE_TTL_MS = 60 * 60 * 1000
// FormExtensionAbility 触发回调后仅存活约 5 秒，整次刷新以此为硬预算
const REFRESH_BUDGET_MS = 4500
// 沙箱内保留的最新卡片图片数
const KEEP_IMAGE_COUNT = 4

/** 卡片随机池条目 */
export interface WidgetPoolItem {
  id: number
  target: string
  url: string
}

interface FormState {
  lastIllustId: number
  target: string
  updatedAt: number
  /** 池代际（cacheKey@缓存时间戳）：池换代时轮播队列自动重建 */
  gen: string
  /** 洗牌轮播剩余队列（illustId 按展示顺序），保证整个池子内不重复 */
  queue: number[]
}

interface PickResult {
  item: WidgetPoolItem
  state: FormState
}

interface SharedLast {
  imgFile: string
  illustId: number
  target: string
}

interface ListCache {
  ts: number
  items: WidgetPoolItem[]
}

/** 带超时的等待：超时返回 null，不抛出（原 promise 继续跑但结果被丢弃） */
async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T | null> {
  if (ms <= 0) return null
  let timer: number = -1
  try {
    return await Promise.race([
      promise,
      new Promise<T | null>((resolve: (value: T | null) => void) => {
        timer = setTimeout(() => resolve(null), ms)
      })
    ])
  } finally {
    if (timer !== -1) clearTimeout(timer)
  }
}

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}

/**
 * 桌面卡片复用层：卡片进程（FormExtensionAbility）内的无 UI 初始化与刷新流水线。
 * 复用主进程同一套网络/鉴权/直连服务（同一沙箱），图片经 formImages fd + memory:// 下发。
 */
export class WidgetService {
  private runtimeReady: boolean = false
  private runtimePromise: Promise<void> | null = null
  // 进行中的刷新（按 formId），防止退出刷新与手动刷新重叠
  private refreshing: Set<string> = new Set()

  /** 卡片进程无 UI 运行时初始化（幂等；对齐 EntryAbility.initAppEnvironment 的无 UI 子集） */
  async ensureRuntime(context: common.Context): Promise<void> {
    if (this.runtimeReady) return
    if (!this.runtimePromise) {
      this.runtimePromise = this.doInitRuntime(context).then(() => {
        this.runtimeReady = true
      })
    }
    await this.runtimePromise
  }

  private async doInitRuntime(context: common.Context): Promise<void> {
    await preferenceUtil.init(context, 'pixlume_preference')
    await kvDbUtil.initKVManager(context, 'pixlume')
    // 屏蔽词过滤依赖（PixivData.fetchListWithFilter 内部会 await ready）
    tagCollectionService.init(context)
    await appSettings.load()
    // 与 EntryAbility 相同：安装 RCP 适配器，直连模式下按静态 DNS 规则解析 pixiv 域名
    axios.defaults.adapter = rcpAdapter
    pixiv.installAdapter(rcpAdapter)
    await networkModeManager.bootstrap()
    const accountsJson = await kvDbUtil.getData<string>('pixiv_accounts', '[]')
    const savedAccounts = JSON.parse(accountsJson) as AccountContext[]
    const lastActiveUserId = await kvDbUtil.getData<string>('active_user_id', '')
    pixiv.initAccounts(savedAccounts, lastActiveUserId)
    logger.info(`runtime ready, login=${pixiv.isLogin()}`)
  }

  /** onAddForm 用的初始数据：有上次缓存图则直接带 fd 出图，否则占位 */
  buildInitialData(context: common.Context): Record<string, Object> {
    const data: Record<string, Object> = { 'state': 'empty' }
    try {
      const prefs = this.getWidgetPrefs(context)
      const json = prefs.getSync('shared_last', '') as string
      if (json) {
        const last = JSON.parse(json) as SharedLast
        if (last.imgFile && fs.accessSync(last.imgFile)) {
          const file = fs.openSync(last.imgFile, fs.OpenMode.READ_ONLY)
          const imgName = `w${Date.now()}`
          const images: Record<string, number> = {}
          images[imgName] = file.fd
          data['state'] = 'ok'
          data['loaded'] = true
          data['imgName'] = imgName
          data['illustId'] = last.illustId
          data['target'] = last.target
          data['formImages'] = images
        }
      }
    } catch (e) {
      logger.warn(`buildInitialData: ${getErrMsg(e)}`)
    }
    return data
  }

  /** 完整刷新流水线：初始化 → 取池 → 随机 → 下载 → updateForm */
  async refreshOne(context: common.Context, formId: string): Promise<void> {
    if (!formId || this.refreshing.has(formId)) return
    this.refreshing.add(formId)
    try {
      await this.ensureRuntime(context)
      if (!pixiv.isLogin()) {
        await this.pushState(formId, 'need_login')
        return
      }
      const deadline = Date.now() + REFRESH_BUDGET_MS
      const pick = await this.pickNextWork(context, formId, deadline)
      if (!pick) {
        await this.pushState(formId, 'error')
        return
      }
      const imgPath = await this.downloadCover(context, pick.item.url, deadline - Date.now())
      if (!imgPath) {
        await this.pushState(formId, 'error')
        return
      }
      await this.pushImage(formId, imgPath, pick.item.id, pick.item.target)

      const prefs = this.getWidgetPrefs(context)
      // 轮播队列在取图时已持久化，成功后仅回写当前展示目标
      pick.state.lastIllustId = pick.item.id
      pick.state.target = pick.item.target
      pick.state.updatedAt = Date.now()
      prefs.putSync(`form_state_${formId}`, JSON.stringify(pick.state))
      const shared: SharedLast = { imgFile: imgPath, illustId: pick.item.id, target: pick.item.target }
      prefs.putSync('shared_last', JSON.stringify(shared))
      prefs.flush()
      this.pruneImages(context, imgPath)
      logger.info(`refresh ok: form=${formId} illust=${pick.item.id}`)
    } catch (e) {
      logger.error(`refreshOne failed: ${getErrMsg(e)}`)
      try {
        await this.pushState(formId, 'error')
      } catch (err) {
        logger.warn(`push error state failed: ${getErrMsg(err)}`)
      }
    } finally {
      this.refreshing.delete(formId)
    }
  }

  /** 卡片移除时清理按 formId 的状态（加桌弹窗会成对触发，需幂等） */
  onFormRemoved(context: common.Context, formId: string): void {
    try {
      const prefs = this.getWidgetPrefs(context)
      prefs.deleteSync(`form_state_${formId}`)
      prefs.flush()
    } catch (e) {
      logger.warn(`onFormRemoved: ${getErrMsg(e)}`)
    }
  }

  private getWidgetPrefs(context: common.Context): preferences.Preferences {
    return preferences.getPreferencesSync(context, { name: WIDGET_PREF_FILE })
  }

  private async pushState(formId: string, state: string): Promise<void> {
    const data: Record<string, Object> = { 'state': state }
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(data))
  }

  /** 洗牌轮播取图：池内按洗牌顺序消费、播完重洗；取图时即持久化剩余队列 */
  private async pickNextWork(context: common.Context, formId: string, deadline: number): Promise<PickResult | null> {
    const source = appSettings.card_image_source
    const novelMode = appSettings.novel_mode
    const cacheKey = `${source}@${novelMode ? 'novel' : 'illust'}`
    const prefs = this.getWidgetPrefs(context)

    // 取池（带缓存），并计算池代际
    let items: WidgetPoolItem[] = []
    let gen = cacheKey
    const cachedJson = prefs.getSync(`list_cache_${cacheKey}`, '') as string
    if (cachedJson) {
      try {
        const cache = JSON.parse(cachedJson) as ListCache
        if (cache.items && cache.items.length > 0 && Date.now() - cache.ts < LIST_CACHE_TTL_MS) {
          items = cache.items
          gen = `${cacheKey}@${cache.ts}`
        }
      } catch (e) {
        // 缓存损坏则重新拉取
      }
    }
    if (items.length === 0) {
      items = await this.fetchPool(source, novelMode, deadline - Date.now())
      if (items.length === 0) return null
      const ts = Date.now()
      const cache: ListCache = { ts: ts, items: items }
      prefs.putSync(`list_cache_${cacheKey}`, JSON.stringify(cache))
      prefs.flush()
      gen = `${cacheKey}@${ts}`
    }

    const itemById: Map<number, WidgetPoolItem> = new Map()
    for (const it of items) {
      itemById.set(it.id, it)
    }

    // 读卡片状态（旧版本无 gen/queue 字段 → 走重建分支，天然兼容）
    let lastIllustId = 0
    let savedGen = ''
    let queue: number[] = []
    const stateJson = prefs.getSync(`form_state_${formId}`, '') as string
    if (stateJson) {
      try {
        const st = JSON.parse(stateJson) as FormState
        lastIllustId = st.lastIllustId ?? 0
        if (st.gen === gen) {
          savedGen = st.gen
          queue = st.queue ?? []
        }
      } catch (e) {
        // 状态损坏按重建处理
      }
    }

    const rebuildQueue = (): number[] => {
      const ids: number[] = items.map(it => it.id)
      // Fisher-Yates 洗牌
      for (let i = ids.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1))
        const tmp = ids[i]
        ids[i] = ids[j]
        ids[j] = tmp
      }
      // 重洗后避开刚展示过的一张（单图池除外）
      if (ids.length > 1) {
        const idx = ids.indexOf(lastIllustId)
        if (idx > -1) {
          ids.splice(idx, 1)
        }
      }
      return ids
    }

    const takeFromQueue = (q: number[]): WidgetPoolItem | null => {
      while (q.length > 0) {
        const id = q.shift()
        if (id === undefined) break
        const it = itemById.get(id)
        if (it) return it
      }
      return null
    }

    if (savedGen !== gen || queue.length === 0) {
      queue = rebuildQueue()
    }
    let picked = takeFromQueue(queue)
    if (!picked) {
      // 队列耗尽或所存 id 均已不在池内（如过滤规则变化）→ 重建一轮
      queue = rebuildQueue()
      picked = takeFromQueue(queue)
    }
    if (!picked) return null

    const saved: FormState = {
      lastIllustId: lastIllustId,
      target: picked.target,
      updatedAt: Date.now(),
      gen: gen,
      queue: queue
    }
    prefs.putSync(`form_state_${formId}`, JSON.stringify(saved))
    prefs.flush()
    return { item: picked, state: saved }
  }

  /** 请求来源第 1 页并构建随机池（show_H 开启时剔除 R-18，显式选择的 R-18 榜单除外） */
  private async fetchPool(source: string, novelMode: boolean, budgetMs: number): Promise<WidgetPoolItem[]> {
    const mode = source.startsWith('rank:') ? source.substring(5) : ''
    const filterR18 = appSettings.show_H && !mode.includes('r18')
    try {
      let result: PixivListResult | null = null
      if (source === 'recommend') {
        result = await withTimeout(pixiv.getRecommended(true), budgetMs)
      } else if (source === 'follow') {
        result = await withTimeout(pixiv.getFollowingIllusts('public'), budgetMs)
      } else if (mode) {
        result = novelMode
          ? await withTimeout(pixiv.getNovelRanking(mode), budgetMs)
          : await withTimeout(pixiv.getRanking(mode), budgetMs)
      }
      if (!result) return []

      const rawList: PixivIllust[] = (result.illusts ?? result.novels ?? []) as PixivIllust[]
      const target = (mode && novelMode) ? 'novel_detail' : 'illust_detail'
      const items: WidgetPoolItem[] = []
      for (const it of rawList) {
        if (!it || !it.id) continue
        // visible=false 为不可见作品（隐私/账号限制）
        if (it.visible === false) continue
        if (filterR18 && (it.x_restrict ?? 0) > 0) continue
        const url = it.image_urls?.square_medium || it.image_urls?.medium || ''
        if (!url) continue
        items.push({ id: it.id, target: target, url: url })
      }
      logger.info(`fetchPool ${cacheKeyOf(source, novelMode)}: ${items.length} items`)
      return items
    } catch (e) {
      logger.warn(`fetchPool failed: ${getErrMsg(e)}`)
      return []
    }
  }

  private async downloadCover(context: common.Context, url: string, budgetMs: number): Promise<string | null> {
    const dir = `${context.filesDir}/${IMAGE_DIR}`
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true)
      }
    } catch (e) {
      // 目录已存在
    }
    const path = `${dir}/w_${Date.now()}.jpg`
    const ok = await withTimeout(directDownloader.download(url, path), budgetMs)
    if (!ok) {
      logger.warn(`downloadCover failed: ${url}`)
      return null
    }
    return path
  }

  /** 图片经 formImages(fd) 下发；imgName 每次必须变化，否则卡片不重绘 */
  private async pushImage(formId: string, imgPath: string, illustId: number, target: string): Promise<void> {
    const file = fs.openSync(imgPath, fs.OpenMode.READ_ONLY)
    try {
      const imgName = `w${Date.now()}`
      const images: Record<string, number> = {}
      images[imgName] = file.fd
      const data: Record<string, Object> = {
        'state': 'ok',
        'loaded': true,
        'imgName': imgName,
        'illustId': illustId,
        'target': target,
        'formImages': images
      }
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data))
    } finally {
      fs.closeSync(file)
    }
  }

  /** 只保留最新几张卡片图，防止沙箱膨胀（keepPath 为当前正在显示的文件） */
  private pruneImages(context: common.Context, keepPath: string): void {
    try {
      const dir = `${context.filesDir}/${IMAGE_DIR}`
      const names: string[] = fs.listFileSync(dir)
      const files: string[] = []
      for (const name of names) {
        const p = `${dir}/${name}`
        if (p !== keepPath) {
          files.push(p)
        }
      }
      // 文件名带毫秒时间戳，字典序即时间序
      files.sort()
      const deleteCount = files.length - (KEEP_IMAGE_COUNT - 1)
      for (let i = 0; i < deleteCount; i++) {
        try {
          fs.unlinkSync(files[i])
        } catch (e) {
          // 单个文件删除失败忽略
        }
      }
    } catch (e) {
      logger.warn(`pruneImages: ${getErrMsg(e)}`)
    }
  }

}

function cacheKeyOf(source: string, novelMode: boolean): string {
  return `${source}@${novelMode ? 'novel' : 'illust'}`
}

export const widgetService = new WidgetService()

/**
 * 应用主进程批量触发卡片刷新（不直接推数据，由卡片进程拉起后自取）。
 * 用于退出应用刷新与设置变更后的立即换图。
 */
export async function requestWidgetRefresh(context: common.UIAbilityContext): Promise<void> {
  try {
    const count = await formProvider.reloadForms(context, 'entry', 'PixCardFormAbility', 'PixCard')
    logger.info(`reloadForms -> ${count}`)
  } catch (e) {
    logger.warn(`reloadForms failed: ${getErrMsg(e)}`)
  }
}

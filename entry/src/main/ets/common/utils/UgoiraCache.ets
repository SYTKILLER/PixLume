import zlib from '@ohos.zlib';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { directDownloader } from './network/DirectDownloader';
import { createLogger } from './Logger';
import { UgoiraMetadata } from '../../services/PixivTypes';

const logger = createLogger('UgoiraCache')

/**
 * 动图（ugoira）帧包缓存：
 * Pixiv 动图本质是"帧图片 zip + 每帧延时表"，查看与转码 GIF 都要先把 zip 下载并解压成帧序列。
 * 缓存布局：{cacheDir}/ugoira/{illustId}/
 *   meta.json          —— 帧表缓存（file + delay），命中后不再请求 metadata 接口
 *   ugoira_{size}.zip  —— 原始帧包
 *   frames_{size}/     —— 解压后的帧目录（文件名即 zip 内条目名，如 000000.jpg）
 * 放在 cacheDir 下：系统可按需回收，播放器侧丢失后重新下载即可。
 */

/** 帧包尺寸档位（对应 Pixiv zip URL 中的 600x600 / 1920x1080 标记） */
export type UgoiraSize = '600x600' | '1920x1080'

/** 已解压的帧序列：paths 与 delays 一一对应（顺序即播放顺序） */
export interface UgoiraFrames {
  paths: string[]
  delays: number[]
}

interface CachedFrame {
  file: string
  delay: number
}

interface CachedMeta {
  frames: CachedFrame[]
}

function cacheRootOf(context: common.Context, illustId: number): string {
  return `${context.cacheDir}/ugoira/${illustId}`
}

function zipPathOf(context: common.Context, illustId: number, size: UgoiraSize): string {
  return `${cacheRootOf(context, illustId)}/ugoira_${size}.zip`
}

function framesDirOf(context: common.Context, illustId: number, size: UgoiraSize): string {
  return `${cacheRootOf(context, illustId)}/frames_${size}`
}

function metaPathOf(context: common.Context, illustId: number): string {
  return `${cacheRootOf(context, illustId)}/meta.json`
}

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}

/** 递归删除目录（decompressFile 不接受已存在的目标目录，重新解压前必须清理） */
export function removeDirRecursive(dirPath: string): void {
  try {
    if (!fs.accessSync(dirPath)) return
  } catch (e) {
    return
  }
  try {
    const names: string[] = fs.listFileSync(dirPath)
    for (const name of names) {
      const child = `${dirPath}/${name}`
      if (fs.statSync(child).isDirectory()) {
        removeDirRecursive(child)
      } else {
        fs.unlinkSync(child)
      }
    }
    fs.rmdirSync(dirPath)
  } catch (e) {
    logger.warn(`removeDirRecursive failed: ${dirPath}, ${getErrMsg(e)}`)
  }
}

async function deleteFileIfExists(filePath: string): Promise<void> {
  try {
    if (fs.accessSync(filePath)) fs.unlinkSync(filePath)
  } catch (e) {
    logger.warn(`deleteFile failed: ${filePath}, ${getErrMsg(e)}`)
  }
}

function readCachedMeta(context: common.Context, illustId: number): CachedMeta | null {
  try {
    const metaPath = metaPathOf(context, illustId)
    if (!fs.accessSync(metaPath)) return null
    const parsed = JSON.parse(fs.readTextSync(metaPath)) as CachedMeta
    if (!parsed || !Array.isArray(parsed.frames) || parsed.frames.length === 0) return null
    return parsed
  } catch (e) {
    return null
  }
}

/**
 * 读取已解压的帧缓存；任一帧文件缺失即视为未命中（避免半截解压被当成完整缓存）。
 */
export async function loadCachedUgoiraFrames(context: common.Context, illustId: number,
  size: UgoiraSize): Promise<UgoiraFrames | null> {
  const meta = readCachedMeta(context, illustId)
  if (!meta) return null
  const dir = framesDirOf(context, illustId, size)
  const paths: string[] = []
  for (const frame of meta.frames) {
    const path = `${dir}/${frame.file}`
    try {
      if (!fs.accessSync(path)) return null
    } catch (e) {
      return null
    }
    paths.push(path)
  }
  return { paths: paths, delays: meta.frames.map(f => f.delay) }
}

/** 按尺寸档位推导帧包地址：600x600 之外的档位由 medium URL 标记替换得出（Shaft 同款技巧） */
function zipUrlForSize(mediumUrl: string, size: UgoiraSize): string {
  if (size === '600x600') return mediumUrl
  const large = mediumUrl.replace('600x600', size)
  return large === mediumUrl ? mediumUrl : large
}

/**
 * 确保指定尺寸的帧序列已解压就绪：缓存命中直接返回；
 * 否则下载 zip（onProgress 上报 0~100）→ 解压 → 帧表落盘。
 * @param meta 来自 /v1/ugoira/metadata 的动图元数据（zip 地址 + 帧表）
 */
export async function ensureUgoiraFrames(context: common.Context, illustId: number,
  meta: UgoiraMetadata, size: UgoiraSize, onProgress?: (percent: number) => void): Promise<UgoiraFrames> {
  const cached = await loadCachedUgoiraFrames(context, illustId, size)
  if (cached) {
    onProgress?.(100)
    return cached
  }
  if (!meta.zip_urls?.medium || !meta.frames || meta.frames.length === 0) {
    throw new Error('ugoira metadata incomplete')
  }

  // 帧表落盘：再次播放/转码直接读本地，不再请求 metadata 接口
  const root = cacheRootOf(context, illustId)
  try {
    if (!fs.accessSync(root)) fs.mkdirSync(root, true)
    const metaPath = metaPathOf(context, illustId)
    const file = fs.openSync(metaPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC)
    fs.writeSync(file.fd, JSON.stringify({ frames: meta.frames }))
    fs.closeSync(file)
  } catch (e) {
    logger.warn(`write meta.json failed: ${getErrMsg(e)}`)
  }

  const zipPath = zipPathOf(context, illustId, size)
  if (!fs.accessSync(zipPath)) {
    const url = zipUrlForSize(meta.zip_urls.medium, size)
    logger.info(`download ugoira zip: ${url}`)
    const ok = await directDownloader.download(url, zipPath,
      (percent: number) => onProgress?.(Math.floor(percent * 0.9)))
    if (!ok) {
      // 半截文件清理，避免下次误判为已下载
      await deleteFileIfExists(zipPath)
      throw new Error(`ugoira zip download failed: ${url}`)
    }
  }

  const dir = framesDirOf(context, illustId, size)
  removeDirRecursive(dir)
  // zlib.decompressFile 要求目标目录必须已存在（否则 900002），且会覆盖其中同名文件；
  // 重建空目录即可满足要求，重复解压也不会残留旧帧（帧名来自帧表，重解压前已整目录删除）
  if (!fs.accessSync(dir)) fs.mkdirSync(dir, true)
  onProgress?.(95)
  await zlib.decompressFile(zipPath, dir)
  onProgress?.(100)

  const frames = await loadCachedUgoiraFrames(context, illustId, size)
  if (!frames) throw new Error('ugoira frames incomplete after unzip')
  return frames
}

/** 清理指定尺寸的转码缓存（zip + 帧目录），meta.json 保留 */
export async function clearUgoiraFrames(context: common.Context, illustId: number, size: UgoiraSize): Promise<void> {
  removeDirRecursive(framesDirOf(context, illustId, size))
  await deleteFileIfExists(zipPathOf(context, illustId, size))
}

import { request } from "@kit.BasicServicesKit";
import { common } from '@kit.AbilityKit';
import { fileUri, fileIo as fs, picker } from "@kit.CoreFileKit";
import { image } from "@kit.ImageKit";
import { getDownloadRecordTable, DownloadRecordTable } from "../common/utils/database/impl/DownloadRecordTable";
import DownloadRecordInfo from "../common/entity/DownloadRecordInfo";
import { PixivIllust, PixivNovel } from "../services/PixivTypes";
import { pixiv } from "../services/PixivService";
import { createLogger } from "../common/utils/Logger";
import { photoAccessHelper } from "@kit.MediaLibraryKit";
import { toastUtil } from "../common/utils/ToastUtils";
import { appSettings } from "../common/entity/SettingsModel";
import { networkModeManager } from "../common/utils/network/NetworkModeManager";
import { directDownloader } from "../common/utils/network/DirectDownloader";
import { ensureUgoiraFrames, clearUgoiraFrames, UgoiraFrames, UgoiraSize } from "../common/utils/UgoiraCache";

const logger = createLogger('DownloadsViewModel')

/** 保存到系统相册的文件条目 */
interface GallerySaveItem {
  filePath: string;
  title: string;
}

/** 转码解码阶段的总内存预算（字节，RGBA 4B/px）：帧数 × 分辨率超出时等比缩小解码尺寸 */
const UGOIRA_DECODE_BUDGET_BYTES = 256 * 1024 * 1024;

@ObservedV2
export class DownloadsViewModel {

  @Trace selectedIds: Set<string> = new Set()

  @Trace displayList: DownloadRecordInfo[] = []
  @Trace tasks: DownloadRecordInfo[] = []

  @Trace isEditMode: boolean = false
  @Trace currentPage: number = 0

  private downloadDir = ""
  private context: common.Context | null = null
  // 正在批量保存的作品 id，防止回调连续到达时重复弹窗
  private savingIllustIds: Set<number> = new Set()
  // 直连引擎：进行中的任务 id（与系统任务统一计入并发上限）
  private activeDirectTaskIds: Set<string> = new Set()
  // 直连引擎：待派发的任务队列（并发有空位时按序启动）
  private pendingDirectTasks: DownloadRecordInfo[] = []
  // 动图转码管线：进行中/待派发（与直连、系统任务统一计入并发上限）
  private activeUgoiraTaskIds: Set<string> = new Set()
  private pendingUgoiraTasks: DownloadRecordInfo[] = []

  // 公共请求头
  private readonly PIXIV_HEADERS: Record<string, string> = {
    "Referer": "https://www.pixiv.net/",
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  };

  /** 初始化下载目录 */
  async initDownLoad(context: common.Context) {
    this.context = context
    try {
      this.downloadDir = `${context.filesDir}/Pixiv/Pictures`;
      if (!fs.accessSync(this.downloadDir)) fs.mkdirSync(this.downloadDir);
    } catch (e) {
      logger.error("initDownLoad Error:", e)
    }
  }

  // 监听页码和总任务列表的变化，自动刷新显示列表
  @Monitor('currentPage', 'tasks')
  onDataChanged() {
    this.refreshDisplayList();
  }

  /** 切换编辑模式 */
  toggleEditMode() {
    this.isEditMode = !this.isEditMode;
    this.selectedIds.clear();
  }

  /** 切换选中状态 */
  toggleSelect(task_id: string) {
    if (this.selectedIds.has(task_id)) {
      this.selectedIds.delete(task_id);
    } else {
      this.selectedIds.add(task_id);
    }
  }

  /** 切换缩略图显示 */
  toggleThumbnail() {
    appSettings.show_thumbnail = !appSettings.show_thumbnail;
  }

  /** 判断是否选中 */
  isSelected(task_id: string): boolean {
    return this.selectedIds.has(task_id); // O(1) 复杂度
  }

  /** 全选当前页面 */
  selectAllVisible() {
    this.selectedIds.clear();
    this.displayList.forEach(task => this.selectedIds.add(task.task_id));
  }

  /** 取消全选 */
  deselectAll() {
    this.selectedIds.clear();
  }

  /** 获取选中数量 */
  getSelectedCount(): number {
    return this.selectedIds.size;
  }

  editDelete() {
    // 筛选出当前选中的任务对象数组
    const selectedTasks = this.tasks.filter(t => this.selectedIds.has(t.task_id));
    const count = selectedTasks.length;
    // 根据数量动态生成提示文案
    let message = '';
    if (count === 1) {
      // 只选了一个：显示具体作品名
      const title = selectedTasks[0].title || '未知作品';
      message = `确定要删除「${title}」吗？此操作不可恢复。`;
    } else if (count > 1) {
      // 选了多个：显示数量
      message = `确定要删除选中的 ${count} 个任务吗？此操作不可恢复。`;
    }

    // 召唤弹窗
    if (message) {
      toastUtil.showAlertDialog({
        title: '确认删除',
        message: message,
        alignment: DialogAlignment.Center,
        primaryButton: {
          value: '删除',
          fontColor: Color.Red,
          action: async () => {
            await this.batchRemoveSelectedTasks();
          }
        },
        secondaryButton: {
          value: '取消',
          action: () => {}
        }
      })
    }
  }

  /** 多选后批量删除 */
  async batchRemoveSelectedTasks() {
    if (this.selectedIds.size === 0) return;
    // 获取待删除 ID
    const idsToDelete = Array.from(this.selectedIds);
    // 调用底层删除
    await this.batchDeleteTasksByIds(idsToDelete);
    // 清空勾选、退出编辑模式
    this.toggleEditMode();
  }

  async getFileUri(filePath: string | undefined): Promise<string> {
    return filePath ? fileUri.getUriFromPath(filePath) : '';
  }

  /** 刷新当前展示的列表数据 */
  refreshDisplayList() {
    const statusList: (number[] | null)[] = [
      null, // 0: 所有
      [request.agent.State.RUNNING, request.agent.State.RETRYING], // 1: 下载中
      [request.agent.State.COMPLETED], // 2: 已完成
      [request.agent.State.STOPPED, request.agent.State.FAILED] // 3: 失败
    ];
    const targetStatus = statusList[this.currentPage] ?? null;
    // 赋新数组引用，确保 @Trace 能通知到 UI
    this.displayList = targetStatus
      ? this.tasks.filter(d => targetStatus.includes(d.status))
      : [...this.tasks];
  }

  /** 获取任务列表 */
  async fetchSysTask() {
    if (!this.context) return;
    const db = getDownloadRecordTable(this.context);
    let dbRecords = await db.queryAllDesc();

    const stateTypes = [
      request.agent.State.RUNNING, request.agent.State.FAILED, request.agent.State.PAUSED,
      request.agent.State.COMPLETED, request.agent.State.STOPPED, request.agent.State.RETRYING,
      request.agent.State.WAITING, request.agent.State.INITIALIZED,
    ];
    try {
      const task_ids = (await Promise.all(stateTypes.map(s => request.agent.search({ state: s })))).flat();
      const sysTasks = await Promise.all(task_ids.map(id => request.agent.show(id).catch(() => null)));

      const sysTaskMap = new Map<string, request.agent.TaskInfo>();
      sysTasks.forEach(task => {
        if (task) {
          sysTaskMap.set(task.tid, task);
        }
      });

      this.tasks = dbRecords.map(record => {
        if (record.task_id.startsWith('direct_') || record.task_id.startsWith('ugoira_')) {
          // 直连/动图管线任务没有系统侧任务：活跃中的保持现状；非活跃且未完成的视为失败（进程重启即中断）
          if (!this.activeDirectTaskIds.has(record.task_id) && !this.activeUgoiraTaskIds.has(record.task_id)
            && record.status !== request.agent.State.COMPLETED) {
            record.status = request.agent.State.FAILED;
          }
          return record;
        }
        const sysTask = sysTaskMap.get(record.task_id);
        if (sysTask) {
          record.status = sysTask.progress.state;
          if (sysTask.progress.sizes && sysTask.progress.sizes.length > 0) {
            const total = sysTask.progress.sizes[0];
            if (total > 0) {
              record.progress = Math.floor((sysTask.progress.processed / total) * 100);
            }
          }
        } else if (record.status !== request.agent.State.COMPLETED) {
          record.status = request.agent.State.FAILED;
        }
        return record;
      }).sort((a, b) => b.create_time - a.create_time);

      this.tasks.forEach(record => {
        if (record.task_id.startsWith('direct_') || record.task_id.startsWith('ugoira_')) return;
        if (record.status !== request.agent.State.COMPLETED &&
          record.status !== request.agent.State.FAILED &&
          record.status !== request.agent.State.STOPPED) {
          this.attachSysTask(record.task_id);
        }
      });
    } catch (e) {
      logger.error("fetchSysTask failed", e);
    }
  }

  /** 检查沙箱文件是否真实存在 */
  isFileInSandbox(filePath: string | undefined): boolean {
    if (!filePath) return false;
    try {
      // accessSync 是微秒级的本地校验，在这里使用不会卡 UI
      return fs.accessSync(filePath);
    } catch (e) {
      return false;
    }
  }

  /** 手动保存到相册 */
  async manualSaveToGallery(record: DownloadRecordInfo) {
    if (!this.isFileInSandbox(record.filePath)) {
      toastUtil.showToast({ message: "文件不存在或已保存" });
      return;
    }
    toastUtil.showToast({ message: `正在导出 ${record.title || '未命名作品'}` })
    // 复用保存逻辑，保存成功后它会自动 deleteFile 删除沙箱文件
    await this.saveImageToGallery(record.filePath, record.title || '未命名作品');
    // 保存成功后，主动刷新一次列表
    this.refreshDisplayList()
  }

  async pauseTask(id: string) {
    if (id.startsWith('direct_') || id.startsWith('ugoira_')) {
      toastUtil.showToast({ message: '该任务不支持暂停' });
      return;
    }
    (await this.getSysTask(id))?.pause();
  }

  // 恢复任务
  async resumeTask(id: string) {
    const task = await this.getSysTask(id);
    if (task) this.TryRunTask(task, true);
  }

  // 重启任务
  async restartTask(id: string) {
    if (!this.context) return;
    const record = this.tasks.find(d => d.task_id === id);
    if (!record) {
      toastUtil.showToast({ message: `未查询到下载记录` })
      return;
    }
    toastUtil.showToast({ message: `开始重试「${record.title}」任务` })
    const task = await this.getSysTask(id);
    if (task) {
      this.TryRunTask(task);
    } else {
      await this.recreateLostTask(record);
    }
  }

  async deleteOneTask(task: DownloadRecordInfo) {
    await this.removeTask(task)
  }

  async pauseAllTask() {
    const task_ids = await request.agent.search({ state: request.agent.State.RUNNING });
    for (let id of task_ids) {
      const task = await this.getSysTask(id);
      if (task) { this.attachTask(task); await task.pause(); }
    }
  }

  async resumeAllTask() {
    const task_ids = await request.agent.search({ state: request.agent.State.PAUSED });
    for (let id of task_ids) {
      const task = await this.getSysTask(id);
      if (task) {
        this.attachTask(task);
        await this.TryRunTask(task, true);
        await new Promise<void>(res => setTimeout(res, 100));
      }
    }
  }

  async restartAllTask() {
    // 找出本地内存中所有处于 失败 或 停止 状态的任务
    const failedTasks = this.tasks.filter(d =>
    d.status === request.agent.State.FAILED ||
      d.status === request.agent.State.STOPPED
    );
    if (failedTasks.length === 0) return;

    logger.debug(`restartAllSysTask: 发现 ${failedTasks.length} 个失败/停止任务，开始批量重试`);
    // 遍历并直接调用单个重试逻辑
    for (const task of failedTasks) {
      try {
        // 复用完善后的单个重试方法
        await this.restartTask(task.task_id);
      } catch (e) {
        toastUtil.showToast({ message: `任务 ${task.title} 重试失败`})
        // 防止某一个任务重试时抛出异常中断了整个批量循环
        logger.error(`restartAllSysTask: 单个任务重试异常 task_id: ${task.task_id}, err: ${JSON.stringify(e)}`);
      }
    }
  }

  /** 清空所有已完成的任务 */
  async clearAllCompletedTasks() {
    // 筛选已完成任务
    const completedTasks = this.tasks.filter(d => d.status === request.agent.State.COMPLETED);
    if (completedTasks.length === 0) {
      logger.warn("clearAllCompletedTasks: 没有已完成的任务需要清理");
      return;
    }
    // 提取 ID
    const ids = completedTasks.map(task => task.task_id);
    // 调用底层删除
    await this.batchDeleteTasksByIds(ids);
  }

  async attachSysTask(id: string) {
    const task = await this.getSysTask(id);
    if (task) this.attachTask(task);
  }

  /** 添加 Pixiv 图片下载任务 */
  async addTask(context: common.Context, illustInfo: PixivIllust, url: string) {
    // 按 URL 检查该张图片是否已存在（同一作品的不同页允许同时入队）
    const existingTask = this.tasks.find(t => t.url === url);
    if (existingTask) {
      // 存在则弹窗询问，用 Promise 等待用户选择
      const shouldContinue = await new Promise<boolean>((resolve) => {
        toastUtil.showAlertDialog({
          title: '提示',
          message: `「${existingTask.title || '未知作品'}」已在下载列表中，是否继续下载？`,
          alignment: DialogAlignment.Center,
          primaryButton: {
            value: '继续下载',
            action: () => resolve(true)
          },
          secondaryButton: {
            value: '取消',
            action: () => resolve(false)
          }
        });
      });
      // 用户点了取消，直接 return
      if (!shouldContinue) return;
    }

    // 添加逻辑
    if (!this.downloadDir) await this.initDownLoad(context);
    const db = getDownloadRecordTable(context);
    const fileName = this._generateSafeFileName(illustInfo, url);
    const filePath = `${this.downloadDir}/${fileName}`;
    try {
      // 直连模式：系统下载服务无法自定义 DNS，入队时即改走 RCP 直连引擎（中途不切换引擎）
      if (networkModeManager.isDirectModeForHost(this.hostOf(url))) {
        await this.addDirectIllustTask(db, illustInfo, url, filePath);
        return;
      }
      let task = await request.agent.create(context, this.getTaskConfig(url, fileName, filePath));
      const record = new DownloadRecordInfo();
      record.task_id = task.tid;
      record.illust_id = illustInfo.id;
      record.title = illustInfo.title;
      record.artistName = illustInfo.user?.name;
      record.artist_avatar = illustInfo.user?.profile_image_urls?.medium;
      record.thumbnail = illustInfo.image_urls?.medium || illustInfo.image_urls?.large;
      record.filePath = filePath;
      record.url = url;
      record.status = request.agent.State.INITIALIZED;
      record.create_time = Date.now();
      await db.insert(record);
      this.tasks.unshift(record);
      toastUtil.showToast({ message: $r('app.string.download_now', illustInfo.title) });
      await this.attachTask(task);
      await this.TryRunTask(task);
    } catch (e) {
      logger.error("Add Task Error", e);
    }
  }

  /** 直连引擎入队：建记录、入列表，交给派发器按并发上限启动 */
  private async addDirectIllustTask(db: DownloadRecordTable, illustInfo: PixivIllust, url: string, filePath: string) {
    const record = new DownloadRecordInfo();
    record.task_id = `direct_${illustInfo.id}_${Date.now()}`;
    record.illust_id = illustInfo.id;
    record.title = illustInfo.title;
    record.artistName = illustInfo.user?.name ?? '';
    record.artist_avatar = illustInfo.user?.profile_image_urls?.medium ?? '';
    record.thumbnail = illustInfo.image_urls?.medium || illustInfo.image_urls?.large || '';
    record.filePath = filePath;
    record.url = url;
    record.status = request.agent.State.INITIALIZED;
    record.progress = 0;
    record.create_time = Date.now();
    await db.insert(record);
    this.tasks.unshift(record);
    toastUtil.showToast({ message: $r('app.string.download_now', illustInfo.title) });
    this.dispatchDirectTask(record);
  }

  private dispatchDirectTask(record: DownloadRecordInfo) {
    this.pendingDirectTasks.push(record);
    this.dispatchNextDirectTask();
  }

  /** 按并发上限派发直连任务（系统任务与直连任务统一计数） */
  private async dispatchNextDirectTask(): Promise<void> {
    if (this.pendingDirectTasks.length === 0) return;
    let sysRunningCount = 0;
    try {
      sysRunningCount = (await request.agent.search({ state: request.agent.State.RUNNING })).length;
    } catch (e) { /* 忽略：按 0 计 */ }
    const limit = Number(appSettings.max_download_count) || 1;
    while (this.pendingDirectTasks.length > 0 && this.activeDirectTaskIds.size + sysRunningCount < limit) {
      const next = this.pendingDirectTasks.shift();
      if (next) this.startDirectTask(next);
    }
  }

  private startDirectTask(record: DownloadRecordInfo) {
    const db = this.context ? getDownloadRecordTable(this.context) : null;
    record.status = request.agent.State.RUNNING;
    record.progress = 0;
    this.activeDirectTaskIds.add(record.task_id);
    db?.updateStatus(record.task_id, request.agent.State.RUNNING);
    directDownloader.download(record.url, record.filePath, (percent: number) => {
      record.progress = percent;
    }).then(async (ok: boolean) => {
      if (ok) {
        record.status = request.agent.State.COMPLETED;
        record.progress = 100;
        await db?.updateStatus(record.task_id, request.agent.State.COMPLETED);
      } else {
        record.status = request.agent.State.FAILED;
        await db?.updateStatus(record.task_id, request.agent.State.FAILED);
      }
      // 与系统下载器一致：作品全部页结束后统一触发相册批量保存
      await this.trySaveIllustGroup(record.illust_id);
    }).catch(async () => {
      record.status = request.agent.State.FAILED;
      await db?.updateStatus(record.task_id, request.agent.State.FAILED);
      await this.trySaveIllustGroup(record.illust_id);
    }).finally(() => {
      this.activeDirectTaskIds.delete(record.task_id);
      this.dispatchNextDirectTask();
      this.dispatchNextUgoiraTask();
    });
  }

  /** 从 URL 提取主机名（直连引擎选择用） */
  private hostOf(url: string): string {
    const match = url.match(/^https?:\/\/([^/:?#]+)/);
    return match ? match[1] : '';
  }

  /**
   * 添加动图下载任务：下载高清帧包 → 解压 → 逐帧解码 → 编码 GIF 落盘，
   * 完成后随作品组自动保存到相册。动图无单一原图 URL，不走 request.agent，
   * 全程 RCP 管线（直连模式由 DirectDownloader 注入 DNS 规则）。
   */
  async addUgoiraTask(context: common.Context, illustInfo: PixivIllust) {
    const existing = this.tasks.find(t => t.recordType === 'ugoira' && t.illust_id === illustInfo.id);
    if (existing) {
      const activeStates = [
        request.agent.State.INITIALIZED,
        request.agent.State.WAITING,
        request.agent.State.RUNNING,
        request.agent.State.RETRYING,
        request.agent.State.PAUSED
      ];
      if (activeStates.includes(existing.status)) {
        toastUtil.showToast({ message: `「${illustInfo.title}」已在下载列表中` });
        return;
      }
      if (existing.status === request.agent.State.COMPLETED) {
        toastUtil.showToast({ message: `「${illustInfo.title}」已下载过，可在下载管理中重新保存` });
        return;
      }
      // 失败任务直接重新入队
      this.dispatchUgoiraTask(existing);
      return;
    }

    if (!this.downloadDir) await this.initDownLoad(context);
    const db = getDownloadRecordTable(context);
    const fileName = this._generateSafeFileName(illustInfo, '', 'gif');
    const record = new DownloadRecordInfo();
    record.task_id = `ugoira_${illustInfo.id}_${Date.now()}`;
    record.illust_id = illustInfo.id;
    record.title = illustInfo.title;
    record.artistName = illustInfo.user?.name ?? '';
    record.artist_avatar = illustInfo.user?.profile_image_urls?.medium ?? '';
    record.thumbnail = illustInfo.image_urls?.medium || illustInfo.image_urls?.large || '';
    record.recordType = 'ugoira';
    record.filePath = `${this.downloadDir}/${fileName}`;
    record.url = '';
    record.status = request.agent.State.INITIALIZED;
    record.progress = 0;
    record.create_time = Date.now();
    await db.insert(record);
    this.tasks.unshift(record);
    toastUtil.showToast({ message: $r('app.string.download_now', illustInfo.title) });
    this.dispatchUgoiraTask(record);
  }

  /** 动图转码任务入队：并发上限与直连/系统任务统一计数 */
  private dispatchUgoiraTask(record: DownloadRecordInfo) {
    record.status = request.agent.State.INITIALIZED;
    record.progress = 0;
    this.pendingUgoiraTasks.push(record);
    this.dispatchNextUgoiraTask();
  }

  /** 按并发上限派发动图转码任务 */
  private async dispatchNextUgoiraTask(): Promise<void> {
    if (this.pendingUgoiraTasks.length === 0) return;
    let sysRunningCount = 0;
    try {
      sysRunningCount = (await request.agent.search({ state: request.agent.State.RUNNING })).length;
    } catch (e) { /* 忽略：按 0 计 */ }
    const limit = Number(appSettings.max_download_count) || 1;
    while (this.pendingUgoiraTasks.length > 0
      && this.activeDirectTaskIds.size + this.activeUgoiraTaskIds.size + sysRunningCount < limit) {
      const next = this.pendingUgoiraTasks.shift();
      if (next) this.runUgoiraPipeline(next);
    }
  }

  private runUgoiraPipeline(record: DownloadRecordInfo) {
    const db = this.context ? getDownloadRecordTable(this.context) : null;
    record.status = request.agent.State.RUNNING;
    record.progress = 0;
    this.activeUgoiraTaskIds.add(record.task_id);
    db?.updateStatus(record.task_id, request.agent.State.RUNNING);
    this.executeUgoiraPipeline(record).then(async () => {
      record.status = request.agent.State.COMPLETED;
      record.progress = 100;
      await db?.updateStatus(record.task_id, request.agent.State.COMPLETED);
      // 与图片一致：作品组全部到终态后统一触发相册保存（ugoira 记录天然在分组过滤内）
      await this.trySaveIllustGroup(record.illust_id);
    }).catch(async (e: Object) => {
      logger.error(`ugoira pipeline failed: ${getErrMsg(e)}`);
      record.status = request.agent.State.FAILED;
      await db?.updateStatus(record.task_id, request.agent.State.FAILED);
      await this.trySaveIllustGroup(record.illust_id);
    }).finally(() => {
      this.activeUgoiraTaskIds.delete(record.task_id);
      this.dispatchNextUgoiraTask();
    });
  }

  /**
   * 转码管线：元数据 → 1080 帧包下载（失败回退 600）→ 解压 → 逐帧解码（按总像素
   * 预算自适应缩放，防大帧数撑爆内存）→ ImagePacker 序列编码 GIF 落盘。
   * 进度：下载 5~60%，解码 60~90%，编码 90~100%。
   */
  private async executeUgoiraPipeline(record: DownloadRecordInfo): Promise<void> {
    if (!this.context) throw new Error('context not ready');
    const illustId = record.illust_id;

    record.progress = 2;
    const meta = await pixiv.getUgoiraMetadata(illustId);
    if (!meta?.zip_urls?.medium || !meta.frames || meta.frames.length === 0) {
      throw new Error('ugoira metadata incomplete');
    }

    const onProgress = (percent: number) => {
      record.progress = 5 + Math.floor(percent * 0.55);
    };
    let usedSize: UgoiraSize = '1920x1080';
    let frames: UgoiraFrames;
    try {
      frames = await ensureUgoiraFrames(this.context, illustId, meta, usedSize, onProgress);
    } catch (e) {
      logger.warn(`ugoira 1080 zip failed, fallback to 600x600: ${getErrMsg(e)}`);
      usedSize = '600x600';
      frames = await ensureUgoiraFrames(this.context, illustId, meta, usedSize, onProgress);
    }

    // 解首帧取尺寸（getImageInfo 不解码像素），计算总像素预算内的缩放
    const firstSource = image.createImageSource(frames.paths[0]);
    const imageInfo = await firstSource.getImageInfo();
    await firstSource.release();
    const frameW = imageInfo.size.width;
    const frameH = imageInfo.size.height;
    const totalBytes = frames.paths.length * frameW * frameH * 4;
    const scale = totalBytes <= UGOIRA_DECODE_BUDGET_BYTES
      ? 1
      : Math.sqrt(UGOIRA_DECODE_BUDGET_BYTES / totalBytes);
    const targetW = Math.max(1, Math.floor(frameW * scale));
    const targetH = Math.max(1, Math.floor(frameH * scale));

    const pixelMaps: image.PixelMap[] = [];
    try {
      for (let i = 0; i < frames.paths.length; i++) {
        const source = image.createImageSource(frames.paths[i]);
        const pm = await source.createPixelMap({ desiredSize: { width: targetW, height: targetH } });
        await source.release();
        pixelMaps.push(pm);
        record.progress = 60 + Math.floor(((i + 1) / frames.paths.length) * 30);
      }

      const packer = image.createImagePacker();
      const ops: image.PackingOptionsForSequence = {
        frameCount: pixelMaps.length,
        // GIF 帧延迟单位 10ms；Pixiv delay 为 ms；下限 2（=20ms）防止 0 值
        delayTimeList: frames.delays.map(d => Math.max(2, Math.round(d / 10))),
        disposalTypes: new Array(pixelMaps.length).fill(1),
        loopCount: 0,
      };
      const file = fs.openSync(record.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        await packer.packToFileFromPixelmapSequence(pixelMaps, file.fd, ops);
      } finally {
        fs.closeSync(file);
        await packer.release();
      }
    } finally {
      // 已解码帧及时释放原生内存
      for (const pm of pixelMaps) {
        try {
          await pm.release();
        } catch (e) { /* ignore */ }
      }
    }

    // 清理 1080 转码缓存；回退 600 转码时保留缓存供播放器复用（cacheDir 系统可回收）
    if (usedSize === '1920x1080') {
      await clearUgoiraFrames(this.context, illustId, usedSize);
    }
  }


  /**
   * 添加小说 TXT 记录：正文写入沙箱并登记到下载列表，然后通过系统下载目录接口导出。
   * 小说内容由接口生成而非 URL 下载，因此不走 request.agent，直接以已完成状态入库。
   */
  async addNovelTask(context: common.Context, novel: PixivNovel, text: string) {
    if (!this.downloadDir) await this.initDownLoad(context);
    const db = getDownloadRecordTable(context);
    const novelDir = `${context.filesDir}/Pixiv/Novels`;
    try {
      if (!fs.accessSync(novelDir)) fs.mkdirSync(novelDir, true);
      const fileName = this._generateSafeNovelFileName(novel);
      const filePath = `${novelDir}/${fileName}`;
      const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);

      // 同一本小说重复保存时复用已有记录，只重写沙箱文件并再次导出
      let record = this.tasks.find(t => t.recordType === 'novel' && t.illust_id === novel.id);
      if (!record) {
        record = new DownloadRecordInfo();
        record.task_id = `novel_${novel.id}_${Date.now()}`;
        record.illust_id = novel.id;
        record.title = novel.title;
        record.artistName = novel.user?.name;
        record.artist_avatar = novel.user?.profile_image_urls?.medium;
        record.thumbnail = novel.image_urls?.medium || novel.image_urls?.square_medium || '';
        record.recordType = 'novel';
        record.filePath = filePath;
        record.status = request.agent.State.COMPLETED;
        record.progress = 100;
        record.create_time = Date.now();
        const rowId = await db.insert(record);
        record.id = rowId;
        this.tasks.unshift(record);
      } else {
        // 修复旧版本遗留的空路径记录（文件名由小说 id 决定，重复保存路径不变）
        record.filePath = filePath;
        record.status = request.agent.State.COMPLETED;
        record.progress = 100;
        await db.update(record);
      }
      await this.saveNovelToDevice(record);
    } catch (e) {
      logger.error("Add Novel Task Error", e);
      toastUtil.showToast({ message: '保存失败' });
    }
  }

  /** 通过系统下载目录（DOWNLOAD 模式）将小说 TXT 导出到公共 Download/包名/ 目录 */
  async saveNovelToDevice(record: DownloadRecordInfo) {
    if (!this.context) return;
    if (!this.isFileInSandbox(record.filePath)) {
      toastUtil.showToast({ message: "文件不存在或已保存" });
      return;
    }
    const fileName = record.filePath.substring(record.filePath.lastIndexOf('/') + 1);
    let targetPath = '';
    try {
      // DOWNLOAD 模式跳过文件选择界面，直接在 Download/包名/ 下保存，
      // save() 返回的是该目录的 URI（具备持久化权限），newFileNames 等参数不生效
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
      const documentViewPicker = new picker.DocumentViewPicker(this.context);
      const saveResult: Array<string> = await documentViewPicker.save(documentSaveOptions);
      if (!saveResult || saveResult.length === 0) {
        logger.warn("saveNovelToDevice: save 返回为空");
        return;
      }
      targetPath = new fileUri.FileUri(`${saveResult[0]}/${fileName}`).path;
      fs.copyFileSync(record.filePath, targetPath);
      // 导出成功后清理沙箱文件，与图片保存流程保持一致
      await this.deleteFile(record.filePath);
      toastUtil.showToast({ message: `已保存「${record.title || '未命名小说'}」到下载目录` });
      this.refreshDisplayList();
    } catch (e) {
      // 真机出现过误报：内容已完整写入 Download/包名/ 后，copyFileSync 仍抛 13900001
      // （copy_file.cpp IsAllPath）。以目标文件实际存在且非空为准，避免把成功报成失败
      let savedAnyway = false;
      if (targetPath !== '') {
        try {
          savedAnyway = fs.statSync(targetPath).size > 0;
        } catch (err) {
          savedAnyway = false;
        }
      }
      if (savedAnyway) {
        logger.warn("saveNovelToDevice: copyFileSync 抛错但目标文件已写入，按成功处理");
        await this.deleteFile(record.filePath);
        toastUtil.showToast({ message: `已保存「${record.title || '未命名小说'}」到下载目录` });
        this.refreshDisplayList();
        return;
      }
      logger.error(`saveNovelToDevice failed, code: ${e.code}, message: ${e.message}`);
      toastUtil.showToast({ message: '保存到下载目录失败' });
    }
  }

  /** 纯函数：生成小说 TXT 文件名 */
  private _generateSafeNovelFileName(novel: PixivNovel): string {
    const safeTitle = (novel.title || `novel_${novel.id}`)
      .replace(/[\\/:*?"<>|.]+/g, '_')
      .trim()
      .replace(/\s+/g, ' ')
      .replace(/^_|_$/g, '') || `novel_${novel.id}`;
    return `${safeTitle}_${novel.id}.txt`;
  }


  private async getSysTask(id: string | undefined): Promise<request.agent.Task | undefined> {
    if (!id || !this.context) return undefined;
    try {
      return await request.agent.getTask(this.context, id);
    } catch (e) {
      return undefined;
    }
  }

  // 丢失任务重建
  private async recreateLostTask(record: DownloadRecordInfo) {
    if (!record.url || !this.context) {
      record.status = request.agent.State.FAILED;
      return;
    }
    // 直连引擎任务：重走直连下载
    if (record.task_id.startsWith('direct_')) {
      logger.info(`restartTask: 直连任务重建: ${record.url}`);
      record.status = request.agent.State.INITIALIZED;
      record.progress = 0;
      const db = getDownloadRecordTable(this.context);
      await db.update(record);
      this.dispatchDirectTask(record);
      return;
    }
    // 动图转码任务：重跑整条管线
    if (record.task_id.startsWith('ugoira_')) {
      logger.info(`restartTask: 动图转码任务重建: ${record.title}`);
      const db = getDownloadRecordTable(this.context);
      await db.update(record);
      this.dispatchUgoiraTask(record);
      return;
    }
    logger.info(`restartTask: 系统任务丢失, 使用链接重建: ${record.url}`);

    try {
      const db = getDownloadRecordTable(this.context);
      const fileName = record.filePath ? record.filePath.substring(record.filePath.lastIndexOf('/') + 1) : `pixiv_${Date.now()}`;
      const filePath = record.filePath || `${this.downloadDir}/${fileName}`;

      const newTask = await request.agent.create(this.context, this.getTaskConfig(record.url, fileName, filePath));

      record.task_id = newTask.tid;
      record.status = request.agent.State.INITIALIZED;
      record.progress = 0;
      await db.update(record);

      await this.attachTask(newTask);
      await this.TryRunTask(newTask);
    } catch (e) {
      logger.error(`restartTask: 重建失败. ${JSON.stringify(e)}`);
      record.status = request.agent.State.FAILED;
    }
  }

  private async attachTask(task: request.agent.Task) {
    if (!this.context) return;
    this.unAttackTask(task);
    const db = getDownloadRecordTable(this.context);

    task.on('progress', (progress) => {
      const target = this.tasks.find(d => d.task_id === task.tid);
      if (target && progress.sizes && progress.sizes.length > 0) {
        const total = progress.sizes[0];
        if (total > 0) target.progress = Math.floor((progress.processed / total) * 100);
      }
    });

    task.on('completed', async () => {
      const target = this.tasks.find(d => d.task_id === task.tid);
      if (target) {
        target.status = request.agent.State.COMPLETED;
        target.progress = 100;
        await db.updateStatus(task.tid, request.agent.State.COMPLETED);
        // 等同作品所有页下载结束后，合并为一次授权弹窗批量保存
        await this.trySaveIllustGroup(target.illust_id);
      }
      this.TryRunNextTask();
    });

    task.on('pause', () => {
      const target = this.tasks.find(d => d.task_id === task.tid);
      if (target) target.status = request.agent.State.PAUSED;
      db.updateStatus(task.tid, request.agent.State.PAUSED);
      this.TryRunNextTask();
    });

    task.on('resume', () => {
      const target = this.tasks.find(d => d.task_id === task.tid);
      if (target) target.status = request.agent.State.RUNNING;
      db.updateStatus(task.tid, request.agent.State.RUNNING);
    });

    task.on('failed', async () => {
      const target = this.tasks.find(d => d.task_id === task.tid);
      if (target) target.status = request.agent.State.FAILED;
      await db.updateStatus(task.tid, request.agent.State.FAILED);
      // 部分页失败时，若其余页均已终态，把已完成的页批量保存（一次弹窗）
      if (target) await this.trySaveIllustGroup(target.illust_id);
      this.TryRunNextTask();
    });

    task.on('remove', () => {
      this.tasks = this.tasks.filter(d => d.task_id !== task.tid);
      this.TryRunNextTask();
    });
  }

  private async TryRunNextTask() {
    // 系统任务结束后腾出的并发额度，同样供待派发的动图转码任务使用
    this.dispatchNextUgoiraTask();
    const waiting = await request.agent.search({ state: request.agent.State.INITIALIZED });
    if (waiting.length === 0) return;
    const sysTask = await this.getSysTask(waiting.pop());
    if (sysTask) {
      const started = await this.TryRunTask(sysTask);
      if (started) {
        const target = this.tasks.find(d => d.task_id === sysTask.tid);
        if (target) target.status = request.agent.State.RUNNING;
      }
    }
  }

  private async TryRunTask(task: request.agent.Task, resume: boolean = false) {
    const running = await request.agent.search({ state: request.agent.State.RUNNING });
    // 并发上限对系统任务与直连任务统一计数，避免两条链路加起来超限
    if (running.length + this.activeDirectTaskIds.size < Number(appSettings.max_download_count)) {
      resume ? await task.resume() : await task.start();
      return true;
    }
    return false;
  }

  private unAttackTask(task: request.agent.Task) {
    task.off('progress'); task.off('completed'); task.off('failed');
    task.off('pause'); task.off('resume'); task.off('remove');
  }

  /**
   * 按作品分组保存：当同一作品的所有下载任务均到达终态（完成/失败/停止）后，
   * 将其中已完成且沙箱文件仍存在的图片合并为一次 showAssetsCreationDialog 授权弹窗批量保存。
   * 仍有任务处于排队/下载中/暂停时不触发，等最后一页结束后再统一处理。
   */
  private async trySaveIllustGroup(illustId: number | undefined) {
    if (illustId === undefined || illustId === null || this.savingIllustIds.has(illustId)) return;
    // 只统计插画记录，避免小说记录（illust_id 存的是小说 id）被误归组保存到相册
    const group = this.tasks.filter(d => d.illust_id === illustId && d.recordType !== 'novel');
    if (group.length === 0) return;

    const activeStates = [
      request.agent.State.INITIALIZED,
      request.agent.State.WAITING,
      request.agent.State.RUNNING,
      request.agent.State.RETRYING,
      request.agent.State.PAUSED
    ];
    // 还有页未结束（含暂停，用户可能恢复下载），暂不保存
    if (group.some(d => activeStates.includes(d.status))) return;

    const readyItems: GallerySaveItem[] = group
      .filter(d => d.status === request.agent.State.COMPLETED && this.isFileInSandbox(d.filePath))
      .map(d => ({ filePath: d.filePath as string, title: d.title || '未命名作品' } as GallerySaveItem));
    if (readyItems.length === 0) return;

    this.savingIllustIds.add(illustId);
    try {
      await this.saveImagesToGallery(readyItems);
    } finally {
      this.savingIllustIds.delete(illustId);
    }
  }

  /** 将单个沙箱文件保存到系统相册（内部复用批量保存） */
  private async saveImageToGallery(localPath: string, title: string) {
    if (!localPath || !this.context) return;
    await this.saveImagesToGallery([{ filePath: localPath, title: title } as GallerySaveItem]);
  }

  /** 将多个沙箱文件一次性保存到系统相册，只弹一次授权弹窗 */
  private async saveImagesToGallery(items: Array<GallerySaveItem>) {
    if (!this.context || items.length === 0) return;

    try {
      // 过滤出沙箱中真实存在的文件
      const validItems = items.filter(item => item.filePath && this.isFileInSandbox(item.filePath));
      if (validItems.length === 0) return;

      const phAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const srcUris: string[] = [];
      const configs: Array<photoAccessHelper.PhotoCreationConfig> = [];
      for (const item of validItems) {
        const fileName = item.filePath.substring(item.filePath.lastIndexOf('/') + 1);
        const dotIndex = fileName.lastIndexOf('.');
        let safeTitle = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
        const extension = dotIndex > 0 ? fileName.substring(dotIndex + 1) : 'jpg';
        // 系统媒体库对相册标题有字符黑名单（CheckTitleCompatible）：. \ / : * ? " ' ` < > | { } [ ]
        // 命中后 showAssetsCreationDialog 弹窗直接中止且 Promise 挂起（真机日志：
        // Title contains invalid characters → CloseModalUIExtension），统一替换为下划线
        safeTitle = safeTitle.replace(/[.\\\/:*?"'`<>|{}\[\]]+/g, '_').replace(/_{2,}/g, '_');
        srcUris.push(fileUri.getUriFromPath(item.filePath));
        configs.push({
          title: safeTitle,
          fileNameExtension: extension,
          photoType: photoAccessHelper.PhotoType.IMAGE,
          subtype: photoAccessHelper.PhotoSubtype.DEFAULT
        });
      }
      logger.info(`[SaveDebug] 准备批量保存 ${srcUris.length} 张图片, 调起 showAssetsCreationDialog...`);
      // 一次弹窗授权所有图片
      const desFileUris = await phAccessHelper.showAssetsCreationDialog(srcUris, configs);
      logger.info(`[SaveDebug] 弹窗返回结果: ${JSON.stringify(desFileUris)}`);
      if (desFileUris && desFileUris.length > 0) {
        // 逐个拷贝，任一张失败则跳过该张继续，其余不受影响
        let savedCount = 0;
        for (let i = 0; i < validItems.length && i < desFileUris.length; i++) {
          try {
            const srcFd = fs.openSync(validItems[i].filePath, fs.OpenMode.READ_ONLY);
            const destFd = await fs.open(desFileUris[i], fs.OpenMode.WRITE_ONLY);
            await fs.copyFile(srcFd.fd, destFd.fd);
            fs.closeSync(srcFd);
            await fs.close(destFd.fd);
            await this.deleteFile(validItems[i].filePath);
            savedCount++;
          } catch (e) {
            logger.error(`[SaveDebug] 拷贝第 ${i} 张失败: ${JSON.stringify(e)}`);
          }
        }
        if (savedCount > 0) {
          toastUtil.showToast({ message: savedCount === 1
            ? `已保存 ${validItems[0].title || '未命名作品'}`
            : `已保存 ${savedCount} 张图片到相册` });
        }
      } else {
        // 用户点击取消，或者弹窗莫名返回空数组
        logger.warn(`[SaveDebug] 弹窗返回为空，大概率是用户取消了保存`);
      }
    } catch (e) {
      logger.error(`[SaveDebug] ❌ 发生异常！错误码: ${e.code}, 错误信息: ${e.message}`);
      logger.error(`[SaveDebug] 完整错误堆栈: ${JSON.stringify(e)}`);
    }
  }

  private async removeTask(task: DownloadRecordInfo) {
    if (!this.context) return;
    const db = getDownloadRecordTable(this.context);
    try { await request.agent.remove(task.task_id); } catch (e) { /* ignore */ }
    await this.deleteFile(task.filePath);
    if (task.id) await db.deleteByID(task.id);
    this.tasks = this.tasks.filter(f => f.task_id !== task.task_id);
  }

  private async deleteFile(filePath: string | undefined) {
    if (!filePath) return;
    try {
      if (fs.accessSync(filePath)) await fs.unlink(filePath);
    } catch (e) {
      logger.warn("Delete file failed", e);
    }
  }

  /**
   * @param ids 待删除的任务ID列表
   * 底层辅助函数：根据 任务ID 列表批量删除任务
   * 只负责删文件、删数据库、更新内存列表
   */
  private async batchDeleteTasksByIds(ids: string[]) {
    if (ids.length === 0) return;

    logger.info(`batchDeleteTasksByIds: 开始批量删除 ${ids.length} 个任务`);

    for (const id of ids) {
      const task = this.tasks.find(d => d.task_id === id);
      if (task) {
        try {
          // 复用单条删除（里面包含了删系统任务、删文件、删DB、更新 this.tasks）
          await this.removeTask(task);
        } catch (e) {
          logger.error(`batchDeleteTasksByIds: 删除任务失败 id: ${id}, err:${JSON.stringify(e)}`);
        }
      }
    }
  }

  /** 提取公共的下载任务配置 */
  private getTaskConfig(url: string, fileName: string, filePath: string): request.agent.Config {
    return {
      action: request.agent.Action.DOWNLOAD,
      url: url,
      title: fileName,
      saveas: filePath,
      headers: this.PIXIV_HEADERS,
      retry: true,
      gauge: true,
      mode: request.agent.Mode.BACKGROUND,
      overwrite: true,
    };
  }

  /** 纯函数：仅负责生成文件名（extOverride 用于动图等 URL 后缀不等于目标格式的场景） */
  private _generateSafeFileName(illustInfo: PixivIllust, url: string, extOverride?: string): string {
    // 获取后缀名
    const extension = extOverride || url.split('.').pop() || 'jpg';
    // 只提取页码数字部分（如 _p0 → "0"，_p12 → "12"）
    const pageMatch = url.match(/_p(\d+)/);

    // 提取并安全化各个字段
    const safeIllustId = `${illustInfo.id}`;
    const safePart = pageMatch ? pageMatch[1] : '0'; // 纯数字，单图默认 "0"
    const safeUid = `${illustInfo.user?.id || '0'}`;

    // 安全过滤：去除非法字符和点号，保留空格
    const safeTitle = (illustInfo.title || 'Untitled')
      .replace(/[\\/:*?"<>|.]+/g, '_')
      .trim()
      .replace(/\s+/g, ' ')
      .replace(/^_|_$/g, '');
    const safeUserName = (illustInfo.user?.name || 'Pixiv')
      .replace(/[\\/:*?"<>|.]+/g, '_')
      .trim()
      .replace(/\s+/g, ' ')
      .replace(/^_|_$/g, '');

    // 读取模板，为空则使用默认模板
    const template = appSettings.file_name.trim() || '{illust_id}_p{part}_{title}_{user_name}';

    // 执行占位符替换
    let fileName = template
      .replace(/{illust_id}/g, safeIllustId)
      .replace(/{part}/g, safePart)
      .replace(/{title}/g, safeTitle)
      .replace(/{user_name}/g, safeUserName)
      .replace(/{uid}/g, safeUid);

    // 兜底防错（防止用户在设置页瞎填一堆非法字符导致替换完为空）
    if (!fileName || fileName.trim() === '') {
      fileName = `pixiv_${safeIllustId}_p${safePart}`;
    }

    return `${fileName}.${extension}`;
  }

}

export const downloaderVM = new DownloadsViewModel();

function getErrMsg(e: Object): string {
  const err = e as Error
  return err?.message ?? String(e)
}

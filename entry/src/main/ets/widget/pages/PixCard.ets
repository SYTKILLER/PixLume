let storage = new LocalStorage();

/**
 * 灵感图卡 2x2：整卡显示一张随机作品图，右下角刷新按钮重新随机。
 * 点击按钮以外区域 router 到 EntryAbility，由主进程跳转到对应作品详情页。
 */
@Entry(storage)
@Component
struct PixCard {
  // ok=正常展示 / empty=暂无图 / need_login=未登录 / error=刷新失败（保留旧图）
  @LocalStorageProp('state') state: string = 'empty'
  @LocalStorageProp('loaded') loaded: boolean = false
  @LocalStorageProp('imgName') imgName: string = ''
  @LocalStorageProp('illustId') illustId: number = 0
  @LocalStorageProp('target') target: string = 'illust_detail'

  private hintText(): ResourceStr {
    if (this.state === 'need_login') {
      return $r('app.string.widget_need_login')
    }
    if (this.state === 'empty') {
      return $r('app.string.widget_empty')
    }
    return $r('app.string.widget_refresh_failed')
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      // 层1：整卡背景图（点击跳详情）
      Column() {
        if (this.state !== 'ok') {
          Text(this.hintText())
            .fontSize(13)
            .fontColor('#FFFFFF')
            .opacity(0.92)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor('rgba(0,0,0,0.35)')
            .borderRadius(10)
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundImage(this.loaded && this.imgName !== '' ? 'memory://' + this.imgName : $r('app.media.widget_placeholder'))
      .backgroundImageSize(ImageSize.Cover)
      .onClick(() => {
        if (this.illustId > 0) {
          postCardAction(this, {
            action: 'router',
            abilityName: 'EntryAbility',
            params: {
              'target': this.target,
              'id': this.illustId
            }
          })
        } else {
          postCardAction(this, {
            action: 'router',
            abilityName: 'EntryAbility'
          })
        }
      })

      // 层2：刷新按钮（Stack 兄弟节点，位于最上层，命中不会穿透到层1）
      Image($r('app.media.widget_refresh'))
        .width(30)
        .height(30)
        .padding(6)
        .backgroundColor('rgba(0,0,0,0.30)')
        .borderRadius(15)
        .margin(8)
        .onClick(() => {
          postCardAction(this, {
            action: 'message',
            params: {
              'event': 'refresh'
            }
          })
        })
    }
    .width('100%')
    .height('100%')
  }
}

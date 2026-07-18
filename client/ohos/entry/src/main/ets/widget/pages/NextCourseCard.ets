@Entry
@Component
struct NextCourseCard {
  @LocalStorageProp('title') title: string = '下一节课';
  @LocalStorageProp('subtitle') subtitle: string = '';
  @LocalStorageProp('emptyText') emptyText: string = '今天没有课程';
  @LocalStorageProp('lineCount') lineCount: number = 0;
  @LocalStorageProp('line1Title') lineTitle: string = '';
  @LocalStorageProp('line1Primary') linePrimary: string = '';
  @LocalStorageProp('line1Secondary') lineSecondary: string = '';
  @LocalStorageProp('line1Badge') lineBadge: string = '';
  @LocalStorageProp('route') route: string = 'campus://timetable';

  private openTargetPage(): void {
    // 动态服务卡片必须通过 postCardAction 拉起 UIAbility。
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { homeCardRoute: this.route },
    });
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182230')
        Blank()
        Text(this.lineBadge)
          .fontSize(11)
          .fontColor('#2563EB')
      }
      .width('100%')

      Text(this.subtitle)
        .fontSize(11)
        .fontColor('#667085')
        .margin({ top: 3 })
        .width('100%')

      if (this.lineCount === 0) {
        Column() {
          Text(this.emptyText)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#475467')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        Column() {
          Text(this.lineTitle)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#101828')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.linePrimary)
            .fontSize(14)
            .fontColor('#2563EB')
            .margin({ top: 6 })
            .width('100%')
          Text(this.lineSecondary)
            .fontSize(12)
            .fontColor('#667085')
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .padding(14)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .onClick(() => this.openTargetPage())
  }
}

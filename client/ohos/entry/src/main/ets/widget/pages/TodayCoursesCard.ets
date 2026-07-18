@Entry
@Component
struct TodayCoursesCard {
  @LocalStorageProp('title') title: string = '今日课程';
  @LocalStorageProp('subtitle') subtitle: string = '';
  @LocalStorageProp('emptyText') emptyText: string = '今天没有课程';
  @LocalStorageProp('lineCount') lineCount: number = 0;
  @LocalStorageProp('line1Title') line1Title: string = '';
  @LocalStorageProp('line1Primary') line1Primary: string = '';
  @LocalStorageProp('line1Secondary') line1Secondary: string = '';
  @LocalStorageProp('line1Badge') line1Badge: string = '';
  @LocalStorageProp('line2Title') line2Title: string = '';
  @LocalStorageProp('line2Primary') line2Primary: string = '';
  @LocalStorageProp('line2Secondary') line2Secondary: string = '';
  @LocalStorageProp('line2Badge') line2Badge: string = '';
  @LocalStorageProp('line3Title') line3Title: string = '';
  @LocalStorageProp('line3Primary') line3Primary: string = '';
  @LocalStorageProp('line3Secondary') line3Secondary: string = '';
  @LocalStorageProp('line3Badge') line3Badge: string = '';
  @LocalStorageProp('line4Title') line4Title: string = '';
  @LocalStorageProp('line4Primary') line4Primary: string = '';
  @LocalStorageProp('line4Secondary') line4Secondary: string = '';
  @LocalStorageProp('line4Badge') line4Badge: string = '';
  @LocalStorageProp('route') route: string = 'campus://timetable';

  private openTargetPage(): void {
    // 动态服务卡片必须通过 postCardAction 拉起 UIAbility。
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { homeCardRoute: this.route },
    });
  }

  @Builder
  courseRow(title: string, primary: string, secondary: string, badge: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor('#101828')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(secondary.length > 0 ? secondary : primary)
          .fontSize(11)
          .fontColor('#667085')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(primary)
        .fontSize(12)
        .fontColor('#2563EB')
        .margin({ left: 8 })
      Text(badge)
        .fontSize(10)
        .fontColor('#475467')
        .margin({ left: 8 })
    }
    .height(42)
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#182230')
        Blank()
        Text(this.subtitle)
          .fontSize(11)
          .fontColor('#667085')
      }
      .width('100%')
      .margin({ bottom: 5 })

      if (this.lineCount === 0) {
        Text(this.emptyText)
          .fontSize(15)
          .fontColor('#475467')
          .layoutWeight(1)
      } else {
        if (this.lineCount > 0) {
          this.courseRow(this.line1Title, this.line1Primary, this.line1Secondary, this.line1Badge)
        }
        if (this.lineCount > 1) {
          this.courseRow(this.line2Title, this.line2Primary, this.line2Secondary, this.line2Badge)
        }
        if (this.lineCount > 2) {
          this.courseRow(this.line3Title, this.line3Primary, this.line3Secondary, this.line3Badge)
        }
        if (this.lineCount > 3) {
          this.courseRow(this.line4Title, this.line4Primary, this.line4Secondary, this.line4Badge)
        }
      }
    }
    .padding(14)
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => this.openTargetPage())
  }
}

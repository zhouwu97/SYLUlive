interface ScheduleRow { title: string; detail: string }

@Entry
@Component
struct ScheduleCard {
  @LocalStorageProp('kind') kind: string = 'course';
  @LocalStorageProp('title') title: string = '';
  @LocalStorageProp('subtitle') subtitle: string = '';
  @LocalStorageProp('rows') rows: ScheduleRow[] = [];
  @LocalStorageProp('empty') empty: string = '';
  @LocalStorageProp('background') cardBackground: string = '#FFFFFF';
  @LocalStorageProp('primary') primary: string = '#111827';
  @LocalStorageProp('secondary') secondary: string = '#4B5563';
  @LocalStorageProp('textSize') textSize: number = 14;

  build() {
    Column({ space: 4 }) {
      Text(this.title).fontColor(this.primary).fontSize(16).fontWeight(FontWeight.Bold).maxLines(1)
      Text(this.subtitle).fontColor(this.secondary).fontSize(12).opacity(0.72)
      if (this.rows.length === 0) {
        Text(this.empty).fontColor(this.primary).fontSize(this.textSize).margin({ top: 8 })
      } else {
        ForEach(this.rows.slice(0, 2), (row: ScheduleRow) => {
          Column() {
            Text(row.title).fontColor(this.primary).fontSize(this.textSize).fontWeight(FontWeight.Medium).maxLines(1)
            Text(row.detail).fontColor(this.secondary).fontSize(11).maxLines(1).opacity(0.76)
          }.alignItems(HorizontalAlign.Start)
        })
      }
    }.width('100%').height('100%').padding(12).alignItems(HorizontalAlign.Start)
    .backgroundColor(this.cardBackground)
    .onClick(() => {
      postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { scheduleKind: this.kind } });
    })
  }
}

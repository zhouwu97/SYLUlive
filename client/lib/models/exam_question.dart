/// 题库提取 - 单道题目数据模型
class ExamQuestion {
  final String? id;
  final int index;
  final String question;
  final String questionType;
  final String? chapter;
  final List<ExamOption> options;
  final String? answer;
  final String? analysis;
  final String? score;

  ExamQuestion({
    this.id,
    required this.index,
    required this.question,
    required this.questionType,
    this.chapter,
    required this.options,
    this.answer,
    this.analysis,
    this.score,
  });

  factory ExamQuestion.fromJson(Map<String, dynamic> json) {
    return ExamQuestion(
      id: json['id'] as String?,
      index: (json['index'] as num?)?.toInt() ?? 0,
      question: json['question'] as String? ?? '',
      questionType: json['questionType'] as String? ?? '',
      chapter: json['chapter'] as String?,
      options: (json['options'] as List<dynamic>?)
              ?.map((e) => ExamOption.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      answer: json['answer'] as String?,
      analysis: json['analysis'] as String?,
      score: json['score']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'index': index,
        'question': question,
        'questionType': questionType,
        'chapter': chapter,
        'options': options.map((e) => e.toJson()).toList(),
        'answer': answer,
        'analysis': analysis,
        'score': score,
      };
}

class ExamOption {
  final String label;
  final String text;

  ExamOption({required this.label, required this.text});

  factory ExamOption.fromJson(Map<String, dynamic> json) => ExamOption(
        label: json['label'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'label': label, 'text': text};
}

/// JSON → Markdown 转换器
class ExamMarkdownConverter {
  final bool includeToc;
  final bool includeStats;
  final bool markCorrectAnswers;
  final bool groupByChapter;

  ExamMarkdownConverter({
    this.includeToc = true,
    this.includeStats = true,
    this.markCorrectAnswers = true,
    this.groupByChapter = true,
  });

  String convert(List<ExamQuestion> questions) {
    final buf = StringBuffer();

    // 标题
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_pad(now.month)}-${_pad(now.day)} ${_pad(now.hour)}:${_pad(now.minute)}';
    buf.writeln('# 练习题整理');
    buf.writeln();
    buf.writeln('> 生成时间：$timestamp');
    buf.writeln('> 题目总数：${questions.length} 题');
    buf.writeln();

    // 统计
    if (includeStats) {
      buf.writeln(_buildStatistics(questions));
    }

    // 目录
    if (includeToc && questions.length > 10) {
      buf.writeln(_buildToc(questions));
    }

    // 题目
    buf.writeln('## 📝 题目详情');
    buf.writeln();

    if (groupByChapter) {
      final chapters = <String, List<ExamQuestion>>{};
      for (final q in questions) {
        chapters.putIfAbsent(q.chapter ?? '未分类', () => []).add(q);
      }
      for (final chapter in chapters.keys.toList()..sort()) {
        if (chapters.length > 1) {
          buf.writeln('## 📚 $chapter');
          buf.writeln();
        }
        for (final q in chapters[chapter]!) {
          buf.writeln(_formatQuestion(q));
        }
      }
    } else {
      for (final q in questions) {
        buf.writeln(_formatQuestion(q));
      }
    }

    return buf.toString();
  }

  String _buildStatistics(List<ExamQuestion> questions) {
    final buf = StringBuffer();
    buf.writeln('## 📊 统计信息');
    buf.writeln();
    buf.writeln('- **总题数：** ${questions.length} 题');

    // 题型统计
    final typeCount = <String, int>{};
    final typeScore = <String, double>{};
    for (final q in questions) {
      final type = q.questionType.isNotEmpty ? q.questionType : '未知';
      typeCount[type] = (typeCount[type] ?? 0) + 1;
      typeScore[type] = (typeScore[type] ?? 0) + (double.tryParse(q.score ?? '0') ?? 0);
    }

    buf.writeln();
    buf.writeln('### 题型分布：');
    for (final type in typeCount.keys.toList()..sort()) {
      buf.writeln('- **$type：** ${typeCount[type]} 题（${typeScore[type]} 分）');
    }

    final totalScore = typeScore.values.fold(0.0, (a, b) => a + b);
    buf.writeln();
    buf.writeln('- **总分值：** $totalScore 分');

    buf.writeln();
    buf.writeln('---');
    buf.writeln();
    return buf.toString();
  }

  String _buildToc(List<ExamQuestion> questions) {
    final buf = StringBuffer();
    buf.writeln('## 📑 目录');
    buf.writeln();

    final chapters = <String, List<ExamQuestion>>{};
    for (final q in questions) {
      chapters.putIfAbsent(q.chapter ?? '未分类', () => []).add(q);
    }
    for (final chapter in chapters.keys.toList()..sort()) {
      if (chapter.isNotEmpty) {
        buf.writeln('#### $chapter');
        for (final q in chapters[chapter]!) {
          final title = q.question.length > 50
              ? '${q.question.substring(0, 50)}...'
              : q.question;
          buf.writeln('- ${q.index}. 【${q.questionType}】 $title');
        }
        buf.writeln();
      }
    }
    buf.writeln('---');
    buf.writeln();
    return buf.toString();
  }

  String _formatQuestion(ExamQuestion q) {
    final buf = StringBuffer();

    // 标题行
    var title = '### ${q.index}. ';
    if (q.questionType.isNotEmpty) title += '【${q.questionType}】';
    if (q.score != null && q.score!.isNotEmpty) title += '（${q.score}分）';
    buf.writeln(title);
    buf.writeln();

    if (q.chapter != null && q.chapter!.isNotEmpty) {
      buf.writeln('**章节：** ${q.chapter}');
      buf.writeln();
    }

    buf.writeln('**题目：**');
    buf.writeln(q.question);
    buf.writeln();

    if (q.options.isNotEmpty) {
      buf.writeln('**选项：**');
      for (final opt in q.options) {
        final isCorrect = markCorrectAnswers &&
            q.answer != null &&
            q.answer!.contains(opt.label);
        if (isCorrect) {
          buf.writeln('- **${opt.label}. ${opt.text}** ✓');
        } else {
          buf.writeln('- ${opt.label}. ${opt.text}');
        }
      }
      buf.writeln();
    }

    if (q.answer != null && q.answer!.isNotEmpty) {
      buf.writeln('**答案：** ${q.answer}');
      buf.writeln();
    }

    if (q.analysis != null && q.analysis!.trim().isNotEmpty) {
      buf.writeln('**解析：**');
      buf.writeln(q.analysis);
      buf.writeln();
    }

    buf.writeln('---');
    buf.writeln();
    return buf.toString();
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

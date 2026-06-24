import 'package:flutter/material.dart';
import 'evaluation_automation_models.dart';
import 'evaluation_automation_controller.dart';

class EvaluationAutomationBar extends StatelessWidget {
  final EvaluationAutomationController controller;

  const EvaluationAutomationBar({
    super.key,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final progress = controller.progress;
        final state = progress.state;
        final isDark = Theme.of(context).brightness == Brightness.dark;

        if (state == EvaluationAutomationState.idle ||
            state == EvaluationAutomationState.completed ||
            state == EvaluationAutomationState.failed ||
            state == EvaluationAutomationState.stopped) {
          return _buildIdleBar(context, progress, isDark);
        }

        return _buildRunningBar(context, progress, isDark);
      },
    );
  }

  Widget _buildIdleBar(BuildContext context, EvaluationAutomationProgress progress, bool isDark) {
    final state = progress.state;
    String statusText = '空闲';
    Color statusColor = isDark ? Colors.white70 : Colors.black87;

    if (state == EvaluationAutomationState.completed) {
      statusText = progress.message ?? '已完成';
      statusColor = Colors.green;
    } else if (state == EvaluationAutomationState.failed) {
      statusText = progress.message ?? '发生错误: ${progress.error}';
      statusColor = Colors.red;
    } else if (state == EvaluationAutomationState.stopped) {
      statusText = progress.message ?? '已手动停止';
      statusColor = Colors.orange;
    }

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[900] : Colors.white,
          border: Border(
            top: BorderSide(
              color: isDark ? Colors.grey[800]! : Colors.grey[300]!,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    statusText,
                    style: TextStyle(color: statusColor, fontWeight: FontWeight.bold),
                  ),
                ),
                if (progress.completedCount > 0)
                  Text(
                    '已处理: ${progress.completedCount} 项',
                    style: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[600], fontSize: 12),
                  ),
              ],
            ),
            if (progress.error != null) ...[
              const SizedBox(height: 4),
              Text(
                progress.error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => controller.fillAndSaveCurrent(),
                    child: const Text('填写并保存当前'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      final confirm = await _showConfirmDialog(context, isDark);
                      if (confirm == true) {
                        controller.startBatch();
                      }
                    },
                    child: const Text('自动完成待评'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunningBar(BuildContext context, EvaluationAutomationProgress progress, bool isDark) {
    final isPaused = progress.state == EvaluationAutomationState.paused;
    final isPauseRequested = progress.pauseRequested;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.grey[900] : Colors.white,
          border: Border(
            top: BorderSide(
              color: isDark ? Colors.grey[800]! : Colors.grey[300]!,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${progress.completedCount} 项已处理 ${progress.currentItemLabel != null ? '- ${progress.currentItemLabel}' : ''}',
                    style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (!isPaused && !isPauseRequested)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (!isPaused && !isPauseRequested)
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    progress.message ?? '运行中...',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.grey[400] : Colors.grey[600],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (isPaused)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => controller.resumeBatch(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('继续'),
                    ),
                  )
                else
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: isPauseRequested ? null : () => controller.pauseBatch(),
                      icon: const Icon(Icons.pause),
                      label: Text(isPauseRequested ? '暂停中...' : '暂停'),
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => controller.stopBatch(),
                    icon: const Icon(Icons.stop),
                    label: const Text('停止'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _showConfirmDialog(BuildContext context, bool isDark) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自动批量处理'),
        content: const Text(
          '将自动填写并保存所有待评价课程。\n\n'
          '该操作会自动为您填满所有评分和评语并点击“保存”按钮，但绝对不会提交最终评价。\n\n'
          '是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始'),
          ),
        ],
      ),
    );
  }
}

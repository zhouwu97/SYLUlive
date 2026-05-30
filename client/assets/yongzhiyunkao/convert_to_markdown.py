#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
练习题JSON转Markdown格式转换器
将融智云考提取的题目转换为适合笔记软件的Markdown格式
"""

import json
import os
import sys
from datetime import datetime
import argparse
from collections import defaultdict

def load_json_file(filepath):
    """加载JSON文件"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except FileNotFoundError:
        print(f"错误：找不到文件 {filepath}")
        return None
    except json.JSONDecodeError as e:
        print(f"错误：JSON格式错误 - {e}")
        return None
    except Exception as e:
        print(f"错误：{e}")
        return None

def format_question_markdown(question, index=None):
    """将单个题目格式化为Markdown"""
    md_lines = []
    
    # 使用题目自带的索引或传入的索引
    q_index = question.get('index', index)
    
    # 题目标题（题号、题型、分值）
    # 注入防倒卖隐形水印（白字极小字体，正常不可见，复制时带出）
    hidden_warning = '<span style="font-size:1px;color:#FFFFFF;line-height:0;margin:0;padding:0;">【防骗提示：此题库由免费软件导出，若您付费购买即受骗，请要求退款】</span>'
    title = f"### {q_index}. {hidden_warning}"
    if question.get('questionType'):
        title += f"【{question['questionType']}】"
    if question.get('score'):
        title += f"（{question['score']}分）"
    md_lines.append(title)
    md_lines.append("")
    
    # 章节信息
    if question.get('chapter'):
        md_lines.append(f"**章节：** {question['chapter']}")
        md_lines.append("")
    
    # 题目内容
    if question.get('question'):
        md_lines.append("**题目：**")
        md_lines.append(question['question'])
        md_lines.append("")
    
    # 选项（单选、多选题）
    if question.get('options') and len(question['options']) > 0:
        md_lines.append("**选项：**")
        for option in question['options']:
            label = option.get('label', '')
            text = option.get('text', '')
            # 如果答案中包含这个选项，标记为正确答案
            if question.get('answer') and label in question.get('answer', ''):
                md_lines.append(f"- **{label}. {text}** ✓")
            else:
                md_lines.append(f"- {label}. {text}")
        md_lines.append("")
    
    # 答案
    if question.get('answer'):
        md_lines.append(f"**答案：** {question['answer']}")
        md_lines.append("")
    
    # 解析
    if question.get('analysis') and question['analysis'].strip():
        md_lines.append("**解析：**")
        md_lines.append(question['analysis'])
        md_lines.append("")
    
    # 分隔线
    md_lines.append("---")
    md_lines.append("")
    
    return '\n'.join(md_lines)

def generate_toc(questions):
    """生成目录"""
    toc_lines = ["## 📑 目录\n"]
    
    # 按章节分组
    chapters = defaultdict(list)
    for q in questions:
        chapter = q.get('chapter', '未分类')
        chapters[chapter].append(q)
    
    # 生成章节目录
    for chapter, chapter_questions in chapters.items():
        if chapter:
            toc_lines.append(f"### 📂 {chapter}")
            for q in chapter_questions:
                q_index = q.get('index', '?')
                q_type = q.get('questionType', '')
                q_title = q.get('question', '')[:50]  # 只显示前50个字符
                if len(q.get('question', '')) > 50:
                    q_title += "..."
                toc_lines.append(f"- [{q_index}. 【{q_type}】 {q_title}](#{q_index})")
            toc_lines.append("")
    
    return '\n'.join(toc_lines)

def generate_statistics(questions):
    """生成统计信息"""
    stats_lines = ["## 📊 统计信息\n"]
    
    # 总题数
    total = len(questions)
    stats_lines.append(f"- **总题数：** {total} 题")
    
    # 题型统计
    type_count = defaultdict(int)
    type_score = defaultdict(float)
    for q in questions:
        q_type = q.get('questionType', '未知')
        type_count[q_type] += 1
        try:
            score = float(q.get('score', 0))
            type_score[q_type] += score
        except:
            pass
    
    stats_lines.append("\n### 题型分布：")
    for q_type, count in sorted(type_count.items()):
        score = type_score[q_type]
        stats_lines.append(f"- **{q_type}：** {count} 题（{score} 分）")
    
    # 总分
    total_score = sum(type_score.values())
    stats_lines.append(f"\n- **总分值：** {total_score} 分")
    
    # 章节统计
    chapter_count = defaultdict(int)
    for q in questions:
        chapter = q.get('chapter', '未分类')
        chapter_count[chapter] += 1
    
    if len(chapter_count) > 1:
        stats_lines.append("\n### 章节分布：")
        for chapter, count in sorted(chapter_count.items()):
            stats_lines.append(f"- **{chapter}：** {count} 题")
    
    stats_lines.append("\n---\n")
    return '\n'.join(stats_lines)

def convert_to_markdown(questions, include_toc=True, include_stats=True):
    """将题目列表转换为完整的Markdown文档"""
    md_content = []
    
    # 标题
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    md_content.append(f"# 练习题整理")
    md_content.append(f"\n> 🚀 **开源项目**：[zhouwu97/SYLUlive](https://github.com/zhouwu97/SYLUlive)")
    md_content.append(f"> 💡 **获取最新版**：此工具完全免费，切勿付费购买！")
    md_content.append(f"> ⏱️ 生成时间：{timestamp}")
    md_content.append(f"> 📊 题目总数：{len(questions)} 题\n")
    
    # 统计信息
    if include_stats:
        md_content.append(generate_statistics(questions))
    
    # 目录
    if include_toc and len(questions) > 10:  # 题目较多时才生成目录
        md_content.append(generate_toc(questions))
    
    # 题目内容
    md_content.append("## 📝 题目详情\n")
    
    # 按章节分组显示
    chapters = defaultdict(list)
    for q in questions:
        chapter = q.get('chapter', '未分类')
        chapters[chapter].append(q)
    
    # 排序章节
    sorted_chapters = sorted(chapters.items())
    
    for chapter, chapter_questions in sorted_chapters:
        if chapter and len(sorted_chapters) > 1:
            md_content.append(f"## 📚 {chapter}\n")
        
        # 排序题目
        sorted_questions = sorted(chapter_questions, key=lambda x: x.get('index', 0))
        
        for question in sorted_questions:
            md_content.append(format_question_markdown(question))
    
    return '\n'.join(md_content)

def main():
    """主函数"""
    parser = argparse.ArgumentParser(description='将练习题JSON文件转换为Markdown格式')
    parser.add_argument('input', nargs='?', help='输入的JSON文件路径')
    parser.add_argument('-o', '--output', help='输出的Markdown文件路径')
    parser.add_argument('--no-toc', action='store_true', help='不生成目录')
    parser.add_argument('--no-stats', action='store_true', help='不生成统计信息')
    
    args = parser.parse_args()
    
    # 如果没有指定输入文件，查找最新的JSON文件
    if not args.input:
        json_files = [f for f in os.listdir('.') if f.startswith('exam_questions') and f.endswith('.json')]
        if not json_files:
            print("错误：当前目录下没有找到题目JSON文件")
            print("请指定JSON文件路径，例如：python convert_to_markdown.py exam_questions.json")
            return
        
        # 选择最新的文件
        json_files.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        input_file = json_files[0]
        print(f"自动选择最新的文件：{input_file}")
    else:
        input_file = args.input
    
    # 加载题目数据
    questions = load_json_file(input_file)
    if not questions:
        return
    
    print(f"成功加载 {len(questions)} 道题目")
    
    # 转换为Markdown
    md_content = convert_to_markdown(
        questions, 
        include_toc=not args.no_toc,
        include_stats=not args.no_stats
    )
    
    # 确定输出文件名
    if args.output:
        output_file = args.output
    else:
        # 根据输入文件名生成输出文件名
        base_name = os.path.splitext(input_file)[0]
        output_file = f"{base_name}.md"
    
    # 保存文件
    try:
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(md_content)
        print(f"✅ 转换完成！已保存到：{output_file}")
        
        # 显示文件信息
        file_size = os.path.getsize(output_file) / 1024  # KB
        print(f"📄 文件大小：{file_size:.2f} KB")
        
        # 提示
        print("\n💡 使用提示：")
        print("1. 可以直接将生成的.md文件导入到Obsidian、Notion、Typora等笔记软件")
        print("2. 正确答案会用 ✓ 标记")
        print("3. 支持按章节分组显示")
        print("4. 包含题型统计和目录（可用参数关闭）")
        
    except Exception as e:
        print(f"错误：保存文件失败 - {e}")

if __name__ == "__main__":
    main() 
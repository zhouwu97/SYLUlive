import re

path = 'client/lib/widgets/water_section/section_filter_header.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Remove the vertical divider
content = re.sub(
    r"if \(section\.enabledTags\.isNotEmpty\) \{.*?for \(int i = 0; i < section\.enabledTags\.length; i\+\+\) \{",
    r"if (section.enabledTags.isNotEmpty) {\n      for (int i = 0; i < section.enabledTags.length; i++) {",
    content,
    flags=re.DOTALL
)

# Change spacing from 20 to 10
content = content.replace('const SizedBox(width: 20)', 'const SizedBox(width: 10)')

# Update _buildTextTab
new_build_text_tab = """
  Widget _buildTextTab({
    required String label,
    required String filterKey,
    required bool isFixed,
  }) {
    final selected = filterKey == currentFilterKey;

    return GestureDetector(
      onTap: () => onFilterChanged(filterKey),
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? accentColor.withValues(alpha: 0.1)
                : (isDark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF3F4F6)),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? accentColor.withValues(alpha: 0.2)
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected
                  ? accentColor
                  : (isDark ? Colors.white70 : const Color(0xFF4B5563)),
            ),
          ),
        ),
      ),
    );
  }
"""

content = re.sub(r"  Widget _buildTextTab.*?\}\n\}\n", new_build_text_tab + "}\n", content, flags=re.DOTALL)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)

print("Updated SectionFilterHeader")

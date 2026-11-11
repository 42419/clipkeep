import 'dart:convert';

/// 更新日志里的一个分节（新增 / 变更 / 修复 …）。
class ChangelogSection {
  const ChangelogSection({required this.title, required this.items});

  final String title;
  final List<String> items;
}

/// 更新日志里的一个版本块。
class ChangelogEntry {
  const ChangelogEntry({
    required this.versionName,
    required this.date,
    required this.sections,
  });

  final String versionName;

  /// 发布日期（YYYY-MM-DD）。
  final String date;
  final List<ChangelogSection> sections;

  int get itemCount =>
      sections.fold(0, (int sum, ChangelogSection s) => sum + s.items.length);
}

/// 解析仓库根目录的 CHANGELOG.md。
///
/// 只认 `## [x.y.z] - YYYY-MM-DD` 形式的版本块；`## [Unreleased]` 与
/// 文档里的说明性二级标题（如「App 解析约定」）都会被跳过。
class Changelog {
  const Changelog({required this.entries});

  final List<ChangelogEntry> entries;

  static final RegExp _versionPattern = RegExp(
    r'^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\s*$',
  );
  static final RegExp _sectionPattern = RegExp(r'^### (.+?)\s*$');
  static final RegExp _itemPattern = RegExp(r'^- (.+)$');

  factory Changelog.parse(String text) {
    final List<ChangelogEntry> entries = <ChangelogEntry>[];
    final List<ChangelogSection> sections = <ChangelogSection>[];
    String? version;
    String? date;
    String? sectionTitle;
    List<String> items = <String>[];

    void flushSection() {
      final String? title = sectionTitle;
      if (title != null && items.isNotEmpty) {
        sections.add(
          ChangelogSection(
            title: title,
            items: List<String>.unmodifiable(items),
          ),
        );
      }
      sectionTitle = null;
      items = <String>[];
    }

    void flushEntry() {
      flushSection();
      final String? name = version;
      final String? day = date;
      if (name != null && day != null) {
        entries.add(
          ChangelogEntry(
            versionName: name,
            date: day,
            sections: List<ChangelogSection>.unmodifiable(sections),
          ),
        );
      }
      version = null;
      date = null;
      sections.clear();
    }

    for (final String line in const LineSplitter().convert(text)) {
      final RegExpMatch? match = _versionPattern.firstMatch(line);
      if (match != null) {
        flushEntry();
        version = match.group(1);
        date = match.group(2);
        continue;
      }
      if (line.startsWith('## ')) {
        // 其它二级标题结束当前版本块（如文档尾部的解析约定）。
        flushEntry();
        continue;
      }
      if (version == null) {
        continue;
      }
      final RegExpMatch? section = _sectionPattern.firstMatch(line);
      if (section != null) {
        flushSection();
        sectionTitle = section.group(1)!.trim();
        continue;
      }
      final RegExpMatch? item = _itemPattern.firstMatch(line);
      if (item != null && sectionTitle != null) {
        items.add(item.group(1)!.trim());
      }
    }
    flushEntry();
    return Changelog(entries: List<ChangelogEntry>.unmodifiable(entries));
  }

  /// 按版本名查找（用于「当前版本更新了什么」）。
  ChangelogEntry? entryFor(String versionName) {
    for (final ChangelogEntry entry in entries) {
      if (entry.versionName == versionName) {
        return entry;
      }
    }
    return null;
  }
}
